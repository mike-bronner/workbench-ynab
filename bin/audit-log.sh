#!/usr/bin/env bash
#
# bin/audit-log.sh — append-only audit log for applied YNAB write-back changes.
#
# WHAT THIS IS
#   The evidence trail for approval-gated write-back (M4). For every operation
#   the apply executor (M4-4) acts on — real or dry-run — this appends ONE
#   structured JSONL record capturing what changed, when, the before/after
#   snapshots (raw milliunits), the namespaced MCP tool invoked, and the call
#   status. Mike can later review, reverse, or dispute any mutation, and a
#   misbehaving write path leaves a paper trail for debugging.
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
#   Append-only is trivial and crash-safe with JSONL: a new record is one
#   `>>` of a newline-terminated line — no read, no parse, no rewrite of what is
#   already on disk, and a process killed mid-write can at worst leave one
#   trailing partial line that readers skip. A single JSON array would force a
#   read-modify-write of the whole file on every append (O(n) and not crash-safe:
#   a truncated rewrite loses the entire history). Append-only integrity is the
#   whole point of an audit log, so JSONL is the correct shape.
#
# THE WRITER CONTRACT — _audit_append <operation_json> <result_json> <dry_run>
#   operation_json  The change-set operation (see assets/changeset-schema.json):
#                   { id, type, transaction_id|category_id|account_id|transaction_ids,
#                     before{…}, after{…}, … }. before/after are stored VERBATIM,
#                     in raw milliunits — the read helper divides by 1000 only for
#                     human display.
#   result_json     The apply executor's call descriptor, carrying the MCP-call
#                   outcome plus the change-set provenance it knows:
#                     { tool, status, schema_version, run_id }
#                   tool   = namespaced MCP tool invoked (e.g. mcp__ynab__ynab_update_transaction)
#                   status = MCP call status (success | error | dry_run | …)
#                   schema_version = change-set envelope schema_version (provenance)
#                   run_id = change-set `source` (the review run id, or "manual")
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

# --- writer -----------------------------------------------------------------

# _audit_append <operation_json> <result_json> <dry_run>
#   Append exactly one JSONL record built from the three inputs. Pure: the only
#   side effect is the append. The audit dir and monthly file are created on
#   first write if absent. Append-only — never rewrites, truncates, or seeks.
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
  # category names, account and transaction ids — so it must NOT be world-readable
  # by default. Restrict perms at creation: the audit dir lands 0700 and each
  # record file 0600. `umask 077` is scoped to a subshell so sourcing this helper
  # never mutates the caller's umask (the same no-side-effects-at-load contract the
  # rest of this file keeps); `-m 700` pins the dir mode explicitly even where the
  # caller's umask is already permissive. (No sibling helper sets modes because
  # none of them write sensitive data — this one does.)
  local dir; dir="$(_audit_dir)"
  if ! ( umask 077; mkdir -p -m 700 "$dir" ) 2>/dev/null; then
    echo "audit-log: cannot create audit dir: $dir" 1>&2
    return 1
  fi

  if ! ( umask 077; printf '%s\n' "$record" >> "$(_audit_file)" ); then
    echo "audit-log: append failed: $(_audit_file)" 1>&2
    return 1
  fi
}

# --- read helpers -----------------------------------------------------------

# _audit_read_last [N]
#   Print the last N records (default 10) from the CURRENT month's file, with
#   milliunit amounts divided by 1000 for display, to STDOUT. Diagnostics (e.g.
#   no file yet) go to STDERR; absence is not an error.
_audit_read_last() {
  local n="${1:-10}" file
  file="$(_audit_file)"
  if [ ! -f "$file" ]; then
    echo "audit-log: no audit file for $(_audit_month) at $file" 1>&2
    return 0
  fi
  tail -n "$n" "$file" | jq "$(_audit_fixmu_program)
.before |= fixmu | .after |= fixmu"
}

# _audit_read_run <run_id>
#   Print every record whose run_id matches, across ALL monthly files in the
#   audit dir (chronological order), with milliunit amounts divided by 1000 for
#   display, to STDOUT.
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

  cat "${files[@]}" | jq --arg rid "$rid" "$(_audit_fixmu_program)
select(.run_id == \$rid) | .before |= fixmu | .after |= fixmu"
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
