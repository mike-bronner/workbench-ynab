#!/usr/bin/env bash
# Unit tests for the fresh-machine (clean-room) install-test doc (issue #69,
# M5-10): docs/fresh-install-test.md. Run directly:
#   tests/unit/fresh-install-test-doc.test.sh
#
# Pins the doc's AC-mandated invariants so a future edit can't silently drop
# them: the canonical not-tax-advice tag (prominent, byte-for-byte, per #18); a
# prerequisite step that asserts ALL FOUR prereqs (node, jq, security,
# workbench-core) AND fails fast with a non-zero exit; BOTH install paths
# (marketplace AND local-checkout); the out-of-repo config path; the
# token-is-Keychain-only verification; the namespaced pre-approval prefix (Step 7);
# the ynab_list_budgets MCP check routed THROUGH that glob (Step 8); the read-only
# review's print-CSS invariant (Step 9); the first-connection latency measurement
# against the real 20 s cold-start boot budget (bin/launcher.sh documents no
# timeout); a Results section; and a Gaps section that links its follow-up.
#
# Several needles (the namespaced prefix, "20 s", @media print, the out-of-repo
# config path, the Keychain-only token check) recur across steps, so the checks
# that pin a SPECIFIC step are section-scoped via doc_section() — a whole-file
# grep stayed green with the whole step deleted.
# Style mirrors tests/unit/docs-set.test.sh: raw bash, `set -u`, PASS/FAIL
# counters, non-zero exit on any failure.
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

# doc_section <step-label> — emit the BODY of a "### <step-label> — …" section, up
# to (not including) the next "### " heading or a "---" rule. Empty when the step
# is absent, so every section-scoped assertion below goes red the moment its step
# is deleted or renamed — the discrimination a whole-file grep can't give, since
# these needles recur across steps. Mirrors docs-set.test.sh's scoped extraction.
doc_section() {
  awk -v h="^### $1 " '
    $0 ~ h { f = 1; next }
    f && (/^### / || /^---$/) { exit }
    f
  ' "$REPO_ROOT/$DOC"
}

# assert_in_section <step-label> <desc> <literal> — the named step's body must
# contain <literal>.
assert_in_section() {
  local label="$1" desc="$2" needle="$3"
  if doc_section "$label" | grep -qF -- "$needle"; then
    ok "$desc"
  else
    no "$desc"
  fi
}

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
# Fail-fast on a miss — mirrors the dev-team setup Step 2 pattern. Pin BOTH the
# message AND the non-zero exit: the message alone stayed green when `exit 1` was
# removed (the block would print and fall through). Extract the miss block
# (Missing prerequisites: → the ✅ all-present confirm) and assert it exits 1.
assert_contains "prereq step announces the miss" "Missing prerequisites:"
MISS_BLOCK="$(awk '/Missing prerequisites:/{f=1} f{print} /all present/{exit}' "$REPO_ROOT/$DOC")"
if printf '%s\n' "$MISS_BLOCK" | grep -qF -- "exit 1"; then
  ok "prereq miss block fails fast with a non-zero exit"
else
  no "prereq miss block fails fast with a non-zero exit"
fi
assert_contains "prereq step enforces the pinned Node floor" "meets the Node >= "

# --- both install paths covered (AC #1) ----------------------------------------
assert_contains "documents the marketplace install path" "workbench-ynab@claude-workbench"
assert_contains "documents the local-checkout install path" "claude plugin install /absolute/path/to/workbench-ynab"

# --- config lands out of repo (AC #6) ------------------------------------------
# Section-scoped to Step 5: the config path recurs 3× (Step 0 precondition, Step 5
# assertion, Results table), so a whole-file grep stayed green with all of Step 5
# deleted. Pin it to Step 5's body so dropping the out-of-repo assertion fails.
assert_in_section "Step 5" "documents the out-of-repo config path" "plugins/data/workbench-ynab-claude-workbench/config.json"

# --- token is Keychain-only (AC #7) --------------------------------------------
# Section-scoped to Step 6: the `security find-generic-password` needle recurs in
# Step 0's blockquote and "Keychain-only" recurs in the Gaps prose, so a whole-file
# grep stayed green with all of Step 6 (the token-leak-sweep procedure) deleted.
# Pin both to Step 6's body so dropping the heart of AC #7 fails.
assert_in_section "Step 6" "documents the Keychain-only token verification" "security find-generic-password -s ynab-mcp -a access-token"
assert_in_section "Step 6" "states the token is Keychain-only" "Keychain-only"
# The Step 6a config-scan guard must fail CLOSED like setup's own (commands/setup.md
# Step 4): a jq scan failure must report "cannot verify", never a silent ✅. Pin the
# cannot-verify branch so the `&& … || …` collapse — which turns a scan failure
# (missing/corrupt file → exit 2/5) into a false "token-free" pass — can't return.
assert_in_section "Step 6" "Step 6a config-scan guard fails closed on a jq scan failure" "could not verify config.json is token-free"

# --- namespaced pre-approval glob (AC #8) --------------------------------------
# Section-scoped to Step 7: the bare $PREFIX recurs 6× across the doc (Steps 3, 7,
# 8, and the Results table), so a whole-file grep stayed green with all of Step 7
# deleted. Pin it to Step 7's body so dropping the pre-approval step fails.
assert_in_section "Step 7" "Step 7 documents the namespaced pre-approval prefix" "$PREFIX"

# --- MCP connection verified via ynab_list_budgets, THROUGH the glob (AC #4) ----
# One linked invariant, not two independent greps: Step 8 must name
# ynab_list_budgets AND route it through the namespaced glob. Checked separately, a
# Step 8 that called the op "directly" (severing the glob) still passed. Bare op
# name + bare prefix, never the concrete prefix+op concatenation (guard-forbidden).
if doc_section "Step 8" | grep -qF -- "ynab_list_budgets" \
   && doc_section "Step 8" | grep -qF -- "$PREFIX"; then
  ok "Step 8 calls ynab_list_budgets through the namespaced glob (AC #4, linked)"
else
  no "Step 8 calls ynab_list_budgets through the namespaced glob (AC #4, linked)"
fi

# --- AC #5: Step 9 pins the read-only-review / print-CSS invariant --------------
# Nothing pinned Step 9 before — deleting the whole step left the suite at 21/21.
# Section-scoped so a dropped Step 9 fails, and it pins the print-CSS half that IS
# sandbox-provable: the frozen template's @media print + the offline report-template
# proof (tests/report-template.test.sh). The live-review half stays human-run.
if doc_section "Step 9" | grep -qF -- "@media print" \
   && doc_section "Step 9" | grep -qF -- "tests/report-template.test.sh"; then
  ok "Step 9 pins the print-CSS invariant + offline report-template proof (AC #5)"
else
  no "Step 9 pins the print-CSS invariant + offline report-template proof (AC #5)"
fi

# --- Results section present (AC #3) -------------------------------------------
assert_contains "has a Results section" "## Results"

# --- first-connection latency vs the real 20 s boot budget (AC #9) -------------
# The doc previously mis-attributed a "30 s timeout class" to bin/launcher.sh,
# which documents no timeout at all; the real cold-start budget is 20 s
# (agents/ynab-orchestrator.md, docs/ynab-read-path.md). Pin the corrected figure
# section-scoped to Step 8, AND guard that the false claim never returns.
assert_in_section "Step 8" "measures first-connection latency" "spawn→first response"
assert_in_section "Step 8" "cites the real 20 s boot-patience budget" "20 s boot-patience budget"
if grep -qF -- "30 s timeout class" "$REPO_ROOT/$DOC"; then
  no "doc no longer ships the false 30 s launcher-timeout claim"
else
  ok "doc no longer ships the false 30 s launcher-timeout claim"
fi

# --- gaps section links the follow-up (AC #10) --------------------------------
assert_contains "has a Gaps found section" "## Gaps found"
assert_contains "links the workbench-core follow-up issue" "issues/230"

# --- cross-references the companion release proofs -----------------------------
assert_contains "references the human release-gate checklist" "verification-checklist.md"
assert_contains "references the automated offline-boot proof" "tests/offline-boot.sh"

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
