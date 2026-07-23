#!/usr/bin/env bash
# Unit tests for bin/apply-lock.sh — the single-flight write-back concurrency guard.
# Run directly: tests/unit/apply-lock.test.sh
#
# Style mirrors tests/unit/audit-log.test.sh: raw bash, `set -u`, PASS/FAIL
# counters, a mktemp sandbox, and a non-zero exit when anything fails. The guard is
# exercised in isolation (no YNAB, no apply command) by sourcing the helper and
# calling its functions, driving holder identity/liveness with the YNAB_LOCK_PID and
# YNAB_LOCK_FILE test seams.
#
# Covers issue #51 AC #7 exactly:
#   (a) normal acquire/release cycle
#   (b) lock-held rejection (the exact user-facing message)
#   (c) stale-PID auto-recovery
#   (d) crash simulation (lock left by a killed process) → successful re-acquisition
# plus AC #2 (pid + timestamp + operation are all recorded) and AC #6 (the record
# carries NO approval-shaped field — it is a concurrency guard only).
#
# Requires jq (the helper itself requires jq); fails with a clear message if absent.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$REPO_ROOT/bin/apply-lock.sh"
PASS=0
FAIL=0

if ! command -v jq >/dev/null 2>&1; then
  echo "apply-lock tests: jq not found on PATH — cannot run" 1>&2
  exit 1
fi

SANDBOX="$(mktemp -d)"
# A real, long-lived helper process gives us a pid that is provably ALIVE for the
# whole run (a "different live holder" the current run does not own). Reaped at teardown.
sleep 300 &
LIVE_OTHER_PID=$!
trap 'kill "$LIVE_OTHER_PID" 2>/dev/null; wait "$LIVE_OTHER_PID" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

# The lock file for every test — the seam that keeps this out of the real data dir.
export YNAB_LOCK_FILE="$SANDBOX/apply.lock"
export YNAB_LOCK_TIMESTAMP="2026-06-15T12:00:00Z"

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1)); echo "  ✅ $desc"
  else
    FAIL=$((FAIL + 1)); echo "  ❌ $desc — expected: [$expected] got: [$actual]"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1)); echo "  ✅ $desc"
  else
    FAIL=$((FAIL + 1)); echo "  ❌ $desc — expected to find: [$needle] in: [$haystack]"
  fi
}

# assert_jq <desc> <json> <jq-bool-filter>: PASS when the filter is true.
assert_jq() {
  local desc="$1" json="$2" filter="$3"
  if printf '%s' "$json" | jq -e "$filter" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "  ✅ $desc"
  else
    FAIL=$((FAIL + 1)); echo "  ❌ $desc — filter failed: [$filter] on: [$json]"
  fi
}

# reaped_pid: echo a pid that is guaranteed NOT alive — a child we start and reap, so
# `kill -0` fails on it. This is a real dead pid (not a guessed-high number), the exact
# state a crashed holder leaves behind.
reaped_pid() {
  local p
  ( exit 0 ) &
  p=$!
  wait "$p" 2>/dev/null || true
  printf '%s' "$p"
}

reset_lock() { rm -f "$YNAB_LOCK_FILE"; }

# Source the helper under test (defines functions; no side effects at load).
# shellcheck source=/dev/null
source "$HELPER"

# ---------------------------------------------------------------------------
echo "AC #7(a) + AC #2: a normal acquire records pid + timestamp + operation, release clears it:"
reset_lock
export YNAB_LOCK_PID="$$"   # this run owns the lock (a live pid: the test process)
_lock_acquire apply; rc=$?
assert_eq "acquire returns 0"                       "0" "$rc"
assert_eq "lock file exists after acquire"          "1" "$([ -f "$YNAB_LOCK_FILE" ] && echo 1 || echo 0)"
REC="$(cat "$YNAB_LOCK_FILE")"
assert_jq "record carries pid, timestamp, operation" "$REC" 'has("pid") and has("timestamp") and has("operation")'
assert_eq "pid is the acquiring process"            "$$"                    "$(printf '%s' "$REC" | jq -r '.pid')"
assert_eq "timestamp is recorded"                   "2026-06-15T12:00:00Z"  "$(printf '%s' "$REC" | jq -r '.timestamp')"
assert_eq "operation name is recorded"              "apply"                 "$(printf '%s' "$REC" | jq -r '.operation')"
_lock_release; rc=$?
assert_eq "release returns 0"                       "0" "$rc"
assert_eq "lock file gone after release"            "0" "$([ -e "$YNAB_LOCK_FILE" ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
echo "AC #6: the record has NO approval-shaped field — concurrency guard only:"
reset_lock
export YNAB_LOCK_PID="$$"
_lock_acquire apply >/dev/null
REC="$(cat "$YNAB_LOCK_FILE")"
# Exactly three keys, and none of the approval-shaped names an approval gate might read.
assert_eq "record has exactly three keys"           "3" "$(printf '%s' "$REC" | jq -r '[keys[]] | length')"
assert_jq "no 'approved' key"                       "$REC" '(has("approved") | not)'
assert_jq "no 'approval' key"                       "$REC" '(has("approval") | not)'
assert_jq "no 'authorized' key"                     "$REC" '(has("authorized") | not)'
assert_jq "keys are exactly {operation,pid,timestamp}" "$REC" '(keys | sort) == ["operation","pid","timestamp"]'
_lock_release

# ---------------------------------------------------------------------------
echo "AC #7(b): a live holder makes a second actor back off with the exact message:"
reset_lock
export YNAB_LOCK_PID="$$"              # holder: this live process, as 'apply'
_lock_acquire apply >/dev/null
# A second actor (the review) attempts to acquire; its own owner pid is irrelevant —
# what matters is that the RECORDED holder ($$) is alive, so it must back off.
err="$(YNAB_LOCK_PID="$LIVE_OTHER_PID" _lock_acquire review 2>&1)"; rc=$?
assert_eq "second acquire returns 1 (held)"         "1" "$rc"
assert_contains "prints the exact AC #4 message"    "$err" "an apply/review is already running — try again once it completes"
assert_eq "the original lock is untouched"          "apply" "$(jq -r '.operation' "$YNAB_LOCK_FILE")"
assert_eq "holder pid still the original"           "$$"    "$(jq -r '.pid' "$YNAB_LOCK_FILE")"
export YNAB_LOCK_PID="$$"
_lock_release

# ---------------------------------------------------------------------------
echo "AC #7(b) symmetric: the guard is mutual — apply also backs off behind a review:"
reset_lock
export YNAB_LOCK_PID="$$"
_lock_acquire review >/dev/null
err="$(YNAB_LOCK_PID="$LIVE_OTHER_PID" _lock_acquire apply 2>&1)"; rc=$?
assert_eq "apply backs off behind a live review"    "1" "$rc"
assert_contains "prints the exact AC #4 message"    "$err" "an apply/review is already running — try again once it completes"
export YNAB_LOCK_PID="$$"
_lock_release

# ---------------------------------------------------------------------------
echo "AC #7(c): a stale lock (dead recorded pid) is auto-recovered on the next acquire:"
reset_lock
DEAD="$(reaped_pid)"
# Craft a well-formed lock left by a now-dead pid (a fully-written record, exactly what
# a graceful writer leaves — only the process is gone).
printf '{"pid":%s,"timestamp":"2026-06-15T09:00:00Z","operation":"apply"}\n' "$DEAD" > "$YNAB_LOCK_FILE"
export YNAB_LOCK_PID="$$"
err="$(_lock_acquire apply 2>&1)"; rc=$?
assert_eq "acquire succeeds by breaking the stale lock" "0" "$rc"
assert_contains "logs the stale-lock recovery"          "$err" "recovered stale lock"
assert_eq "the lock is now owned by the live acquirer"  "$$" "$(jq -r '.pid' "$YNAB_LOCK_FILE")"
_lock_release

# ---------------------------------------------------------------------------
echo "AC #7(d): crash simulation — a killed process's leftover lock is re-acquirable:"
reset_lock
# Start a real process, let it 'hold' the lock, then KILL it (SIGKILL: no cleanup, the
# lock is left behind exactly as a crash would leave it), then re-acquire.
sleep 300 &
CRASH_PID=$!
YNAB_LOCK_PID="$CRASH_PID" _lock_acquire apply >/dev/null
assert_eq "lock held by the soon-to-crash pid"      "$CRASH_PID" "$(jq -r '.pid' "$YNAB_LOCK_FILE")"
kill -9 "$CRASH_PID" 2>/dev/null
wait "$CRASH_PID" 2>/dev/null || true
# The lock file still exists (nothing cleaned it up) but its pid is now dead.
assert_eq "crashed holder's lock is left behind"    "1" "$([ -f "$YNAB_LOCK_FILE" ] && echo 1 || echo 0)"
export YNAB_LOCK_PID="$$"
err="$(_lock_acquire apply 2>&1)"; rc=$?
assert_eq "re-acquire after the crash succeeds"     "0" "$rc"
assert_contains "logs the recovery"                 "$err" "recovered stale lock"
assert_eq "re-acquired by the live process"         "$$" "$(jq -r '.pid' "$YNAB_LOCK_FILE")"
_lock_release

# ---------------------------------------------------------------------------
echo "release is ownership-checked: a run never deletes another LIVE holder's lock:"
reset_lock
YNAB_LOCK_PID="$LIVE_OTHER_PID" _lock_acquire apply >/dev/null   # held by another live pid
err="$(YNAB_LOCK_PID="$$" _lock_release 2>&1)"; rc=$?
assert_eq "release refuses (returns 1)"             "1" "$rc"
assert_contains "explains the refusal"              "$err" "refusing to release"
assert_eq "the other holder's lock is intact"       "1" "$([ -f "$YNAB_LOCK_FILE" ] && echo 1 || echo 0)"
# The rightful owner can release it.
YNAB_LOCK_PID="$LIVE_OTHER_PID" _lock_release
assert_eq "rightful owner releases cleanly"         "0" "$([ -e "$YNAB_LOCK_FILE" ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
echo "release is idempotent and an invalid operation is rejected without a write:"
reset_lock
export YNAB_LOCK_PID="$$"
_lock_release; rc=$?
assert_eq "release with no lock returns 0"          "0" "$rc"
_lock_acquire sneaky >/dev/null 2>&1; rc=$?
assert_eq "an unknown operation returns 2"          "2" "$rc"
assert_eq "no lock file is created for a bad op"    "0" "$([ -e "$YNAB_LOCK_FILE" ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
if [ "$FAIL" -ne 0 ]; then
  echo "apply-lock tests: $FAIL failed, $PASS passed" 1>&2
  exit 1
fi
echo "apply-lock tests: all $PASS passed"
