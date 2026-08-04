#!/usr/bin/env bash
# Unit tests for bin/audit-log.sh — the append-only write-back audit log.
# Run directly: tests/unit/audit-log.test.sh
#
# Style mirrors tests/unit/config.test.sh: raw bash, `set -u`, PASS/FAIL
# counters, a mktemp sandbox, and a non-zero exit when anything fails. The
# writer is exercised in isolation (no YNAB) by sourcing the helper and calling
# its functions, exactly as config.test.sh sources bin/config.sh.
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

# Deterministic fixtures. Every result fixture's `status` uses the trail's
# documented result_status vocabulary: the apply executor's frozen four-value
# STATUS enum (applied | skipped-stale | blocked | error —
# assets/apply-executor.js) plus the delete path's pending_delete intent
# sentinel (assets/delete-duplicate.js, two-phase trail #50). This matches the
# real contract: _audit_append is a trusted pass-through fed only these
# normalized statuses, never a raw MCP call status like `success`.
CATEGORIZE_OP='{"id":"op-cat-1","type":"categorize","budget_id":"b1","transaction_id":"txn-1","before":{"category_id":null,"category_name":null},"after":{"category_id":"c9","category_name":"Groceries"},"rationale":"reclassify","risk":"low"}'
CATEGORIZE_RES='{"tool":"mcp__ynab__ynab_update_transaction","status":"applied","schema_version":"1.0.0","run_id":"run-A"}'
ALLOCATE_OP='{"id":"op-alloc-1","type":"allocate","budget_id":"b1","category_id":"cat-7","month":"2026-06-01","before":{"budgeted":250000},"after":{"budgeted":300000},"rationale":"top up","risk":"low"}'
ALLOCATE_RES='{"tool":"mcp__ynab__ynab_update_category","status":"applied","schema_version":"1.0.0","run_id":"run-A"}'
RECONCILE_OP='{"id":"op-rec-1","type":"reconcile","budget_id":"b1","account_id":"acct-1","transaction_ids":["t1","t2"],"before":{"cleared_balance":100000,"reconciled_balance":90000},"after":{"reconciled_balance":100000},"rationale":"month-end","risk":"low"}'
RECONCILE_RES='{"tool":"mcp__ynab__ynab_reconcile_account","status":"applied","schema_version":"1.0.0","run_id":"run-B"}'
# delete_duplicate carries the `amount` milliunit field (a REQUIRED before-field per
# assets/changeset-schema.json:255) — the fourth and final field fixmu divides. This
# fixture carries `amount` in BOTH before and after so the ÷1000 read transform is
# proven in each position (the real op's after is {deleted:true}; here we add an
# amount to exercise the after branch of fixmu too — the writer stores both verbatim).
DELETE_OP='{"id":"op-del-1","type":"delete_duplicate","budget_id":"b1","transaction_id":"txn-dup-1","before":{"amount":-54990,"date":"2026-06-12","payee_name":"Amazon","category_name":"Shopping","import_id":"YNAB:-54990:2026-06-12:1"},"after":{"amount":12340,"deleted":true},"rationale":"exact duplicate","risk":"destructive"}'
DELETE_RES='{"tool":"mcp__ynab__ynab_delete_transaction","status":"applied","schema_version":"1.0.0","run_id":"run-C"}'

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
assert_jq "record has all 13 required fields" "$REC" '
  has("timestamp") and has("schema_version") and has("run_id")
  and has("operation_id") and has("operation_type") and has("target_entity_ids")
  and has("before") and has("after") and has("tool")
  and has("result_status") and has("error_class") and has("applied_state")
  and has("dry_run")'
# A normal (non-error) op carries null in both auth-failure fields — they are
# populated only when the executor stamps an errored op (GAP-8 / #50).
assert_jq "error_class is null on a normal op"   "$REC" '.error_class == null'
assert_jq "applied_state is null on a normal op" "$REC" '.applied_state == null'
assert_eq "timestamp is ISO 8601 + Z"        "2026-06-15T12:00:00Z" "$(printf '%s' "$REC" | jq -r '.timestamp')"
assert_eq "schema_version from change-set"   "1.0.0"                "$(printf '%s' "$REC" | jq -r '.schema_version')"
assert_eq "run_id from change-set source"    "run-A"                "$(printf '%s' "$REC" | jq -r '.run_id')"
assert_eq "operation_id from operation"      "op-cat-1"             "$(printf '%s' "$REC" | jq -r '.operation_id')"
assert_eq "operation_type from operation"    "categorize"          "$(printf '%s' "$REC" | jq -r '.operation_type')"
assert_eq "tool is the namespaced MCP tool"  "mcp__ynab__ynab_update_transaction" "$(printf '%s' "$REC" | jq -r '.tool')"
assert_eq "result_status from result"        "applied"             "$(printf '%s' "$REC" | jq -r '.result_status')"
assert_jq "dry_run is boolean false"         "$REC" '.dry_run == false'
assert_jq "target_entity_ids = [transaction_id]" "$REC" '.target_entity_ids == ["txn-1"]'
assert_jq "before stored verbatim"           "$REC" '.before == {"category_id":null,"category_name":null}'
assert_jq "after stored verbatim"            "$REC" '.after == {"category_id":"c9","category_name":"Groceries"}'

# ---------------------------------------------------------------------------
echo "AC: dry-run operations are written with dry_run:true:"
export YNAB_AUDIT_TIMESTAMP="2026-06-15T12:05:00Z"
# A dry-run simulation arrives with the executor's normalized status `applied`
# (assets/apply-executor.js simulateResult) — the dry_run flag, not the status,
# is what marks it as a simulation.
dry_stdout="$(_audit_append "$CATEGORIZE_OP" '{"tool":"mcp__ynab__ynab_update_transaction","status":"applied","schema_version":"1.0.0","run_id":"run-A"}' true)"
assert_empty "dry-run writer prints nothing to STDOUT"   "$dry_stdout"
assert_eq "two records now in the file"      "2" "$(wc -l < "$FILE" | tr -d ' ')"
DRY_REC="$(tail -1 "$FILE")"
assert_jq "dry-run record has dry_run:true"  "$DRY_REC" '.dry_run == true'
assert_eq "dry-run record keeps the normalized status (applied)" "applied" "$(printf '%s' "$DRY_REC" | jq -r '.result_status')"

# ---------------------------------------------------------------------------
echo "AC: append-only — earlier lines are never rewritten or truncated:"
FIRST_BEFORE="$(head -1 "$FILE")"
export YNAB_AUDIT_TIMESTAMP="2026-06-15T12:10:00Z"
_audit_append "$ALLOCATE_OP" "$ALLOCATE_RES" false
assert_eq "three records after another append" "3" "$(wc -l < "$FILE" | tr -d ' ')"
FIRST_AFTER="$(head -1 "$FILE")"
assert_eq "first line byte-identical after later appends" "$FIRST_BEFORE" "$FIRST_AFTER"

# ---------------------------------------------------------------------------
# GAP-8 / #50: an errored op's result carries error_class + applied_state, and the
# writer persists them verbatim so a later resume (#48) can reason about failed ops.
echo "auth-failure fields: an errored op records error_class + applied_state:"
export YNAB_AUDIT_DIR="$SANDBOX/errfields"
export YNAB_AUDIT_MONTH="2026-06"
export YNAB_AUDIT_TIMESTAMP="2026-06-15T12:20:00Z"
ERR_RES='{"tool":"mcp__ynab__ynab_update_transaction","status":"error","schema_version":"1.0.0","run_id":"run-A","error_class":"auth_revoked","applied_state":"not_applied"}'
_audit_append "$CATEGORIZE_OP" "$ERR_RES" false
EFILE="$SANDBOX/errfields/audit-2026-06.jsonl"
ERR_REC="$(head -1 "$EFILE")"
assert_eq "errored op result_status is error"        "error"        "$(printf '%s' "$ERR_REC" | jq -r '.result_status')"
assert_eq "error_class persisted verbatim"           "auth_revoked" "$(printf '%s' "$ERR_REC" | jq -r '.error_class')"
assert_eq "applied_state persisted verbatim"         "not_applied"  "$(printf '%s' "$ERR_REC" | jq -r '.applied_state')"

# ---------------------------------------------------------------------------
# Writer hardening (issue #57, Mike's call): the writer must NEVER leave a
# truncated line. Each record is appended as a single atomic, newline-terminated
# write, so a crash leaves either the whole record or nothing — and, as
# belt-and-suspenders, a new record is never FUSED onto a pre-existing dangling
# fragment (one left by an out-of-band truncation, not by this writer). This is the
# root-cause fix for the multi-file read_run crash bug: if no file ever ends
# mid-record, an earlier month's fragment can't fuse onto the next month's record.
echo "writer hardening: every append leaves the file newline-terminated:"
export YNAB_AUDIT_DIR="$SANDBOX/harden-nl"
export YNAB_AUDIT_MONTH="2026-06"
export YNAB_AUDIT_TIMESTAMP="2026-06-18T09:00:00Z"
_audit_append "$CATEGORIZE_OP" "$CATEGORIZE_RES" false
export YNAB_AUDIT_TIMESTAMP="2026-06-18T09:01:00Z"
_audit_append "$ALLOCATE_OP" "$ALLOCATE_RES" false
HN_FILE="$YNAB_AUDIT_DIR/audit-2026-06.jsonl"
# `tail -c1` is empty iff the last byte is a newline (command substitution strips
# it) — so an empty result proves the file ends cleanly, no dangling line.
assert_empty "file ends in a newline after appends (no truncated line)" "$(tail -c1 "$HN_FILE")"
assert_eq    "two complete records, one per line" "2" "$(wc -l < "$HN_FILE" | tr -d ' ')"

echo "writer hardening: an append never FUSES onto a pre-existing dangling fragment:"
export YNAB_AUDIT_DIR="$SANDBOX/harden-fuse"
export YNAB_AUDIT_MONTH="2026-06"
mkdir -p "$YNAB_AUDIT_DIR"
HF_FILE="$YNAB_AUDIT_DIR/audit-2026-06.jsonl"
# Simulate an out-of-band truncation: a dangling, unterminated fragment (no newline).
printf '%s' '{"operation_id":"op-danglin' > "$HF_FILE"
export YNAB_AUDIT_TIMESTAMP="2026-06-18T09:05:00Z"
_audit_append "$ALLOCATE_OP" "$ALLOCATE_RES" false; rc=$?
assert_eq "append onto a dangling fragment succeeds" "0" "$rc"
# The new record must be its OWN last line — never fused onto the fragment.
assert_jq "new record is a clean line, not fused with the fragment" "$(tail -1 "$HF_FILE")" '.operation_id == "op-alloc-1"'
# The writer must leave the file newline-terminated (no new dangling line).
assert_empty "writer leaves the file newline-terminated" "$(tail -c1 "$HF_FILE")"
# The fragment is isolated on its own (now-terminated) line, not merged into the
# new record. A regression that dropped the no-fuse guard would produce a single
# fused line `{"operation_id":"op-danglin{"...alloc...}` and fail this.
assert_eq "the fragment is isolated, not merged into the new record" "1" \
  "$(grep -c '^{"operation_id":"op-danglin$' "$HF_FILE")"
# The new record reads back cleanly through the helper (proving it parses on its own).
HF_LAST="$(_audit_read_last 1 2>/dev/null)"
assert_jq "the un-fused new record reads back through the helper" "$HF_LAST" '.operation_id == "op-alloc-1"'

# ---------------------------------------------------------------------------
# Durability (#275): every record must be flushed to stable storage before the
# writer reports success — not merely handed to the page cache.
#
# These tests observe the shim's BEHAVIOUR, never its source text. A test that
# grepped bin/audit-log.sh for "fsync"/"python3" would pass against a writer that
# merely mentions them, which is exactly the vacuous shape this AC forbids.
echo "AC (#275): each record is fsync'd to stable storage before the writer returns:"
export YNAB_AUDIT_DIR="$SANDBOX/fsync"
export YNAB_AUDIT_MONTH="2026-06"
export YNAB_AUDIT_TIMESTAMP="2026-06-20T10:00:00Z"
FS_PROBE_DIR="$SANDBOX/fsync-probe"
FS_PROBE_LOG="$SANDBOX/fsync-calls.log"
mkdir -p "$FS_PROBE_DIR"
rm -f "$FS_PROBE_LOG"
# python3's `site` module imports `sitecustomize` automatically at interpreter
# startup from any directory on PYTHONPATH. That lets us wrap os.fsync INSIDE the
# real shim process — the writer runs its own unmodified program, and we record
# each call before delegating to the real syscall. Deleting `os.fsync(fd)` from
# _audit_fsync_append_program leaves this log empty and reddens the assertions
# below; that is the mutation these tests exist to catch.
cat > "$FS_PROBE_DIR/sitecustomize.py" <<'PY'
import os
_real_fsync = os.fsync
def _probe(fd):
    with open(os.environ["AUDIT_FSYNC_PROBE_LOG"], "a") as fh:
        fh.write("fsync %d\n" % os.fstat(fd).st_size)
    return _real_fsync(fd)
os.fsync = _probe
PY
export PYTHONPATH="$FS_PROBE_DIR"
export AUDIT_FSYNC_PROBE_LOG="$FS_PROBE_LOG"
_audit_append "$CATEGORIZE_OP" "$CATEGORIZE_RES" false; rc=$?
unset PYTHONPATH AUDIT_FSYNC_PROBE_LOG
FS_FILE="$YNAB_AUDIT_DIR/audit-2026-06.jsonl"
assert_eq "append succeeds with the fsync probe attached" "0" "$rc"
assert_eq "the writer fsync'd exactly once for the one record" "1" \
  "$([ -f "$FS_PROBE_LOG" ] && wc -l < "$FS_PROBE_LOG" | tr -d ' ' || echo 0)"
# The probe records the descriptor's size AT fsync time. It equalling the final
# file size proves the fsync happened AFTER the record was written, not before —
# a shim that fsync'd an empty fd and then wrote would report 0 here.
assert_eq "the fsync ran AFTER the write (fd size at fsync = final file size)" \
  "$(wc -c < "$FS_FILE" | tr -d ' ')" \
  "$(awk '{print $2}' "$FS_PROBE_LOG" 2>/dev/null | tr -d ' ')"
# One fsync PER RECORD, not one per run: a second append must flush again.
export YNAB_AUDIT_TIMESTAMP="2026-06-20T10:01:00Z"
export PYTHONPATH="$FS_PROBE_DIR"
export AUDIT_FSYNC_PROBE_LOG="$FS_PROBE_LOG"
_audit_append "$ALLOCATE_OP" "$ALLOCATE_RES" false
unset PYTHONPATH AUDIT_FSYNC_PROBE_LOG
assert_eq "a second record triggers a second fsync (per-record, not per-run)" "2" \
  "$(wc -l < "$FS_PROBE_LOG" | tr -d ' ')"
assert_eq "both records are on disk, one line each" "2" "$(wc -l < "$FS_FILE" | tr -d ' ')"

echo "AC (#275): the append FAILS CLOSED when the fsync shim is unavailable:"
export YNAB_AUDIT_DIR="$SANDBOX/nopy"
export YNAB_AUDIT_MONTH="2026-06"
export YNAB_AUDIT_TIMESTAMP="2026-06-20T10:02:00Z"
# PATH-isolation, mirroring config.test.sh's test_jq_absent: an allowlist dir
# holding every tool the writer legitimately needs EXCEPT python3, so
# `command -v python3` genuinely fails. The command-substitution subshell confines
# the PATH change, leaving the rest of the suite untouched.
NOPY_BIN="$SANDBOX/nopy-bin"
mkdir -p "$NOPY_BIN"
for t in jq mkdir chmod tail; do ln -sf "$(command -v "$t")" "$NOPY_BIN/$t"; done
NOPY_ERR="$(PATH="$NOPY_BIN" _audit_append "$CATEGORIZE_OP" "$CATEGORIZE_RES" false 2>&1)"; rc=$?
assert_eq       "append exits non-zero when python3 is absent" "1" "$rc"
assert_contains "the error names python3"    "$NOPY_ERR" "python3"
assert_contains "the error names the reason" "$NOPY_ERR" "durability guarantee"
# Fail CLOSED means a refused append leaves NO trace — neither a record the writer
# cannot promise is durable, nor the directory it would have gone in. A fail-OPEN
# regression (plain `>>` when python3 is missing) creates the file; a guard placed
# after the `mkdir -p` creates the dir. Both redden here.
assert_eq "no record file is created when the flush cannot happen" "0" \
  "$([ -f "$YNAB_AUDIT_DIR/audit-2026-06.jsonl" ] && echo 1 || echo 0)"
assert_eq "not even the audit dir is created — the refusal happens first" "0" \
  "$([ -d "$YNAB_AUDIT_DIR" ] && echo 1 || echo 0)"

echo "AC (#275): a failing shim fails the append (never a silent undurable write):"
export YNAB_AUDIT_DIR="$SANDBOX/shimfail"
export YNAB_AUDIT_MONTH="2026-06"
mkdir -p "$YNAB_AUDIT_DIR/audit-2026-06.jsonl"   # a DIRECTORY where the log goes
SHIMFAIL_ERR="$(_audit_append "$CATEGORIZE_OP" "$CATEGORIZE_RES" false 2>&1)"; rc=$?
assert_eq       "append exits non-zero when the shim cannot open the file" "1" "$rc"
assert_contains "the error names the failed append" "$SHIMFAIL_ERR" "append failed"

echo "AC (#275): a SHORT write fails the append instead of fsyncing a torn record:"
export YNAB_AUDIT_DIR="$SANDBOX/shortwrite"
export YNAB_AUDIT_MONTH="2026-06"
export YNAB_AUDIT_TIMESTAMP="2026-06-20T10:05:00Z"
# A real short write needs ENOSPC, which isn't arrangeable portably. Same
# interception trick as the fsync probe instead: a sitecustomize that makes
# os.write consume only part of the buffer and return that short count, so the
# shim's `n != len(data)` branch actually executes. Deleting that branch makes the
# writer fsync a torn record and return 0 — reddening both assertions below.
SW_PROBE_DIR="$SANDBOX/shortwrite-probe"
mkdir -p "$SW_PROBE_DIR"
cat > "$SW_PROBE_DIR/sitecustomize.py" <<'PY'
import os
_real_write = os.write
def _short(fd, data):
    return _real_write(fd, data[:8])
os.write = _short
PY
SW_ERR="$(PYTHONPATH="$SW_PROBE_DIR" _audit_append "$CATEGORIZE_OP" "$CATEGORIZE_RES" false 2>&1)"; rc=$?
assert_eq       "append exits non-zero on a short write" "1" "$rc"
assert_contains "the shim names the short write"  "$SW_ERR" "short write"
assert_contains "the writer reports the failed append" "$SW_ERR" "append failed"

echo "AC (#275): a RAISED error in the shim fails the append (never a durable-looking success):"
# The short-write test above covers os.write returning a bad COUNT. This block
# covers the other half of the shim's failure surface: the STDIN read and the
# syscalls themselves RAISING. _audit_fsync_append_program wraps them in a bare
# try/finally with no `except`, so an exception must propagate to a non-zero exit
# — but nothing pinned that. A future `except OSError` that swallowed a real write
# error would fall straight through the `n != len(data)` check and report exit 0
# for a record that never reached the disk: the exact fail-open #275 exists to
# close, and invisible to every other test here (`sys.exit` raises SystemExit, a
# BaseException, so the short-write test's mechanism cannot catch it either).
# Faults are injected with the same sitecustomize/PYTHONPATH interception as the
# fsync probe, so the writer still runs its own unmodified program.
#
# Every failure branch of the shim is now covered: os.open raising (the failing-
# shim test above), a short os.write return (the short-write test above), and the
# STDIN read / os.write / os.fsync raising (below). The `finally`'s os.close is
# deliberately NOT pinned: it runs only after the record is already fsync'd and
# durable, so a failure there is a conservative false negative — it cannot break
# the durability contract ("exit 0 ⇒ the record is on stable storage"), which is
# what these tests exist to guard.
RAISE_ROOT="$SANDBOX/raise"
export YNAB_AUDIT_MONTH="2026-06"
export YNAB_AUDIT_TIMESTAMP="2026-06-20T10:06:00Z"

# run_with_fault <name> <sitecustomize-program>: inject the fault into the shim's
# own interpreter and run one append into its own audit dir. Sets RF_RC and RF_ERR
# for the assertions that follow.
run_with_fault() {
  local name="$1" program="$2" probe="$RAISE_ROOT/$1/probe"
  mkdir -p "$probe"
  printf '%s\n' "$program" > "$probe/sitecustomize.py"
  export YNAB_AUDIT_DIR="$RAISE_ROOT/$name/audit"
  RF_ERR="$(PYTHONPATH="$probe" _audit_append "$CATEGORIZE_OP" "$CATEGORIZE_RES" false 2>&1)"
  RF_RC=$?
}

run_with_fault write 'import os
def _raise(fd, data):
    raise OSError(5, "Input/output error")
os.write = _raise'
assert_eq       "append exits non-zero when os.write RAISES"      "1" "$RF_RC"
assert_contains "the writer reports the failed append (os.write)" "$RF_ERR" "append failed"

run_with_fault fsync 'import os
def _raise(fd):
    raise OSError(5, "Input/output error")
os.fsync = _raise'
assert_eq       "append exits non-zero when os.fsync RAISES — an unflushed record is NOT a success" \
  "1" "$RF_RC"
assert_contains "the writer reports the failed append (os.fsync)" "$RF_ERR" "append failed"

run_with_fault stdin 'import sys
class _Buffer:
    def read(self):
        raise OSError(5, "Input/output error")
class _Stdin:
    buffer = _Buffer()
sys.stdin = _Stdin()'
assert_eq       "append exits non-zero when the STDIN read RAISES" "1" "$RF_RC"
assert_contains "the writer reports the failed append (stdin)"     "$RF_ERR" "append failed"

echo "AC (#275): a record larger than a pipe buffer survives whole:"
export YNAB_AUDIT_DIR="$SANDBOX/bigrec"
export YNAB_AUDIT_MONTH="2026-06"
export YNAB_AUDIT_TIMESTAMP="2026-06-20T10:03:00Z"
# 100 000 bytes — past a pipe buffer (64 KB on Linux, 16 KB on macOS) and far past
# dd's 512-byte default block. What this pins is that the shim consumes its STDIN
# to EOF and writes ALL of it: a shim that handled only one buffer's worth (a bare
# `os.read(0, N)`, or `dd` with its default `bs`) would truncate the record here.
# It does NOT by itself rule out a correct multi-write loop — the write-count test
# below is what pins the SINGLE-write property.
#
# Sized under 128 KB deliberately. Linux caps a SINGLE argv entry at
# MAX_ARG_STRLEN (32 pages = 131 072 bytes), and _audit_append takes the operation
# JSON as one argument, so a larger fixture fails in the writer's own `jq` build —
# at the argv boundary, before the shim is ever reached. macOS has no per-argument
# cap, so a 200 KB fixture passed locally and failed on the Linux CI lane.
BIG_VALUE="$(head -c 100000 /dev/zero | tr '\0' 'A')"
BIG_OP="$(jq -cn --arg s "$BIG_VALUE" '{id:"op-big-1",type:"categorize",transaction_id:"txn-big",before:{category_name:null},after:{category_name:$s}}')"
_audit_append "$BIG_OP" "$CATEGORIZE_RES" false; rc=$?
BIG_FILE="$YNAB_AUDIT_DIR/audit-2026-06.jsonl"
assert_eq    "append of a 100 KB record succeeds"        "0" "$rc"
assert_eq    "the 100 KB record is exactly one line"     "1" "$(wc -l < "$BIG_FILE" | tr -d ' ')"
assert_empty "the 100 KB record ends in a newline"       "$(tail -c1 "$BIG_FILE")"
assert_eq    "the record round-trips byte-exact (no truncation)" "100000" \
  "$(jq -r '.after.category_name | length' < "$BIG_FILE")"

echo "AC (#275): the shim issues EXACTLY ONE write(2) per record:"
export YNAB_AUDIT_DIR="$SANDBOX/onewrite"
export YNAB_AUDIT_MONTH="2026-06"
export YNAB_AUDIT_TIMESTAMP="2026-06-20T10:07:00Z"
# THIS is the deterministic proof of the single-atomic-write property. The
# concurrency test below observes only the CONSEQUENCE of a split write — a torn
# line — and only when the kernel happens to interleave another writer's chunks
# between the two halves. On a fast local disk two sequential writes from one
# process usually still land contiguously, so that test lets a genuine split-write
# regression through most runs. This block pins the property itself, with the same
# sitecustomize/PYTHONPATH interception the fsync probe uses: wrap os.write, log
# every call with its fd and byte count, then assert the shim made exactly ONE
# call carrying the WHOLE record. Splitting _audit_fsync_append_program's append
# into two os.write calls reddens this on every run, on any disk, at any speed.
#
# fds 1 and 2 are filtered out: the assertions are about writes to the LOG FILE,
# and a stray diagnostic on stdout/stderr must not be counted as a record write.
OW_PROBE_DIR="$SANDBOX/onewrite-probe"
OW_LOG="$SANDBOX/onewrite-calls.log"
mkdir -p "$OW_PROBE_DIR"
rm -f "$OW_LOG"
cat > "$OW_PROBE_DIR/sitecustomize.py" <<'PY'
import os
_real_write = os.write
def _probe(fd, data):
    n = _real_write(fd, data)
    with open(os.environ["AUDIT_WRITE_PROBE_LOG"], "a") as fh:
        fh.write("%d %d\n" % (fd, n))
    return n
os.write = _probe
PY
# ow_calls: the probe's record-file writes, one "fd bytes" line each. No log means
# the shim never wrote at all — empty output, which reddens the counts below. An
# awk failure is NOT swallowed: it too yields empty output and a non-zero status.
ow_calls() {
  [ -f "$OW_LOG" ] || return 0
  awk '$1 != 1 && $1 != 2' "$OW_LOG"
}
PYTHONPATH="$OW_PROBE_DIR" AUDIT_WRITE_PROBE_LOG="$OW_LOG" \
  _audit_append "$CATEGORIZE_OP" "$CATEGORIZE_RES" false; rc=$?
OW_FILE="$YNAB_AUDIT_DIR/audit-2026-06.jsonl"
assert_eq "append succeeds with the os.write probe attached" "0" "$rc"
assert_eq "the shim issued EXACTLY ONE write(2) for the one record" "1" \
  "$(ow_calls | wc -l | tr -d ' ')"
# The one call must carry the whole record: bytes written = the record's size on
# disk. A two-call split reddens the count above AND this (two byte counts, each
# short), so neither half of the property can regress unnoticed.
assert_eq "that single write carried the WHOLE record (bytes written = file size)" \
  "$(wc -c < "$OW_FILE" | tr -d ' ')" \
  "$(ow_calls | awk '{print $2}' | tr -d ' ')"
# One write PER RECORD, not one per run — mirrors the per-record fsync assertion.
export YNAB_AUDIT_TIMESTAMP="2026-06-20T10:08:00Z"
PYTHONPATH="$OW_PROBE_DIR" AUDIT_WRITE_PROBE_LOG="$OW_LOG" \
  _audit_append "$ALLOCATE_OP" "$ALLOCATE_RES" false
assert_eq "a second record is a second single write (per-record, not per-run)" "2" \
  "$(ow_calls | wc -l | tr -d ' ')"
# A 100 KB record in ONE write. This is the deterministic form of the regression
# the big-record test above can only hint at: a block-wise copier (dd's 512-byte
# default, or any `while chunk` loop) would log many calls here, never one.
export YNAB_AUDIT_DIR="$SANDBOX/onewrite-big"
export YNAB_AUDIT_TIMESTAMP="2026-06-20T10:09:00Z"
rm -f "$OW_LOG"
OW_BIG_VALUE="$(head -c 100000 /dev/zero | tr '\0' 'C')"
OW_BIG_OP="$(jq -cn --arg s "$OW_BIG_VALUE" '{id:"op-onewrite-big",type:"categorize",transaction_id:"txn-ow",before:{},after:{category_name:$s}}')"
PYTHONPATH="$OW_PROBE_DIR" AUDIT_WRITE_PROBE_LOG="$OW_LOG" \
  _audit_append "$OW_BIG_OP" "$CATEGORIZE_RES" false; rc=$?
OW_BIG_FILE="$YNAB_AUDIT_DIR/audit-2026-06.jsonl"
assert_eq "append of a 100 KB record succeeds under the probe" "0" "$rc"
assert_eq "a 100 KB record is still EXACTLY ONE write(2) — never chunked" "1" \
  "$(ow_calls | wc -l | tr -d ' ')"
assert_eq "that single write carried all 100 KB (bytes written = file size)" \
  "$(wc -c < "$OW_BIG_FILE" | tr -d ' ')" \
  "$(ow_calls | awk '{print $2}' | tr -d ' ')"

echo "AC (#275): concurrent appends never interleave (secondary sanity check):"
export YNAB_AUDIT_DIR="$SANDBOX/concurrent"
export YNAB_AUDIT_MONTH="2026-06"
export YNAB_AUDIT_TIMESTAMP="2026-06-20T10:04:00Z"
mkdir -p "$YNAB_AUDIT_DIR"
CONC_FILE="$YNAB_AUDIT_DIR/audit-2026-06.jsonl"
# A SECONDARY check, not the proof of "one atomic write per record" — the
# write-count block above is that. O_APPEND makes each write(2) land at EOF
# atomically, so 8 simultaneous writers each issuing exactly ONE write produce 8
# intact lines. What this adds is the end-to-end property under real contention:
# the whole writer (jq build, no-fuse guard, shim) run 8 ways at once still yields
# 8 whole records. It is deliberately NOT relied on to catch a split write: doing
# so needs the kernel to actually interleave the halves, which a fast local disk
# usually does not, so it reddens on a real split only some of the time.
CONC_VALUE="$(head -c 100000 /dev/zero | tr '\0' 'B')"
for i in 1 2 3 4 5 6 7 8; do
  (
    conc_op="$(jq -cn --arg s "$CONC_VALUE" --arg id "op-conc-$i" \
      '{id:$id,type:"categorize",transaction_id:"txn-conc",before:{},after:{category_name:$s}}')"
    _audit_append "$conc_op" "$CATEGORIZE_RES" false
  ) &
done
wait
assert_eq "all 8 concurrent appends landed, one line each" "8" \
  "$(wc -l < "$CONC_FILE" | tr -d ' ')"
# `jq -s` parses the whole file as a stream of JSON values: any torn or fused line
# is a parse error, so a non-8 answer means a record was destroyed.
assert_eq "no line is torn — all 8 parse as JSON objects" "8" \
  "$(jq -s 'map(select(type == "object")) | length' < "$CONC_FILE" 2>/dev/null || echo -1)"
assert_eq "every operation_id survived exactly once" "8" \
  "$(jq -r '.operation_id' < "$CONC_FILE" 2>/dev/null | sort -u | wc -l | tr -d ' ')"
assert_eq "every record kept its full 100 KB payload" "8" \
  "$(jq -r 'select(.after.category_name | length == 100000) | .operation_id' < "$CONC_FILE" 2>/dev/null | wc -l | tr -d ' ')"

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
# Seed THREE records (oldest → newest) so `last N`'s truncation is genuinely
# proven: an oldest reconcile record that `last 2` MUST drop, then categorize,
# then allocate. With only two records a regression where `last N` ignored N and
# returned the whole file would still pass — three records make `tail -n N` bite.
export YNAB_AUDIT_TIMESTAMP="2026-06-15T13:59:00Z"
_audit_append "$RECONCILE_OP" "$RECONCILE_RES" false   # oldest — must be truncated by `last 2`
export YNAB_AUDIT_TIMESTAMP="2026-06-15T14:00:00Z"
_audit_append "$CATEGORIZE_OP" "$CATEGORIZE_RES" false
export YNAB_AUDIT_TIMESTAMP="2026-06-15T14:01:00Z"
_audit_append "$ALLOCATE_OP" "$ALLOCATE_RES" false     # newest
LAST_OUT="$(_audit_read_last 1)"
assert_jq "last 1 returns the most recent (allocate) record" "$LAST_OUT" '.operation_id == "op-alloc-1"'
# allocate carries only category_id (no transaction_id/account_id/transaction_ids),
# so this exercises the category_id-only branch of the target_entity_ids derivation
# (bin/audit-log.sh) — a regression dropping it to [] would otherwise pass the suite.
assert_jq "allocate target_entity_ids = [category_id]"       "$LAST_OUT" '.target_entity_ids == ["cat-7"]'
assert_jq "allocate before.budgeted shown as 250 (÷1000)"    "$LAST_OUT" '.before.budgeted == 250'
assert_jq "allocate after.budgeted shown as 300 (÷1000)"     "$LAST_OUT" '.after.budgeted == 300'
# `last 2` against a 3-record file must return EXACTLY the last two, in order (the
# categorize then allocate records) and MUST NOT include the older reconcile
# record — genuinely proving the `tail -n N` windowing for AC #7(a). A regression
# that ignored N and returned the whole file would surface op-rec-1 and fail here.
LAST2_OUT="$(_audit_read_last 2)"
assert_eq "last 2 returns exactly two records" "2" \
  "$(printf '%s' "$LAST2_OUT" | jq -s 'length')"
assert_eq "last 2 are the two newest in order, oldest reconcile dropped" \
  '["op-cat-1","op-alloc-1"]' \
  "$(printf '%s' "$LAST2_OUT" | jq -sc 'map(.operation_id)')"

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
assert_eq "two separate monthly files exist" "2" "$(find "$SANDBOX/p5" -name 'audit-*.jsonl' | wc -l | tr -d ' ')"
RUNA_OUT="$(_audit_read_run run-A)"
assert_eq "run-A matches two records across both months" "2" "$(printf '%s' "$RUNA_OUT" | jq -s 'length')"
# Slurp the whole multi-record stream and quantify: a foreign run_id leaking
# through as a non-final element must fail. (`jq -e` per-document only reflects
# the LAST record, so it would miss a leak in any earlier element.)
assert_eq "run-A results are all run-A (no foreign run_id leaks through)" "0" \
  "$(printf '%s' "$RUNA_OUT" | jq -s 'map(select(.run_id != "run-A")) | length')"
assert_jq "run_id read also divides milliunits (allocate)" "$(printf '%s' "$RUNA_OUT" | jq -s '.[] | select(.operation_id=="op-alloc-1")')" '.after.budgeted == 300'
RUNB_COUNT="$(_audit_read_run run-B | jq -s 'length')"
assert_eq "run-B matches exactly one record" "1" "$RUNB_COUNT"
# AC #7 across EVERY field fixmu touches, not just `budgeted`: read the reconcile
# record back through the run helper and confirm cleared_balance/reconciled_balance
# are divided by 1000 on display (stored verbatim in raw milliunits on disk). A
# regression that broke only the cleared/reconciled branch of fixmu must now fail.
RUNB_OUT="$(_audit_read_run run-B)"
assert_jq "reconcile before.cleared_balance shown as 100 (÷1000)"    "$RUNB_OUT" '.before.cleared_balance == 100'
assert_jq "reconcile before.reconciled_balance shown as 90 (÷1000)"  "$RUNB_OUT" '.before.reconciled_balance == 90'
assert_jq "reconcile after.reconciled_balance shown as 100 (÷1000)"  "$RUNB_OUT" '.after.reconciled_balance == 100'

# ---------------------------------------------------------------------------
# `amount` is the FOURTH milliunit field fixmu divides (bin/audit-log.sh:114) and
# the one no other fixture carried — budgeted, cleared_balance and reconciled_balance
# are all read-asserted above. It is a REQUIRED before-field of delete_duplicate
# (assets/changeset-schema.json:255), so every such record carries before.amount;
# without this a regression that broke only the `amount` branch of fixmu would ship
# raw milliunits in the human display while every other test stayed green. Read a
# delete_duplicate record back through BOTH helpers and confirm the ÷1000 transform.
echo "AC #7: the amount field is divided ÷1000 on read (delete_duplicate op):"
export YNAB_AUDIT_DIR="$SANDBOX/p_del"
export YNAB_AUDIT_MONTH="2026-06"
export YNAB_AUDIT_TIMESTAMP="2026-06-15T16:30:00Z"
_audit_append "$DELETE_OP" "$DELETE_RES" false
DEL_LAST="$(_audit_read_last 1)"
assert_jq "delete read via last: target_entity_ids = [transaction_id]" "$DEL_LAST" '.target_entity_ids == ["txn-dup-1"]'
assert_jq "delete before.amount -54990 shown as -54.99 (÷1000)"        "$DEL_LAST" '.before.amount == -54.99'
assert_jq "delete after.amount 12340 shown as 12.34 (÷1000)"           "$DEL_LAST" '.after.amount == 12.34'
DEL_RUN="$(_audit_read_run run-C)"
assert_jq "delete read via run-C: before.amount shown as -54.99 (÷1000)" "$DEL_RUN" '.before.amount == -54.99'
assert_jq "delete read via run-C: after.amount shown as 12.34 (÷1000)"   "$DEL_RUN" '.after.amount == 12.34'

# ---------------------------------------------------------------------------
# #164 / #50: the delete path writes a pre-delete INTENT record carrying the
# fifth on-trail result_status value, pending_delete (assets/delete-duplicate.js
# makeAuditingDeleteApplyOp), before the irreversible delete runs. The trusted
# pass-through must store it verbatim — proving the trail's documented
# five-value vocabulary end to end, not just the executor's four.
echo "pending_delete: the delete path's intent record passes through verbatim:"
export YNAB_AUDIT_DIR="$SANDBOX/pending-delete"
export YNAB_AUDIT_MONTH="2026-06"
export YNAB_AUDIT_TIMESTAMP="2026-06-15T16:35:00Z"
PENDING_DELETE_RES='{"tool":"mcp__ynab__ynab_delete_transaction","status":"pending_delete","schema_version":"1.0.0","run_id":"run-C"}'
_audit_append "$DELETE_OP" "$PENDING_DELETE_RES" false; rc=$?
assert_eq "pending_delete append exit code is 0" "0" "$rc"
PD_REC="$(head -1 "$SANDBOX/pending-delete/audit-2026-06.jsonl")"
assert_eq "result_status is pending_delete (stored verbatim)" "pending_delete" "$(printf '%s' "$PD_REC" | jq -r '.result_status')"
assert_jq "error_class is null on an intent record"   "$PD_REC" '.error_class == null'
assert_jq "applied_state is null on an intent record" "$PD_REC" '.applied_state == null'
assert_jq "intent record is a real-run record (dry_run:false)" "$PD_REC" '.dry_run == false'

# ---------------------------------------------------------------------------
# Crash recovery (reader leniency, defense-in-depth): the writer now appends each
# record as a single atomic, newline-terminated write, so a crash no longer leaves a
# torn line — but an out-of-band truncation still could, and that can only ever be
# one partial, UNTERMINATED trailing line. The read helpers must SKIP that fragment
# and still emit every complete record before it. A malformed line in the BODY, by
# contrast, is corruption an audit trail must surface, so it still fails the read.
echo "crash recovery: readers skip a partial TRAILING line, keep the good records:"
export YNAB_AUDIT_DIR="$SANDBOX/partial"
export YNAB_AUDIT_MONTH="2026-06"
export YNAB_AUDIT_TIMESTAMP="2026-06-15T17:00:00Z"
_audit_append "$CATEGORIZE_OP" "$CATEGORIZE_RES" false   # one good record (run-A)
PFILE="$YNAB_AUDIT_DIR/audit-2026-06.jsonl"
# Simulate a crash mid-append: a partial, unterminated line (no newline).
printf '%s' '{"operation_id":"op-truncat' >> "$PFILE"

PL_OUT="$(_audit_read_last 10 2>/dev/null)"; rc=$?
assert_eq "read_last exits 0 despite a partial trailing line"        "0" "$rc"
assert_jq "read_last still emits the good record"                    "$PL_OUT" '.operation_id == "op-cat-1"'
assert_eq "read_last emits exactly the one good record"              "1" "$(printf '%s' "$PL_OUT" | jq -s 'length')"
assert_eq "read_last drops the partial line (no op-truncat record)"  "0" \
  "$(printf '%s' "$PL_OUT" | jq -s 'map(select(.operation_id == "op-truncat")) | length')"

PR_OUT="$(_audit_read_run run-A 2>/dev/null)"; rc=$?
assert_eq "read_run exits 0 despite a partial trailing line"         "0" "$rc"
assert_jq "read_run still emits the good record"                     "$PR_OUT" '.operation_id == "op-cat-1"'

# A torn PAST-month file must not corrupt reads of OTHER months. parse_jsonl's
# trailing-partial-line tolerance is per-FILE, so _audit_read_run parses each
# monthly file independently: an earlier month's unterminated fragment can never
# fuse onto the next month's first record. A single `jq -R -s` over every file at
# once would concatenate them — the May fragment would swallow June's first record
# and fail the whole read (exit 1), losing a valid record permanently. This block
# is the regression guard for that exact crash scenario (a non-final torn file).
echo "crash recovery: a torn PAST-month file doesn't break read_run of other months:"
export YNAB_AUDIT_DIR="$SANDBOX/partial-multi"
# May: one good run-A record, then a partial, unterminated trailing line (crash).
export YNAB_AUDIT_MONTH="2026-05"; export YNAB_AUDIT_TIMESTAMP="2026-05-20T10:00:00Z"
_audit_append "$CATEGORIZE_OP" "$CATEGORIZE_RES" false   # good run-A record in May
MMFILE="$YNAB_AUDIT_DIR/audit-2026-05.jsonl"
printf '%s' '{"operation_id":"op-may-truncat' >> "$MMFILE"   # crash: partial, unterminated
# June: a clean good run-A record in the current month (a LATER file lexically).
export YNAB_AUDIT_MONTH="2026-06"; export YNAB_AUDIT_TIMESTAMP="2026-06-20T10:00:00Z"
_audit_append "$ALLOCATE_OP" "$ALLOCATE_RES" false       # good run-A record in June
PM_OUT="$(_audit_read_run run-A 2>/dev/null)"; rc=$?
assert_eq "read_run exits 0 despite a torn PAST-month file"          "0" "$rc"
assert_eq "read_run returns BOTH good records (May + June), partial dropped" "2" \
  "$(printf '%s' "$PM_OUT" | jq -s 'length')"
assert_eq "read_run keeps the clean June record (not fused with May's fragment)" "1" \
  "$(printf '%s' "$PM_OUT" | jq -s 'map(select(.operation_id == "op-alloc-1")) | length')"
assert_eq "read_run drops the May partial line (no op-may-truncat record)" "0" \
  "$(printf '%s' "$PM_OUT" | jq -s 'map(select(.operation_id == "op-may-truncat")) | length')"

# A malformed line in the BODY (terminated → not the trailing fragment) is
# corruption: the read must FAIL loudly with the audit-log: prefix, not skip it.
echo "crash recovery: a malformed BODY line fails the read (corruption surfaced):"
export YNAB_AUDIT_DIR="$SANDBOX/corrupt-body"
export YNAB_AUDIT_MONTH="2026-06"
export YNAB_AUDIT_TIMESTAMP="2026-06-15T17:05:00Z"
_audit_append "$CATEGORIZE_OP" "$CATEGORIZE_RES" false   # good record (becomes a BODY line)
CFILE="$YNAB_AUDIT_DIR/audit-2026-06.jsonl"
printf '%s\n' 'not-json-corruption-in-the-body' >> "$CFILE"   # terminated → a BODY line
_audit_append "$ALLOCATE_OP" "$ALLOCATE_RES" false       # another good record after it
_audit_read_last 10 >/dev/null 2>&1; rc=$?
assert_eq "read_last FAILS on a malformed body line (exit 1)"        "1" "$rc"
cb_err="$(_audit_read_last 10 2>&1 1>/dev/null)"
assert_contains "body-corruption diagnostic names audit-log on STDERR" "$cb_err" "audit-log:"
# Both readers share parse_jsonl, so read_run must fail just as loudly — an
# asymmetric test (read_last only) is exactly what would miss a divergence between
# the two. run-A brackets the corrupt body line (both good records carry run-A).
_audit_read_run run-A >/dev/null 2>&1; rc=$?
assert_eq "read_run FAILS on a malformed body line (exit 1)"         "1" "$rc"
cb_run_err="$(_audit_read_run run-A 2>&1 1>/dev/null)"
assert_contains "read_run body-corruption diagnostic names audit-log on STDERR" "$cb_run_err" "audit-log:"

# A body line equal to the JSON literal `null` is VALID JSON yet NOT a record:
# `fromjson` accepts it without error, so without the object type-guard read_last
# would fabricate a phantom {"before":null,"after":null} (exit 0) and read_run
# would silently drop it (exit 0) — an audit log inventing or losing a change is
# the exact trust failure this feature exists to prevent. With the guard BOTH
# readers must fail loudly (exit 1, audit-log: on STDERR).
# Backticks are literal formatting around `null` — no expansion intended.
# shellcheck disable=SC2016
echo 'crash recovery: a `null` body line fails the read for BOTH helpers:'
export YNAB_AUDIT_DIR="$SANDBOX/corrupt-null"
export YNAB_AUDIT_MONTH="2026-06"
export YNAB_AUDIT_TIMESTAMP="2026-06-15T17:10:00Z"
_audit_append "$CATEGORIZE_OP" "$CATEGORIZE_RES" false   # good record (run-A), a BODY line
NFILE="$YNAB_AUDIT_DIR/audit-2026-06.jsonl"
printf '%s\n' 'null' >> "$NFILE"                          # the literal null, terminated → a BODY line
_audit_append "$ALLOCATE_OP" "$ALLOCATE_RES" false       # another good record after it (run-A)
_audit_read_last 10 >/dev/null 2>&1; rc=$?
assert_eq "read_last FAILS on a \`null\` body line (exit 1)"         "1" "$rc"
nl_err="$(_audit_read_last 10 2>&1 1>/dev/null)"
assert_contains "null-body read_last diagnostic names audit-log on STDERR" "$nl_err" "audit-log:"
_audit_read_run run-A >/dev/null 2>&1; rc=$?
assert_eq "read_run FAILS on a \`null\` body line (exit 1)"          "1" "$rc"
nlr_err="$(_audit_read_run run-A 2>&1 1>/dev/null)"
assert_contains "null-body read_run diagnostic names audit-log on STDERR" "$nlr_err" "audit-log:"

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
# A missing run id is a usage error too: it must exit 2 like the other usage
# errors, not 1 (the _audit_read_run empty-id guard's return code).
bash "$HELPER" run >/dev/null 2>&1; rc=$?
assert_eq "CLI 'run' with no id is a usage error (exit 2)" "2" "$rc"

# ---------------------------------------------------------------------------
echo "the audit trail is owner-only — dir 0700, record files 0600:"
export YNAB_AUDIT_DIR="$SANDBOX/perms/nested"
export YNAB_AUDIT_MONTH="2026-06"
export YNAB_AUDIT_TIMESTAMP="2026-06-15T16:00:00Z"
_audit_append "$CATEGORIZE_OP" "$CATEGORIZE_RES" false
# Portable octal-perms read: GNU/Linux `stat -c '%a'`, BSD/macOS `stat -f '%Lp'`.
# GNU must be probed FIRST. On GNU, `stat -f '%Lp' "$1"` treats `%Lp` as a bad
# file operand: it exits non-zero (so a BSD-first `||` *does* fall through) but
# first prints $1's filesystem-status block to stdout — polluting the capture
# with "<fs block>\n<mode>". Probing GNU `stat -c '%a'` first avoids that; BSD
# `stat -c` is a genuine error, so this order fails over cleanly on macOS.
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
assert_eq "audit dir is created mode 700"  "700" "$(mode_of "$YNAB_AUDIT_DIR")"
assert_eq "record file is created mode 600" "600" "$(mode_of "$YNAB_AUDIT_DIR/audit-2026-06.jsonl")"

# Perms must be ENFORCED, not merely set at creation: `mkdir -m`/`umask` only bite
# when the dir/file is first made, so a PRE-EXISTING loose dir (0755) or file (0644)
# — from an older run or tampering — must be tightened on the next append, else the
# financial trail stays world-readable. Seed a loose dir+file, then append.
echo "owner-only perms are enforced on a PRE-EXISTING loose dir/file:"
export YNAB_AUDIT_DIR="$SANDBOX/perms-pre/nested"
export YNAB_AUDIT_MONTH="2026-06"
export YNAB_AUDIT_TIMESTAMP="2026-06-15T16:05:00Z"
mkdir -p "$YNAB_AUDIT_DIR"; chmod 755 "$YNAB_AUDIT_DIR"
PRE_FILE="$YNAB_AUDIT_DIR/audit-2026-06.jsonl"
: > "$PRE_FILE"; chmod 644 "$PRE_FILE"
assert_eq "pre-existing dir starts at 755"  "755" "$(mode_of "$YNAB_AUDIT_DIR")"
assert_eq "pre-existing file starts at 644" "644" "$(mode_of "$PRE_FILE")"
_audit_append "$CATEGORIZE_OP" "$CATEGORIZE_RES" false; rc=$?
assert_eq "append into a pre-existing loose dir succeeds"   "0"   "$rc"
assert_eq "append tightens the pre-existing dir to 700"     "700" "$(mode_of "$YNAB_AUDIT_DIR")"
assert_eq "append tightens the pre-existing file to 600"    "600" "$(mode_of "$PRE_FILE")"

# ---------------------------------------------------------------------------
echo "read helpers: diagnostics go to STDERR, STDOUT stays clean (AC #9):"
export YNAB_AUDIT_DIR="$SANDBOX/read-empty"
export YNAB_AUDIT_MONTH="2026-06"
# _audit_read_last against a missing month file: nothing on STDOUT, note on STDERR.
RL_OUT="$(_audit_read_last 1 2>/dev/null)"
assert_empty   "read_last on a missing file prints nothing to STDOUT" "$RL_OUT"
RL_ERR="$(_audit_read_last 1 2>&1 1>/dev/null)"
assert_contains "read_last diagnostic names audit-log on STDERR" "$RL_ERR" "audit-log:"
# _audit_read_run against a missing audit dir: nothing on STDOUT, note on STDERR.
RR_OUT="$(_audit_read_run run-A 2>/dev/null)"
assert_empty   "read_run on a missing dir prints nothing to STDOUT" "$RR_OUT"
RR_ERR="$(_audit_read_run run-A 2>&1 1>/dev/null)"
assert_contains "read_run diagnostic names audit-log on STDERR" "$RR_ERR" "audit-log:"

# ---------------------------------------------------------------------------
echo "AC #6: with no override, _audit_dir resolves the canonical plugin-data path:"
# Unset the test seam inside a command-substitution subshell so the parent's
# YNAB_AUDIT_DIR (and the running PASS/FAIL counters) are untouched.
DEFAULT_DIR="$(unset YNAB_AUDIT_DIR; _audit_dir)"
assert_eq "default _audit_dir is the canonical plugin-data audit path" \
  "$HOME/.claude/plugins/data/workbench-ynab-claude-workbench/audit" \
  "$DEFAULT_DIR"

echo ""
echo "audit log: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
