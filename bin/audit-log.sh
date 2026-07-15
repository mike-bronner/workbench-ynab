#!/usr/bin/env bash
#
# bin/audit-log.sh — append-only audit log for applied YNAB write-back changes.
#
# WHAT THIS IS
#   The evidence trail for approval-gated write-back (M4). For every operation
#   the apply executor (M4-4) acts on — real or dry-run — this appends ONE
#   structured JSONL record capturing what changed, when, the before/after
#   snapshots (raw milliunits), the namespaced MCP tool invoked, and the
#   executor's per-op result status. Mike can later review, reverse, or dispute
#   any mutation, and a misbehaving write path leaves a paper trail for debugging.
#
# WHO SOURCES THIS
#   - The apply executor (M4-4) sources this file and calls `_audit_append`
#     after each operation result. The writer is a pure function of its three
#     inputs — it reads no external state and never touches a YNAB API — so it
#     is unit-testable in isolation (see tests/unit/test-audit-log.sh).
#   - The approval command / report path calls the read helpers (`_audit_read_last`,
#     `_audit_read_run`) — or runs this file as a CLI (`last` / `run`) — to render
#     the log for a human.
#
# WHY IT IS SOURCEABLE, NOT just executable
#   Sourcing only DEFINES functions and one path variable. It never runs
#   `set -e`/`set -u` or any command with side effects at load time, so sourcing
#   it cannot alter or abort the caller's shell (same contract as bin/config.sh).
#   When executed directly it dispatches the read-helper CLI (see the foot).
#
# STORAGE LOCATION — under the plugin DATA dir, never the repo
#   The log lives alongside config in the plugin-data dir so it SURVIVES plugin
#   updates: ~/.claude/plugins/data/workbench-ynab-claude-workbench/audit/ , one
#   file per UTC month: audit-YYYY-MM.jsonl. Both config and the audit log live
#   under the data dir for the same survives-updates reason — never in the repo.
#   The path is resolved via the workbench-core pattern (HOME-relative, never
#   hard-coded); see workbench-core/hooks/mcp-memory.sh lines 66-76 and
#   bin/config.sh for the sibling idiom.
#
# WHY JSONL (one JSON object per line) and NOT a single growing JSON array
#   Append-only is trivial and crash-safe with JSONL: a new record is one atomic
#   `>>` write of a newline-terminated line — no read, no parse, no rewrite of what
#   is already on disk. Each record is one compact line (jq -c, no interior
#   newlines), so the writer emits it plus its terminating newline in a SINGLE
#   write(2) to the O_APPEND fd; a regular-file write of a sub-page buffer is copied
#   to the page cache uninterruptibly, so a crash (SIGKILL / power loss) leaves
#   either zero bytes or the whole record — never a partial, truncated line (see
#   _audit_append). As belt-and-suspenders the writer also refuses to FUSE a new
#   record onto any pre-existing dangling fragment. A single JSON array would force a
#   read-modify-write of the whole file on every append (O(n) and not crash-safe: a
#   truncated rewrite loses the entire history). Append-only integrity is the whole
#   point of an audit log, so JSONL is the correct shape.
#
#   The read helpers stay defensively lenient about one UNTERMINATED trailing line
#   (all an out-of-band truncation could leave) and surface a malformed BODY line
#   loudly rather than swallow it — see _audit_jsonl_parse_program — but the writer's
#   single-write guarantee means a crash mid-append no longer produces one.
#
# THE WRITER CONTRACT — _audit_append <operation_json> <result_json> <dry_run>
#   operation_json  The change-set operation (see assets/changeset-schema.json):
#                   { id, type, transaction_id|category_id|account_id|transaction_ids,
#                     before{…}, after{…}, … }. before/after are stored VERBATIM,
#                     in raw milliunits — the read helper divides by 1000 only for
#                     human display.
#   result_json     The write path's per-op result descriptor, carrying the
#                   op outcome plus the change-set provenance it knows:
#                     { tool, status, schema_version, run_id, error_class?, applied_state? }
#                   tool   = namespaced MCP tool invoked (e.g. mcp__ynab__ynab_update_transaction)
#                   status = the write path's NORMALIZED status. It lands verbatim
#                            in each record's result_status, whose full on-trail
#                            vocabulary is five values from three producers:
#                              applied | skipped-stale | blocked | error
#                                — the frozen STATUS enum in assets/apply-executor.js
#                                  (the authoritative definition of these four),
#                                  passed by the executor's recordAudit and
#                                  mirrored by assets/reconcile-handler.js's
#                                  recordAudit;
#                              pending_delete
#                                — the delete path's pre-delete INTENT sentinel
#                                  (assets/delete-duplicate.js
#                                  makeAuditingDeleteApplyOp), written before the
#                                  irreversible delete runs so a destructive op
#                                  leaves a two-phase trail (#50): intent before,
#                                  outcome after.
#                            Never a raw MCP call status such as `success`; a
#                            dry-run simulation arrives as `applied` with the
#                            separate dry_run flag distinguishing it.
#                   schema_version = change-set envelope schema_version (provenance)
#                   run_id = change-set `source` (the review run id, or "manual")
#                   error_class   = on an errored op, the failure class (GAP-8 / #50):
#                                   auth_revoked | insufficient_scope | rate_limited |
#                                   unknown. Absent/null on a non-error op.
#                   applied_state = on an errored op, whether the mutation is known
#                                   NOT to have applied (not_applied) or is
#                                   indeterminate (unknown). Absent/null otherwise.
#                   Both default to null when the result omits them, so every prior
#                   caller stays valid — the resume design (#48) reads these two.
#   dry_run         true|1|yes → logged with dry_run:true; anything else → false.
#                   Dry-run attempts are logged too, flagged, so a dry run leaves
#                   a full paper trail without implying a real mutation.
#   Side effect: appends exactly one record. STDOUT is left untouched (it is
#   reserved for the read helper); diagnostics go to STDERR; returns non-zero on
#   failure to build or append.
#
# TEST SEAMS (env overrides; production leaves them unset)
#   YNAB_AUDIT_DIR        audit dir override (else the canonical data-dir path)
#   YNAB_AUDIT_MONTH      YYYY-MM month key override (else current UTC month)
#   YNAB_AUDIT_TIMESTAMP  record timestamp override (else current UTC ISO 8601)

# --- path / time resolution -------------------------------------------------

# _audit_dir
#   Echo the resolved audit directory. Honors the YNAB_AUDIT_DIR test seam,
#   otherwise the canonical plugin-data path (HOME-relative, never hard-coded,
#   never inside the repo).
_audit_dir() {
  if [ -n "${YNAB_AUDIT_DIR:-}" ]; then
    printf '%s\n' "$YNAB_AUDIT_DIR"
  else
    printf '%s\n' "$HOME/.claude/plugins/data/workbench-ynab-claude-workbench/audit"
  fi
}

# _audit_month
#   Echo the YYYY-MM key for the monthly file. Current UTC month unless the
#   YNAB_AUDIT_MONTH test seam overrides it.
_audit_month() {
  printf '%s\n' "${YNAB_AUDIT_MONTH:-$(date -u +%Y-%m)}"
}

# _audit_timestamp
#   Echo the record timestamp: ISO 8601 with timezone (UTC, trailing Z). Current
#   time unless the YNAB_AUDIT_TIMESTAMP test seam overrides it.
_audit_timestamp() {
  printf '%s\n' "${YNAB_AUDIT_TIMESTAMP:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
}

# _audit_file
#   Echo the full path to the current month's JSONL file.
_audit_file() {
  printf '%s\n' "$(_audit_dir)/audit-$(_audit_month).jsonl"
}

# _audit_fixmu_program
#   Echo the jq `fixmu` definition: recursively divides the known milliunit
#   fields (budgeted, amount, cleared_balance, reconciled_balance) by 1000 for
#   human display, leaving every other field — and non-numeric values — untouched.
_audit_fixmu_program() {
  cat <<'JQ'
def fixmu:
  if type == "object" then
    with_entries(
      if ((.key | IN("budgeted","amount","cleared_balance","reconciled_balance")) and (.value | type == "number"))
      then .value |= (. / 1000)
      else .value |= fixmu
      end
    )
  elif type == "array" then map(fixmu)
  else . end;
JQ
}

# _audit_jsonl_parse_program
#   Echo the jq `parse_jsonl` definition: split slurped raw input (`jq -R -s`) into
#   lines and parse each as one JSON record OBJECT, emitting a stream of objects.
#   Crash tolerance (defense-in-depth): the writer appends each record as a single
#   atomic, newline-terminated write, so a crash no longer leaves a torn line — but
#   an out-of-band truncation still could, and that can only ever be a partial,
#   UNTERMINATED final line.
#   `split("\n")` puts that fragment — or the empty string after a clean trailing
#   newline — in the LAST element, which is parsed leniently: kept only if it is a
#   JSON object (`fromjson?` swallows a parse error; `select(type=="object")` drops
#   a stray non-object such as a bare `null`/`true`/number). Every BODY line must be
#   a JSON OBJECT: a line that fails to parse — OR parses to valid-but-non-object
#   JSON like the literal `null` — is corruption an audit trail must surface, not
#   silently swallow. (A `null` body line is the subtle case: `fromjson` accepts it
#   without error, so without the object guard it would fabricate a phantom
#   {"before":null,"after":null} on read_last, or be dropped by read_run — exactly
#   the kind of invented/lost record this trail exists to prevent.) Such a line
#   `error`s the read. Requires `jq -R -s` (raw input, slurped).
_audit_jsonl_parse_program() {
  cat <<'JQ'
def parse_jsonl:
  split("\n") as $lines
  | ($lines | length) as $n
  | range(0; $n) as $i
  | if $i == $n - 1
    then ($lines[$i] | fromjson? | select(type == "object"))
    else ($lines[$i] | fromjson
          | if type == "object" then .
            else error("malformed audit record (line is valid JSON but not an object)")
            end)
    end;
JQ
}

# --- writer -----------------------------------------------------------------

# _audit_append <operation_json> <result_json> <dry_run>
#   Append exactly one JSONL record built from the three inputs. Pure: the only
#   side effect is the append. The audit dir and monthly file are created on
#   first write if absent. Append-only — never rewrites, truncates, or seeks; the
#   record is emitted as a single atomic, newline-terminated write so a crash can
#   never leave a partial/truncated line, and a new record is never fused onto a
#   pre-existing dangling fragment.
#
#   TRUSTED PASS-THROUGH — no normalization, no validation. The writer stores
#   $res.status verbatim into result_status (and every other field likewise); it
#   does NOT map or reject values outside the trail's five-value vocabulary
#   (see THE WRITER CONTRACT above). Its three production callers — wired to
#   this helper by commands/ynab-apply.md — all honor it:
#   assets/apply-executor.js's recordAudit and assets/reconcile-handler.js's
#   recordAudit pass only the frozen four-value STATUS enum (applied |
#   skipped-stale | blocked | error), and assets/delete-duplicate.js's
#   makeAuditingDeleteApplyOp adds the pending_delete intent sentinel
#   (two-phase trail #50). Any future caller MUST stay within that vocabulary:
#   handing this writer a raw MCP call status (e.g. `success`) would put an
#   undocumented value on the permanent trail.
_audit_append() {
  local op="${1:-}" res="${2:-}" dry_raw="${3:-false}" dry
  case "$dry_raw" in
    true|TRUE|True|1|yes|YES) dry=true ;;
    *) dry=false ;;
  esac

  local record
  record="$(jq -cn \
    --arg ts "$(_audit_timestamp)" \
    --argjson op "$op" \
    --argjson res "$res" \
    --argjson dry "$dry" \
    '{
      timestamp: $ts,
      schema_version: ($res.schema_version // null),
      run_id: ($res.run_id // null),
      operation_id: ($op.id // null),
      operation_type: ($op.type // null),
      target_entity_ids: (
        ([$op.transaction_id, $op.category_id, $op.account_id] | map(select(. != null)))
        + ($op.transaction_ids // [])
      ),
      before: ($op.before // null),
      after: ($op.after // null),
      tool: ($res.tool // null),
      result_status: ($res.status // null),
      error_class: ($res.error_class // null),
      applied_state: ($res.applied_state // null),
      dry_run: $dry
    }' 2>/dev/null)" || {
    echo "audit-log: failed to build record — operation/result must be valid JSON" 1>&2
    return 1
  }

  if [ -z "$record" ]; then
    echo "audit-log: built an empty record; nothing appended" 1>&2
    return 1
  fi

  # The audit trail persists financial data to disk — before/after milliunits,
  # category names, account and transaction ids — so it must NOT be world-readable:
  # the audit dir must be 0700 and each record file 0600 (owner-only). `umask 077`
  # is scoped to a subshell so sourcing this helper never mutates the caller's umask
  # (the same no-side-effects-at-load contract the rest of this file keeps), and it
  # makes a freshly-CREATED dir/file land owner-only. But `mkdir -m` and `umask`
  # only bite at CREATION — a PRE-EXISTING dir/file left at a looser mode (a 0755
  # dir from an earlier run, external tampering) would never be tightened by an
  # append. So we also `chmod` explicitly afterward to ENFORCE the mode every time,
  # not just on the first write. The 0700 dir is the real access boundary; the 0600
  # file is defense-in-depth. (No sibling helper sets modes because none of them
  # write sensitive data — this one does.)
  local dir; dir="$(_audit_dir)"
  local file; file="$(_audit_file)"

  if ! ( umask 077; mkdir -p -m 700 "$dir" ) 2>/dev/null; then
    echo "audit-log: cannot create audit dir: $dir" 1>&2
    return 1
  fi
  if ! chmod 700 "$dir" 2>/dev/null; then
    echo "audit-log: cannot enforce owner-only perms on audit dir: $dir" 1>&2
    return 1
  fi

  # Atomic, never-truncating append. The record is one compact JSONL line (jq -c,
  # no interior newlines), so a single `printf` to the O_APPEND fd (`>>`) emits the
  # whole record plus its terminating newline in one write(2). A regular-file write
  # of a sub-page buffer is copied to the page cache uninterruptibly, so a crash
  # (SIGKILL / power loss) leaves either zero bytes or the whole newline-terminated
  # record — never a partial, truncated line. O_APPEND also positions every write at
  # EOF atomically, so concurrent appenders never interleave.
  #
  # Belt-and-suspenders: if the file somehow does NOT already end in a newline (a
  # dangling fragment from an out-of-band truncation — this writer never leaves one),
  # prepend a newline so the new record starts on its own line and can never FUSE
  # onto the fragment. `$(tail -c1)` is empty iff the last byte is a newline (command
  # substitution strips it). This only ever ADDS bytes at EOF — still strictly
  # append-only: the fragment is isolated on its own line, never rewritten.
  local nl=""
  if [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ]; then
    nl=$'\n'
  fi
  if ! ( umask 077; printf '%s%s\n' "$nl" "$record" >> "$file" ); then
    echo "audit-log: append failed: $file" 1>&2
    return 1
  fi
  if ! chmod 600 "$file" 2>/dev/null; then
    echo "audit-log: cannot enforce owner-only perms on audit file: $file" 1>&2
    return 1
  fi
}

# --- read helpers -----------------------------------------------------------

# _audit_read_last [N]
#   Print the last N records (default 10) from the CURRENT month's file, with
#   milliunit amounts divided by 1000 for display, to STDOUT. Output is JSONL
#   (one JSON object per line), not a JSON array — a caller wanting an array can
#   `jq -s`. A partial trailing line (from an out-of-band truncation; the writer's
#   atomic append prevents one on crash) is skipped; a malformed BODY line fails the
#   read. Diagnostics (e.g. no file yet, or a body-corruption failure) go to STDERR;
#   absence is not an error.
_audit_read_last() {
  local n="${1:-10}" file
  file="$(_audit_file)"
  if [ ! -f "$file" ]; then
    echo "audit-log: no audit file for $(_audit_month) at $file" 1>&2
    return 0
  fi
  # Slurp the last N lines as raw text (`-R -s`) and parse line-by-line via
  # parse_jsonl so a malformed TRAILING line — the most an out-of-band truncation
  # can leave (the writer's atomic append prevents one on crash) — is skipped while
  # every complete record still reads back. A malformed
  # BODY line, by contrast, makes jq exit non-zero; the pipeline's exit status is
  # jq's, so `if !` keys on it and adds the `audit-log:` prefix every other error
  # path uses (jq's own detail still reaches STDERR).
  if ! tail -n "$n" "$file" | jq -R -s "$(_audit_fixmu_program)
$(_audit_jsonl_parse_program)
parse_jsonl | .before |= fixmu | .after |= fixmu"; then
    echo "audit-log: failed to format records from $file" 1>&2
    return 1
  fi
}

# _audit_read_run <run_id>
#   Print every record whose run_id matches, across ALL monthly files in the
#   audit dir (chronological order), with milliunit amounts divided by 1000 for
#   display, to STDOUT. Output is JSONL (one JSON object per line), not a JSON
#   array — a caller wanting an array can `jq -s`. A partial trailing line (from an
#   out-of-band truncation; the writer's atomic append prevents one on crash) is
#   skipped; a malformed BODY line fails the read. Diagnostics go to STDERR.
_audit_read_run() {
  local rid="${1:-}"
  if [ -z "$rid" ]; then
    echo "audit-log: a run id is required" 1>&2
    return 1
  fi
  local dir; dir="$(_audit_dir)"
  if [ ! -d "$dir" ]; then
    echo "audit-log: no audit dir at $dir" 1>&2
    return 0
  fi

  # Collect monthly files in chronological (lexical) order; tolerate none.
  # Use the portable [ -e ] glob-guard rather than `shopt nullglob`, so sourcing
  # this helper never mutates the caller's shell options.
  local files=() f
  for f in "$dir"/audit-*.jsonl; do
    [ -e "$f" ] || continue
    files[${#files[@]}]="$f"
  done
  if [ ${#files[@]} -eq 0 ]; then
    echo "audit-log: no audit files in $dir" 1>&2
    return 0
  fi

  # Parse each monthly file INDEPENDENTLY (one `jq -R -s` per file) and emit the
  # record streams in chronological (lexical) file order. parse_jsonl's "tolerate
  # one partial trailing line" guarantee is per-FILE: `split("\n")` only puts a
  # fragment in the LAST element of THAT file's own lines. A single
  # `jq -R -s "${files[@]}"` would slurp every file into ONE string, so the
  # tolerance would cover only the last file lexically — an EARLIER month left with
  # an unterminated trailing line (an out-of-band truncation; the writer's atomic
  # append no longer leaves one on crash) would fuse onto the next month's first
  # line and destroy an otherwise-valid
  # record on read. Looping keeps each file's own last line in its lenient slot, so
  # every complete record reads back regardless of which month was torn. A malformed
  # BODY line in any file makes that file's jq exit non-zero; jq is the sole command
  # in the pipeline, so `if !` keys directly on its exit and adds the `audit-log:`
  # prefix (jq's own detail still reaches STDERR).
  local f
  for f in "${files[@]}"; do
    if ! jq -R -s --arg rid "$rid" "$(_audit_fixmu_program)
$(_audit_jsonl_parse_program)
parse_jsonl | select(.run_id == \$rid) | .before |= fixmu | .after |= fixmu" "$f"; then
      echo "audit-log: failed to format records from $f" 1>&2
      return 1
    fi
  done
}

# --- CLI dispatch (only when executed directly, never when sourced) ----------

# _audit_cli_usage
#   Print the CLI usage block to STDERR. Shared by the help arm and the
#   missing-run-id guard so both emit identical text. Defining it at load is a
#   pure function definition — no side effect — the same sourceable contract the
#   rest of this file keeps.
_audit_cli_usage() {
  cat 1>&2 <<'USAGE'
usage: bin/audit-log.sh last [N]      # last N records (default 10) for the current UTC month
       bin/audit-log.sh run <run_id>  # all records for a run id, across every month
Both modes format milliunit amounts (÷1000) for display and print to STDOUT.
USAGE
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -u
  cmd="${1:-}"
  case "$cmd" in
    last) shift; _audit_read_last "${1:-10}" ;;
    run)
      # A missing run id is a usage error: exit 2 to match the unknown-command
      # and no-command arms, rather than falling through to _audit_read_run's
      # empty-id guard (which `return 1`s — an inconsistent CLI exit contract).
      shift
      if [ -z "${1:-}" ]; then
        echo "audit-log: 'run' requires a run id" 1>&2
        _audit_cli_usage
        exit 2
      fi
      _audit_read_run "$1"
      ;;
    ""|-h|--help|help)
      _audit_cli_usage
      exit 2 ;;
    *) echo "audit-log: unknown command: $cmd" 1>&2; exit 2 ;;
  esac
fi
