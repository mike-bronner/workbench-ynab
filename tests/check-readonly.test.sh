#!/usr/bin/env bash
#
# check-readonly.test.sh — self-test for the M2 read-only guardrail (issue #39).
#
# Self-contained: no test framework required. Run directly:
#   bash tests/check-readonly.test.sh
# Exits 0 if all assertions pass, 1 otherwise. Auto-discovered by scripts/test.sh.
#
# The guard (scripts/check-readonly.sh) enforces two M2 invariants: no CALLABLE
# (namespaced) YNAB write tool on a read-only surface, and no bare `mcp__ynab__`
# reference. This file is the test for the test — it proves the guard:
#   * catches a namespaced write verb planted in a review skill, the orchestrator,
#     and a review command;
#   * catches a bare `mcp__ynab__` reference;
#   * does NOT flag the orchestrator's own read-only DENY-LIST prose (a bare
#     `ynab_reconcile_account` / a `ynab_update_*` family glob) — the exact
#     false-positive this design avoids;
#   * does NOT flag a namespaced READ tool (read tools are allowed);
#   * fails closed when a scanned surface is missing;
#   * and passes on the REAL repository tree (so a real regression fails CI here).
#
# The concrete namespaced write token is assembled at runtime from two harmless
# fragments — the bare prefix and a verb suffix — so THIS file contains no literal
# concrete tool name and stays clean when bin/check-tool-name-sources.sh scans
# tests/.

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/../scripts/check-readonly.sh"

PREFIX='mcp__plugin_workbench-ynab_ynab__'            # the callable namespace prefix
WRITE_CALL="${PREFIX}ynab_update_transaction"         # a callable write tool (assembled)
READ_CALL="${PREFIX}ynab_list_transactions"           # a callable READ tool (allowed)
GLOB="ynab_update_*"                                  # a deny-prose family glob (not callable)
BARE='mcp__ynab__'                                    # the non-resolving bare namespace

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0
fail=0

# Lay down a minimal but COMPLETE set of M2 read-only surfaces so the guard's
# fail-closed "surface missing" path is not tripped unless a case removes one.
reset_sandbox() {
  rm -rf "$SANDBOX"
  mkdir -p "$SANDBOX/scripts" "$SANDBOX/agents" "$SANDBOX/skills/protocol" \
           "$SANDBOX/skills/review" "$SANDBOX/commands"
  cp "$GUARD" "$SANDBOX/scripts/check-readonly.sh"
  chmod +x "$SANDBOX/scripts/check-readonly.sh"
  : > "$SANDBOX/agents/ynab-orchestrator.md"
  : > "$SANDBOX/skills/protocol/SKILL.md"
  : > "$SANDBOX/skills/review/ynab-review.md"
  : > "$SANDBOX/commands/ynab-review.md"
  : > "$SANDBOX/commands/ynab-weekly-review.md"
  : > "$SANDBOX/commands/ynab-monthly-review.md"
  : > "$SANDBOX/commands/ynab-quarterly-tax-review.md"
  : > "$SANDBOX/commands/ynab-annual-review.md"
}

# run_case "<desc>" <expected-exit> <file-relative-to-sandbox> "<content>"
# An empty <file> writes nothing (used for the clean-tree case).
run_case() {
  local desc="$1" expected="$2" file="$3" content="$4"
  reset_sandbox
  if [ -n "$file" ]; then
    mkdir -p "$SANDBOX/$(dirname "$file")"
    printf '%s\n' "$content" > "$SANDBOX/$file"
  fi
  local actual=0
  ( cd "$SANDBOX" && bash scripts/check-readonly.sh ) >/dev/null 2>&1 || actual=$?
  if [ "$actual" -eq "$expected" ]; then
    echo "  ✓ $desc (exit $actual)"
    pass=$((pass + 1))
  else
    echo "  ✖ $desc — expected exit $expected, got $actual"
    fail=$((fail + 1))
  fi
}

# run_case_rm "<desc>" <expected-exit> <file-to-delete>
# Proves the fail-closed path: a required surface is removed before the run.
run_case_rm() {
  local desc="$1" expected="$2" file="$3"
  reset_sandbox
  rm -f "$SANDBOX/$file"
  local actual=0
  ( cd "$SANDBOX" && bash scripts/check-readonly.sh ) >/dev/null 2>&1 || actual=$?
  if [ "$actual" -eq "$expected" ]; then
    echo "  ✓ $desc (exit $actual)"
    pass=$((pass + 1))
  else
    echo "  ✖ $desc — expected exit $expected, got $actual"
    fail=$((fail + 1))
  fi
}

echo "Self-test: a callable write verb on any read-only surface is caught"
run_case "callable write verb in a review skill is caught"  1 "skills/review/ynab-review.md"        "call $WRITE_CALL to fix it"
run_case "callable write verb in the orchestrator is caught" 1 "agents/ynab-orchestrator.md"        "tools: [$WRITE_CALL]"
run_case "callable write verb in a review command is caught" 1 "commands/ynab-weekly-review.md"     "runs $WRITE_CALL"
run_case "callable write verb in the protocol skill is caught" 1 "skills/protocol/SKILL.md"         "then $WRITE_CALL"

echo "Self-test: a bare (non-resolving) namespace is caught"
run_case "bare mcp__ynab__ in a review skill is caught"     1 "skills/review/ynab-review.md"        "fetch via ${BARE}ynab_list_transactions"

echo "Self-test: read-only deny prose and read tools are NOT flagged"
# The exact false-positive this design avoids: the orchestrator names write verbs
# in its OWN deny-list. A bare verb and a family glob are prohibitions, not calls.
run_case "deny-prose bare write verb is not flagged"        0 "agents/ynab-orchestrator.md"         "never call a write verb (\`ynab_reconcile_account\`)"
run_case "deny-prose family glob is not flagged"            0 "agents/ynab-orchestrator.md"         "never call \`$GLOB\` — read-only"
run_case "a namespaced READ tool is not flagged"            0 "agents/ynab-orchestrator.md"         "tools: [$READ_CALL]"
run_case "clean tree passes"                                0 ""                                    ""

echo "Self-test: fail closed when a required surface is missing"
run_case_rm "missing orchestrator fails closed"             1 "agents/ynab-orchestrator.md"
run_case_rm "missing protocol skill fails closed"           1 "skills/protocol/SKILL.md"
run_case_rm "missing a review command fails closed"         1 "commands/ynab-annual-review.md"
run_case_rm "no review skill at all fails closed"           1 "skills/review/ynab-review.md"

# Mechanics proven above against the sandbox; this case proves the INVARIANT on
# the real tree — the actual M2 surfaces carry no callable write verb and no bare
# namespace. Because this is a tests/**/*.test.sh, scripts/test.sh runs it in CI,
# so a real read-only regression fails the build here, not just in the sandbox.
echo "Self-test: the real repository tree is clean"
real_out=""
real_rc=0
real_out="$( (cd "$SELF_DIR/.." && bash scripts/check-readonly.sh) 2>&1 )" || real_rc=$?
if [ "$real_rc" -eq 0 ]; then
  echo "  ✓ real tree passes the guard (exit 0)"
  pass=$((pass + 1))
else
  echo "  ✖ real tree FAILS the guard (exit $real_rc):"
  printf '%s\n' "$real_out" | sed 's/^/    /'
  fail=$((fail + 1))
fi

echo
echo "Passed: $pass   Failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "✓ read-only guard self-test green."
