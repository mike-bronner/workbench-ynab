#!/usr/bin/env bash
# Unit tests for bin/audit-log.sh — the append-only write-back audit log.
# Run directly: tests/unit/test-audit-log.sh
#
# Style mirrors tests/unit/test-config.sh: raw bash, `set -u`, PASS/FAIL
# counters, a mktemp sandbox, and a non-zero exit when anything fails. The
# writer is exercised in isolation (no YNAB) by sourcing the helper and calling
# its functions, exactly as test-config.sh sources bin/config.sh.
#
# Requires jq (the helper itself requires jq); skips with a clear message if absent.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$REPO_ROOT/bin/audit-log.sh"
PASS=0
FAIL=0

if ! command -v jq >/dev/null 2>&1; then
  echo "audit-log tests: jq not found on PATH — cannot run" 1>&2
  exit 1
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1)); echo "  ✅ $desc"
  else
    FAIL=$((FAIL + 1)); echo "  ❌ $desc — expected: [$expected] got: [$actual]"
  fi
}

assert_empty() {
  local desc="$1" actual="$2"
  if [ -z "$actual" ]; then
    PASS=$((PASS + 1)); echo "  ✅ $desc"
  else
    FAIL=$((FAIL + 1)); echo "  ❌ $desc — expected empty, got: [$actual]"
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

# Source the helper under test (defines functions; no side effects at load).
# shellcheck source=/dev/null
source "$HELPER"

# Deterministic fixtures.
CATEGORIZE_OP='{"id":"op-cat-1","type":"categorize","budget_id":"b1","transaction_id":"txn-1","before":{"category_id":null,"category_name":null},"after":{"category_id":"c9","category_name":"Groceries"},"rationale":"reclassify","risk":"low"}'
CATEGORIZE_RES='{"tool":"mcp__ynab__ynab_update_transaction","status":"success","schema_version":"1.0.0","run_id":"run-A"}'
ALLOCATE_OP='{"id":"op-alloc-1","type":"allocate","budget_id":"b1","category_id":"cat-7","month":"2026-06-01","before":{"budgeted":250000},"after":{"budgeted":300000},"rationale":"top up","risk":"low"}'
ALLOCATE_RES='{"tool":"mcp__ynab__ynab_update_category","status":"success","schema_version":"1.0.0","run_id":"run-A"}'
RECONCILE_OP='{"id":"op-rec-1","type":"reconcile","budget_id":"b1","account_id":"acct-1","transaction_ids":["t1","t2"],"before":{"cleared_balance":100000,"reconciled_balance":90000},"after":{"reconciled_balance":100000},"rationale":"month-end","risk":"low"}'
RECONCILE_RES='{"tool":"mcp__ynab__ynab_reconcile_account","status":"success","schema_version":"1.0.0","run_id":"run-B"}'

# ---------------------------------------------------------------------------
echo "AC: a normal operation appends one record with all required fields:"
export YNAB_AUDIT_DIR="$SANDBOX/p1"
export YNAB_AUDIT_MONTH="2026-06"
export YNAB_AUDIT_TIMESTAMP="2026-06-15T12:00:00Z"

stdout="$(_audit_append "$CATEGORIZE_OP" "$CATEGORIZE_RES" false)"; rc=$?
assert_eq    "_audit_append exit code is 0"                "0" "$rc"
assert_empty "writer prints nothing to STDOUT"            "$stdout"

FILE="$YNAB_AUDIT_DIR/audit-2026-06.jsonl"
assert_eq    "monthly file created at audit-YYYY-MM.jsonl" "1" "$([ -f "$FILE" ] && echo 1 || echo 0)"
assert_eq    "exactly one record appended"                "1" "$(wc -l < "$FILE" | tr -d ' ')"

REC="$(head -1 "$FILE")"
assert_jq "record has all 11 required fields" "$REC" '
  has("timestamp") and has("schema_version") and has("run_id")
  and has("operation_id") and has("operation_type") and has("target_entity_ids")
  and has("before") and has("after") and has("tool")
  and has("result_status") and has("dry_run")'
assert_eq "timestamp is ISO 8601 + Z"        "2026-06-15T12:00:00Z" "$(printf '%s' "$REC" | jq -r '.timestamp')"
assert_eq "schema_version from change-set"   "1.0.0"                "$(printf '%s' "$REC" | jq -r '.schema_version')"
assert_eq "run_id from change-set source"    "run-A"                "$(printf '%s' "$REC" | jq -r '.run_id')"
assert_eq "operation_id from operation"      "op-cat-1"             "$(printf '%s' "$REC" | jq -r '.operation_id')"
assert_eq "operation_type from operation"    "categorize"          "$(printf '%s' "$REC" | jq -r '.operation_type')"
assert_eq "tool is the namespaced MCP tool"  "mcp__ynab__ynab_update_transaction" "$(printf '%s' "$REC" | jq -r '.tool')"
assert_eq "result_status from result"        "success"             "$(printf '%s' "$REC" | jq -r '.result_status')"
assert_jq "dry_run is boolean false"         "$REC" '.dry_run == false'
assert_jq "target_entity_ids = [transaction_id]" "$REC" '.target_entity_ids == ["txn-1"]'
assert_jq "before stored verbatim"           "$REC" '.before == {"category_id":null,"category_name":null}'
assert_jq "after stored verbatim"            "$REC" '.after == {"category_id":"c9","category_name":"Groceries"}'

# ---------------------------------------------------------------------------
echo "AC: dry-run operations are written with dry_run:true:"
export YNAB_AUDIT_TIMESTAMP="2026-06-15T12:05:00Z"
_audit_append "$CATEGORIZE_OP" '{"tool":"mcp__ynab__ynab_update_transaction","status":"dry_run","schema_version":"1.0.0","run_id":"run-A"}' true
assert_eq "two records now in the file"      "2" "$(wc -l < "$FILE" | tr -d ' ')"
DRY_REC="$(tail -1 "$FILE")"
assert_jq "dry-run record has dry_run:true"  "$DRY_REC" '.dry_run == true'
assert_eq "dry-run record records its status" "dry_run" "$(printf '%s' "$DRY_REC" | jq -r '.result_status')"

# ---------------------------------------------------------------------------
echo "AC: append-only — earlier lines are never rewritten or truncated:"
FIRST_BEFORE="$(head -1 "$FILE")"
export YNAB_AUDIT_TIMESTAMP="2026-06-15T12:10:00Z"
_audit_append "$ALLOCATE_OP" "$ALLOCATE_RES" false
assert_eq "three records after another append" "3" "$(wc -l < "$FILE" | tr -d ' ')"
FIRST_AFTER="$(head -1 "$FILE")"
assert_eq "first line byte-identical after later appends" "$FIRST_BEFORE" "$FIRST_AFTER"

# ---------------------------------------------------------------------------
echo "AC: writing to a non-existent audit dir creates it:"
export YNAB_AUDIT_DIR="$SANDBOX/brand/new/nested"
export YNAB_AUDIT_MONTH="2026-06"
assert_eq "audit dir does not exist yet"  "0" "$([ -d "$YNAB_AUDIT_DIR" ] && echo 1 || echo 0)"
_audit_append "$CATEGORIZE_OP" "$CATEGORIZE_RES" false; rc=$?
assert_eq "append into absent dir succeeds" "0" "$rc"
assert_eq "audit dir created on first write" "1" "$([ -d "$YNAB_AUDIT_DIR" ] && echo 1 || echo 0)"
assert_eq "monthly file created on first write" "1" "$([ -f "$YNAB_AUDIT_DIR/audit-2026-06.jsonl" ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
echo "target_entity_ids for a reconcile op = [account_id] + transaction_ids:"
export YNAB_AUDIT_DIR="$SANDBOX/p3"
export YNAB_AUDIT_MONTH="2026-06"
export YNAB_AUDIT_TIMESTAMP="2026-06-15T13:00:00Z"
_audit_append "$RECONCILE_OP" "$RECONCILE_RES" false
RECREC="$(head -1 "$SANDBOX/p3/audit-2026-06.jsonl")"
assert_jq "target_entity_ids = [account_id, txn ids…]" "$RECREC" '.target_entity_ids == ["acct-1","t1","t2"]'

# ---------------------------------------------------------------------------
echo "read helper: last N returns the last N, milliunits ÷ 1000 for display:"
export YNAB_AUDIT_DIR="$SANDBOX/p4"
export YNAB_AUDIT_MONTH="2026-06"
export YNAB_AUDIT_TIMESTAMP="2026-06-15T14:00:00Z"
_audit_append "$CATEGORIZE_OP" "$CATEGORIZE_RES" false
export YNAB_AUDIT_TIMESTAMP="2026-06-15T14:01:00Z"
_audit_append "$ALLOCATE_OP" "$ALLOCATE_RES" false
LAST_OUT="$(_audit_read_last 1)"
assert_jq "last 1 returns the most recent (allocate) record" "$LAST_OUT" '.operation_id == "op-alloc-1"'
assert_jq "allocate before.budgeted shown as 250 (÷1000)"    "$LAST_OUT" '.before.budgeted == 250'
assert_jq "allocate after.budgeted shown as 300 (÷1000)"     "$LAST_OUT" '.after.budgeted == 300'
LAST2_COUNT="$(_audit_read_last 2 | jq -s 'length')"
assert_eq "last 2 returns two records" "2" "$LAST2_COUNT"

# ---------------------------------------------------------------------------
echo "read helper: by run_id filters across ALL monthly files:"
export YNAB_AUDIT_DIR="$SANDBOX/p5"
# run-A record in May
export YNAB_AUDIT_MONTH="2026-05"; export YNAB_AUDIT_TIMESTAMP="2026-05-20T10:00:00Z"
_audit_append "$CATEGORIZE_OP" "$CATEGORIZE_RES" false
# run-A record in June + a run-B record in June (different run id)
export YNAB_AUDIT_MONTH="2026-06"; export YNAB_AUDIT_TIMESTAMP="2026-06-10T10:00:00Z"
_audit_append "$ALLOCATE_OP" "$ALLOCATE_RES" false
export YNAB_AUDIT_TIMESTAMP="2026-06-11T10:00:00Z"
_audit_append "$RECONCILE_OP" "$RECONCILE_RES" false
assert_eq "two separate monthly files exist" "2" "$(ls "$SANDBOX/p5"/audit-*.jsonl | wc -l | tr -d ' ')"
RUNA_OUT="$(_audit_read_run run-A)"
assert_eq "run-A matches two records across both months" "2" "$(printf '%s' "$RUNA_OUT" | jq -s 'length')"
assert_jq "run-A results are all run-A" "$RUNA_OUT" '.run_id == "run-A"'
assert_jq "run_id read also divides milliunits (allocate)" "$(printf '%s' "$RUNA_OUT" | jq -s '.[] | select(.operation_id=="op-alloc-1")')" '.after.budgeted == 300'
RUNB_COUNT="$(_audit_read_run run-B | jq -s 'length')"
assert_eq "run-B matches exactly one record" "1" "$RUNB_COUNT"

# ---------------------------------------------------------------------------
echo "diagnostics go to STDERR, never STDOUT; invalid JSON fails cleanly:"
export YNAB_AUDIT_DIR="$SANDBOX/p6"
export YNAB_AUDIT_MONTH="2026-06"
out="$(_audit_append "this is not json" "$CATEGORIZE_RES" false 2>/dev/null)"; rc=$?
assert_eq    "invalid operation JSON returns non-zero"  "1" "$rc"
assert_empty "invalid input prints nothing to STDOUT"   "$out"
err="$(_audit_append "this is not json" "$CATEGORIZE_RES" false 2>&1 1>/dev/null)"
assert_contains "diagnostic names audit-log on STDERR"  "$err" "audit-log:"
assert_eq    "no file written on invalid input"          "0" "$([ -f "$SANDBOX/p6/audit-2026-06.jsonl" ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
echo "CLI mode: read helper runs as a subcommand; bad usage exits 2:"
export YNAB_AUDIT_DIR="$SANDBOX/p7"
export YNAB_AUDIT_MONTH="2026-06"
export YNAB_AUDIT_TIMESTAMP="2026-06-15T15:00:00Z"
_audit_append "$ALLOCATE_OP" "$ALLOCATE_RES" false
CLI_OUT="$(bash "$HELPER" last 1)"
assert_jq "CLI 'last' prints the formatted record" "$CLI_OUT" '.before.budgeted == 250'
bash "$HELPER" bogus >/dev/null 2>&1; rc=$?
assert_eq "CLI unknown command exits 2" "2" "$rc"
bash "$HELPER" >/dev/null 2>&1; rc=$?
assert_eq "CLI with no args prints usage and exits 2" "2" "$rc"

echo ""
echo "audit log: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
