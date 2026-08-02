#!/usr/bin/env bash
#
# bin/apply-lock.sh — single-flight concurrency guard for YNAB write-back (GAP-9 / #51).
#
# WHAT THIS IS
#   A mutex around the write-back apply lifecycle. A scheduled review (M2-11) can
#   fire while Mike is mid-`/ynab-apply`, or two interactive sessions could both
#   write — two overlapping apply runs against the same proposal, or a review
#   regenerating the proposal file while an apply is reading it, can corrupt state
#   or double-apply. This helper serializes those actors: exactly one apply-or-review
#   critical section runs at a time. The apply command acquires it before it reads
#   the proposal and releases it when the batch is done or aborts; the review acquires
#   it (the lighter guard, see below) before it writes/overwrites a proposal.
#
# 🔒 CONCURRENCY GUARD ONLY — IT HAS ZERO BEARING ON APPROVAL (issue #51 AC #6)
#   This lock is PURELY a concurrency guard. It is NOT, and must never become, an
#   approval mechanism. The record it writes carries only { pid, timestamp,
#   operation } — no `approved` flag, no sentinel, no path the write-approval gate
#   reads or could infer satisfaction from. The human-approval gate for a write
#   batch lives entirely in commands/ynab-apply.md (the three-options AskUserQuestion
#   loop) and the M4-2 write-safety guardrail; NEITHER reads this lock. Holding the
#   lock authorizes NOTHING — it only means "another apply/review is in flight, wait."
#   The brief's prohibition is specifically against using a lockfile to BYPASS the
#   approval gate; this lock is kept physically separate (its own file, no approval
#   fields) and semantically separate (guards concurrency, never authorization) so it
#   can never be repurposed to skip approval. Do not add any approval-shaped field to
#   the lock record, and do not make any approval decision read this file.
#
# THE LIGHTER REVIEW GUARD (issue #51 AC #3)
#   Both actors take THIS one lock, so whichever is second backs off (AC #4). The
#   apply run HOLDS it across its whole lifecycle (acquire → read proposal → dry-run
#   → approve → apply → audit → release). The review does NOT need to hold a lock
#   across its long read-only analysis — it only needs to avoid overwriting or
#   truncating a proposal file that an apply is actively consuming. So the review's
#   use is "lighter": it consults the lock only around the destructive proposal-write
#   moment (`acquire review` → write → `release`). If an apply holds the lock, the
#   review's `acquire` returns non-zero and it exits immediately with the held message
#   below, leaving the proposal file untouched. Coordinates with the M4-10 review
#   emitter and the GAP-10 lifecycle (assets/changeset-lifecycle.md §8), which wire
#   `acquire review` around the proposal write when that emitter lands.
#
# WHO SOURCES / RUNS THIS
#   - commands/ynab-apply.md (M4-5) runs it as a CLI: `bash bin/apply-lock.sh acquire
#     apply` before the proposal read, `… release` on completion/abort.
#   - The M4-10 review emitter runs `… acquire review` before writing a proposal.
#   - Tests source it and call the functions directly (see tests/unit/apply-lock.test.sh).
#   Sourcing only DEFINES functions and reads no state — it never runs `set -e`/`set -u`
#   or any side-effecting command at load time, so it cannot alter or abort the
#   caller's shell (same sourceable contract as bin/config.sh and bin/audit-log.sh).
#
# STORAGE LOCATION — under the plugin DATA dir, never /tmp, never the repo
#   The lock lives alongside config, proposals, and the audit log in the plugin-data
#   dir: ~/.claude/plugins/data/workbench-ynab-claude-workbench/apply.lock . Under the
#   data dir (not /tmp) so it sits with the proposal/audit files it protects and is
#   never mistaken for the interactive-approval carve-out lock some tooling keeps in
#   /tmp — this lock has nothing to do with approval (see the guard-only note above).
#   The path is HOME-relative, never hard-coded to a user, and honors a test seam.
#
# CRASH SAFETY — a dead holder is always recoverable, never a permanent deadlock
#   The lock record carries the acquiring process's PID. Staleness is detected with
#   `kill -0` (no external registry): if the recorded PID is not alive, the next
#   acquire automatically breaks the stale lock, logs the recovery to STDERR, and
#   re-acquires. A process killed while holding the lock therefore leaves a lock that
#   the next actor self-heals — no manual intervention, no permanent deadlock. The
#   acquire is atomic via the hardlink (`ln`) idiom: the lock file is created as a
#   link to a fully-written temp file, so it holds its complete record the instant it
#   exists (there is no create-then-write window in which a racer could read an empty
#   lock). Owner identity defaults to $PPID — the long-lived host process, stable
#   across the separate bash blocks of one command run — so acquire in one block and
#   release in another agree on ownership (the $$ of a per-block shell would not).
#
# TEST SEAMS (env overrides; production leaves them unset)
#   YNAB_LOCK_FILE       full path to the lock file (else the canonical data-dir path)
#   YNAB_LOCK_PID        owner pid to record/verify (else $PPID) — lets a test stand in
#                        a specific live or dead pid to drive held / stale / recovery
#   YNAB_LOCK_TIMESTAMP  record timestamp override (else current UTC ISO 8601 + Z)

# --- path / identity / time resolution --------------------------------------

# _lock_file
#   Echo the resolved lock-file path. Honors the YNAB_LOCK_FILE test seam,
#   otherwise the canonical plugin-data path (HOME-relative, never hard-coded,
#   never in /tmp, never inside the repo).
_lock_file() {
  if [ -n "${YNAB_LOCK_FILE:-}" ]; then
    printf '%s\n' "$YNAB_LOCK_FILE"
  else
    printf '%s\n' "$HOME/.claude/plugins/data/workbench-ynab-claude-workbench/apply.lock"
  fi
}

# _lock_owner_pid
#   Echo the pid this run acts as. YNAB_LOCK_PID test seam, else $PPID — the
#   long-lived host process, stable across a command run's separate bash blocks so
#   an acquire and a later release resolve the SAME owner ($$ would be a per-block
#   shell, dead by the next block, and would defeat the release ownership check).
_lock_owner_pid() {
  printf '%s\n' "${YNAB_LOCK_PID:-$PPID}"
}

# _lock_timestamp
#   Echo the record timestamp: ISO 8601 with timezone (UTC, trailing Z). Current
#   time unless the YNAB_LOCK_TIMESTAMP test seam overrides it.
_lock_timestamp() {
  printf '%s\n' "${YNAB_LOCK_TIMESTAMP:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
}

# --- introspection ----------------------------------------------------------

# _lock_read
#   Echo the raw lock-file content, or nothing when no lock exists.
_lock_read() {
  local lock
  lock="$(_lock_file)"
  if [ -f "$lock" ]; then
    cat "$lock" 2>/dev/null
  fi
}

# _lock_field <name>
#   Echo one field (pid | timestamp | operation) from the lock record, or nothing
#   when the lock is absent or its content is not parseable JSON.
_lock_field() {
  local content
  content="$(_lock_read)"
  if [ -z "$content" ]; then
    return 0
  fi
  printf '%s' "$content" | jq -r ".${1} // empty" 2>/dev/null
}

# _lock_pid_alive <pid>
#   Return 0 iff <pid> is a positive integer naming a live process. A non-numeric
#   or empty value is treated as NOT alive (fail-closed for the caller that decides
#   whether to break a lock: only a provably-dead numeric pid is broken).
_lock_pid_alive() {
  local pid="${1:-}"
  case "$pid" in
    '' | *[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

# _lock_held_message
#   Print the exact user-facing message (issue #51 AC #4) to STDOUT, plus a second
#   line of holder context. The first line carries the verbatim required phrasing;
#   callers surface it when a second actor finds the lock held.
_lock_held_message() {
  local pid op ts
  pid="$(_lock_field pid)"
  op="$(_lock_field operation)"
  ts="$(_lock_field timestamp)"
  printf '⏳ an apply/review is already running — try again once it completes\n'
  printf '   (held by pid %s, operation %s, since %s)\n' "${pid:-?}" "${op:-?}" "${ts:-?}"
}

# --- core -------------------------------------------------------------------

# _lock_break <reason>
#   Remove a lock judged stale by the caller, logging the recovery to STDERR so a
#   self-healed deadlock leaves a trail. Only ever called after a dead-pid check.
_lock_break() {
  local reason="${1:-stale}" lock
  lock="$(_lock_file)"
  printf 'apply-lock: recovered stale lock (%s) — broke %s\n' "$reason" "$lock" 1>&2
  rm -f "$lock"
}

# _lock_acquire <apply|review>
#   Acquire the single-flight lock for the named operation. Atomic via the hardlink
#   idiom: write the full record to a temp file, then `ln` it to the lock path — the
#   link fails (EEXIST) if a lock already exists, and succeeds only when this caller
#   wins, at which instant the lock already holds its complete record.
#     * Free            → acquire, return 0.
#     * Held, dead pid  → break the stale lock (log recovery), retry once, acquire.
#     * Held, live pid  → print the held message to STDERR, return 1 (non-destructive).
#   An invalid operation name returns 2 (usage error), touching nothing.
_lock_acquire() {
  local op="${1:-}"
  case "$op" in
    apply | review) ;;
    *)
      printf "apply-lock: operation must be 'apply' or 'review' (got '%s')\n" "${op:-}" 1>&2
      return 2
      ;;
  esac

  local lock dir
  lock="$(_lock_file)"
  dir="$(dirname "$lock")"
  if ! ( umask 077; mkdir -p "$dir" ) 2>/dev/null; then
    printf 'apply-lock: cannot create data dir: %s\n' "$dir" 1>&2
    return 1
  fi

  local pid ts content
  pid="$(_lock_owner_pid)"
  ts="$(_lock_timestamp)"
  if ! content="$(jq -cn --argjson pid "$pid" --arg ts "$ts" --arg op "$op" \
      '{pid: $pid, timestamp: $ts, operation: $op}' 2>/dev/null)"; then
    printf 'apply-lock: failed to build lock record (pid=%s)\n' "$pid" 1>&2
    return 1
  fi

  # Two attempts: the first, and one more after breaking a stale lock. A live holder
  # that re-acquires between our break and retry simply makes the second `ln` fail
  # too — we then report held rather than loop, so a healthy competitor is never
  # starved and we never spin.
  local attempt tmp holder_pid
  for attempt in 1 2; do
    if ! tmp="$(mktemp "$dir/.apply-lock.XXXXXX" 2>/dev/null)"; then
      printf 'apply-lock: cannot create temp file in %s\n' "$dir" 1>&2
      return 1
    fi
    printf '%s\n' "$content" > "$tmp"
    chmod 600 "$tmp" 2>/dev/null || true

    if ln "$tmp" "$lock" 2>/dev/null; then
      rm -f "$tmp"
      return 0
    fi
    rm -f "$tmp"

    # Lock exists. Break it only if its recorded pid is provably dead.
    holder_pid="$(_lock_field pid)"
    if [ "$attempt" -eq 1 ] && ! _lock_pid_alive "$holder_pid"; then
      _lock_break "holder pid ${holder_pid:-unknown} is not alive"
      continue
    fi
    break
  done

  _lock_held_message 1>&2
  return 1
}

# _lock_release
#   Release the lock this run holds. Idempotent (no lock → success). Ownership-checked:
#   it refuses to delete a lock whose recorded pid is a DIFFERENT live process, so a
#   run that was stale-broken and superseded can never delete the successor's lock. A
#   lock with no parseable pid (external tampering) is removable by our own cleanup.
_lock_release() {
  local lock holder_pid mine
  lock="$(_lock_file)"
  if [ ! -e "$lock" ]; then
    return 0
  fi
  holder_pid="$(_lock_field pid)"
  mine="$(_lock_owner_pid)"
  if [ -n "$holder_pid" ] && [ "$holder_pid" != "$mine" ] && _lock_pid_alive "$holder_pid"; then
    printf 'apply-lock: refusing to release a lock held by live pid %s (this run is %s)\n' \
      "$holder_pid" "$mine" 1>&2
    return 1
  fi
  rm -f "$lock"
}

# _lock_status
#   Print a human-readable summary of the current lock to STDOUT: free, held by a
#   live pid, or a stale lock the next acquire will recover.
_lock_status() {
  local lock pid op ts
  lock="$(_lock_file)"
  if [ ! -e "$lock" ]; then
    printf 'apply-lock: no lock held (%s)\n' "$lock"
    return 0
  fi
  pid="$(_lock_field pid)"
  op="$(_lock_field operation)"
  ts="$(_lock_field timestamp)"
  if _lock_pid_alive "$pid"; then
    printf 'apply-lock: held by pid %s (operation %s) since %s\n' "${pid:-?}" "${op:-?}" "${ts:-?}"
  else
    printf 'apply-lock: STALE lock from pid %s (operation %s) since %s — pid not alive; next acquire recovers it\n' \
      "${pid:-?}" "${op:-?}" "${ts:-?}"
  fi
}

# --- CLI dispatch (only when executed directly, never when sourced) ----------

_lock_cli_usage() {
  cat 1>&2 <<'USAGE'
usage: bin/apply-lock.sh acquire <apply|review>   # acquire the single-flight lock (exit 1 if held)
       bin/apply-lock.sh release                  # release the lock this run holds
       bin/apply-lock.sh status                   # print the current lock holder, if any
A concurrency guard only — it has ZERO bearing on write approval (see the file header).
USAGE
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -u
  if ! command -v jq >/dev/null 2>&1; then
    echo "apply-lock: jq is required but was not found on PATH." 1>&2
    exit 1
  fi
  cmd="${1:-}"
  case "$cmd" in
    acquire) shift; _lock_acquire "${1:-}" ;;
    release) _lock_release ;;
    status) _lock_status ;;
    "" | -h | --help | help)
      _lock_cli_usage
      exit 2 ;;
    *)
      echo "apply-lock: unknown command: $cmd" 1>&2
      _lock_cli_usage
      exit 2 ;;
  esac
fi
