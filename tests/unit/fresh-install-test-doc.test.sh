#!/usr/bin/env bash
# Unit tests for the fresh-machine (clean-room) install-test doc (issue #69,
# M5-10): docs/fresh-install-test.md. Run directly:
#   tests/unit/fresh-install-test-doc.test.sh
#
# Pins the doc's AC-mandated invariants so a future edit can't silently drop
# them: the canonical not-tax-advice tag (prominent, byte-for-byte, per #18); a
# prerequisite step that asserts ALL FOUR prereqs (node, jq, security,
# workbench-core) and fails fast; BOTH install paths (marketplace AND
# local-checkout); the out-of-repo config path; the token-is-Keychain-only
# verification; the namespaced pre-approval prefix; the ynab_list_budgets MCP
# check; the first-connection latency measurement against the 30 s timeout
# class; a Results section; and a Gaps section that links its follow-up. Style
# mirrors tests/unit/docs-set.test.sh: raw bash, `set -u`, PASS/FAIL counters,
# non-zero exit on any failure.
#
# The bare prefix (mcp__plugin_workbench-ynab_ynab__) and bare op names are used
# here — never the concrete prefix+op concatenation — so this file stays clean
# under bin/check-tool-name-sources.sh.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOC="docs/fresh-install-test.md"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
no() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# assert_contains <desc> <literal>
assert_contains() {
  local desc="$1" needle="$2"
  if grep -qF -- "$needle" "$REPO_ROOT/$DOC" 2>/dev/null; then
    ok "$desc"
  else
    no "$desc"
  fi
}

TAG='⚠️ Estimates only — not tax advice. Consult a qualified professional before filing or paying.'
PREFIX='mcp__plugin_workbench-ynab_ynab__'   # bare prefix — guard-safe

echo "fresh-install-test-doc.test.sh — the issue #69 clean-room install-test doc invariants"

# --- the doc exists and carries the canonical disclaimer, prominently ----------
if [ -f "$REPO_ROOT/$DOC" ]; then
  ok "$DOC exists"
else
  no "$DOC exists"
  echo ""; echo "passed: $PASS  failed: $FAIL"; exit 1
fi
assert_contains "$DOC carries the canonical not-tax-advice tag" "$TAG"
if head -10 "$REPO_ROOT/$DOC" | grep -qF -- "> $TAG"; then
  ok "$DOC disclaimer is prominent (top-of-file blockquote)"
else
  no "$DOC disclaimer is prominent (top-of-file blockquote)"
fi

# --- prerequisite step: all four asserted, fails fast (AC #2) -------------------
# The confirmation line names all four together — a single discriminating needle
# that goes red if any prereq is dropped from the check.
assert_contains "prereq step confirms all four prereqs" "node, jq, security, workbench-core all present"
# workbench-core is the prereq setup itself omits — pin its concrete detection so
# it can't be quietly weakened to a three-tool check.
assert_contains "prereq step detects workbench-core via the plugins cache" "cache/*/workbench-core"
# Fail-fast on a miss — mirrors the dev-team setup Step 2 pattern.
assert_contains "prereq step fails fast on a miss" "Missing prerequisites:"
assert_contains "prereq step enforces the pinned Node floor" "meets the Node >= "

# --- both install paths covered (AC #1) ----------------------------------------
assert_contains "documents the marketplace install path" "workbench-ynab@claude-workbench"
assert_contains "documents the local-checkout install path" "claude plugin install /absolute/path/to/workbench-ynab"

# --- config lands out of repo (AC #6) ------------------------------------------
assert_contains "documents the out-of-repo config path" "plugins/data/workbench-ynab-claude-workbench/config.json"

# --- token is Keychain-only (AC #7) --------------------------------------------
assert_contains "documents the Keychain-only token verification" "security find-generic-password -s ynab-mcp -a access-token"
assert_contains "states the token is Keychain-only" "Keychain-only"

# --- namespaced pre-approval glob (AC #8) --------------------------------------
assert_contains "documents the namespaced pre-approval prefix" "$PREFIX"

# --- MCP connection verified via ynab_list_budgets (AC #4) ---------------------
# Bare op name — the concrete prefix+op concatenation is guard-forbidden here.
assert_contains "names ynab_list_budgets as the MCP connection check" "ynab_list_budgets"

# --- Results section present (AC #3) -------------------------------------------
assert_contains "has a Results section" "## Results"

# --- first-connection latency vs the 30 s timeout class (AC #9) ----------------
assert_contains "measures first-connection latency" "spawn→first response"
assert_contains "calls out the 30 s timeout class" "30 s timeout class"

# --- gaps section links the follow-up (AC #10) --------------------------------
assert_contains "has a Gaps found section" "## Gaps found"
assert_contains "links the workbench-core follow-up issue" "issues/230"

# --- cross-references the companion release proofs -----------------------------
assert_contains "references the human release-gate checklist" "verification-checklist.md"
assert_contains "references the automated offline-boot proof" "tests/offline-boot.sh"

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
