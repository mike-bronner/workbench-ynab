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

# doc_section <step-label> [doc] — emit the BODY of a "### <step-label> — …"
# section, up to (not including) its terminator. Reads $REPO_ROOT/$DOC unless a
# doc path is given; the boundary regression at the foot of this file points it
# at scratch copies. Empty when the step is absent, so every section-scoped
# assertion below goes red the moment its step is deleted or renamed — the
# discrimination a whole-file grep can't give, since these needles recur across
# steps. Mirrors docs-set.test.sh's scoped extraction.
#
# A section closes at a "---" rule, or at the next heading whose level is AT OR
# ABOVE the wanted heading's own. That depth is read off the wanted heading
# pattern itself, so the two can never drift apart. Closing only at the next
# "### " let a shallower "## " heading pass straight through (issue #301) — the
# same defect fixed for write-safety-guardrail-doc.test.sh's doc_section_verbs in
# 18ce327. It is live here: the doc's last "### " subsection ("Human-run only —
# deferred to the release gate") runs straight into "## Gaps found" with no rule
# between, so that whole section read as part of its body. Deeper headings are
# real sub-sections and stay inside.
#
# Fenced code blocks are held out of that decision, and this is load-bearing, not
# defensive: Step 6's bash fence opens "# a) config.json carries no token-shaped
# …" and Step 7's carries "# Expect ≥ 1, …", both a depth-1 heading to a
# fence-naive regex. Without the fence guard Step 6's body truncates at that
# comment — 39 lines to 6 — dropping the three needles pinned below it (the
# cannot-verify branch, the `security find-generic-password` command, and
# "Keychain-only"); Step 7's truncates 14 lines to 8 the same way.
doc_section() {
  awk -v h="^### $1 " '
    BEGIN   { match(h, /#+/); depth = RLENGTH }
    /^```/  { fence = !fence; if (f) print; next }
    fence   { if (f) print; next }
    $0 ~ h  { f = 1; next }
    !f      { next }
    /^---$/ { exit }
    /^#+ /  { match($0, /^#+/); if (RLENGTH <= depth) exit }
            { print }
  ' "${2:-$REPO_ROOT/$DOC}"
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
# workbench-core is the prereq setup itself originally omitted (issue #230, since
# fixed) — pin its concrete detection so it can't be quietly weakened back to a
# three-tool check.
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
# Section-scoped to Step 2. Neither needle recurs elsewhere in the doc today, so a
# whole-file grep would also go red on deletion — but the Gaps entry now discusses
# both install commands in prose (the #269 verification record), which is exactly
# the drift that turns an unscoped pin vacuous. Scoping matches this file's
# convention for step-specific pins and holds if that prose grows a code sample.
assert_in_section "Step 2" "documents the marketplace install path" "claude plugin install workbench-ynab@claude-workbench"
# Needle omits the leading `~` deliberately: shellcheck SC2088 flags a quoted tilde,
# and it buys no discrimination here — `.claude/skills/workbench-ynab` already pins
# the skills-dir mechanism, and stays correct if the doc switches to `$HOME/`.
assert_in_section "Step 2" "documents the local-checkout install path" ".claude/skills/workbench-ynab"
# The local-checkout path used to read `claude plugin install <path>`, which is not
# a valid form of the command (issue #269 — `install` resolves a plugin NAME against
# registered marketplaces and has no bare-path branch). Pin the refuted form out of
# Step 2. Scoped, NOT whole-file: the Gaps entry quotes the old instruction verbatim
# as the historical record of what was wrong, so a whole-file grep fails on the
# correct doc. Step 2 is where a revert would land, which is what this must catch.
if doc_section "Step 2" | grep -qF -- "claude plugin install /absolute/path"; then
  no "local-checkout path avoids the refuted bare-path install form"
else
  ok "local-checkout path avoids the refuted bare-path install form"
fi
# `marketplace add <path>` is the OTHER refuted form (#269): it takes a marketplace
# manifest, and this repo ships a plugin manifest. Pin it out of Step 2 specifically
# — the Gaps entry legitimately names it while explaining why it fails.
if doc_section "Step 2" | grep -qF -- "claude plugin marketplace add /"; then
  no "local-checkout path avoids the refuted marketplace-add-a-path form"
else
  ok "local-checkout path avoids the refuted marketplace-add-a-path form"
fi

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

# --- the section terminator respects heading level (issue #301) -----------------
# doc_section used to close a "### " section only at the next "### " or "---", so
# a shallower "## " heading did not end it. The boundary under test is the doc's
# real, unmodified dormant risk: "### Human-run only — deferred to the release
# gate" (nested under "## Results") runs straight into "## Gaps found" with no
# "---" and no intervening "### ". Running both rules over all 13 of the doc's
# "### " headings, it is the only one whose body differs (58 lines under the old
# rule, 17 under the new); the other 12 come out byte-identical, because every
# pinned "### Step N" is followed by another "### " before any "## ". So a case
# built on a Step label could never redden under the pre-fix rule.
#
# Both directions are proved on scratch copies; docs/fresh-install-test.md itself
# is never written to.
#   (a) false positive — content planted past the section's real end must not be
#       attributed to it.
#   (b) false negative — a needle DELETED from the section's own body must read as
#       absent even when the same string occurs further down, inside the range the
#       old terminator swept. That is the drift masking these section-scoped pins
#       exist to prevent: the doc stops saying something and the pin stays green.
#
# Each direction runs the literal pre-fix rule over the SAME mutated copy and
# asserts it gets the answer wrong, immediately before asserting the fixed rule
# gets it right — so "reddens under the old rule" is mechanical here, not a claim
# in a commit message.
BOUNDARY_LABEL="Human-run only"
BOUNDARY_NEEDLE="Full-tree token-leak sweep"
BOUNDARY_DECOY="- boundary-regression decoy planted outside the section under test"
BOUNDARY_DIR="$(mktemp -d)"
trap 'rm -rf "$BOUNDARY_DIR"' EXIT

# The original terminator, verbatim — the control each case is measured against.
doc_section_prefix_rule() {
  awk -v h="^### $1 " '
    $0 ~ h { f = 1; next }
    f && (/^### / || /^---$/) { exit }
    f
  ' "${2:-$REPO_ROOT/$DOC}"
}

# plant_after_boundary <doc> <line> — <doc> with <line> inserted just below the
# first heading FOLLOWING the boundary section, i.e. into "## Gaps found"'s body.
# That lands outside the section by heading level but inside the range the old
# terminator swept, which is precisely the gap under test.
plant_after_boundary() {
  awk -v h="^### $BOUNDARY_LABEL " -v line="$2" '
    { print }
    $0 ~ h                  { seen = 1; next }
    seen && /^#+ / && !done { print ""; print line; done = 1 }
  ' "$1"
}

# Positive control: the unmutated doc reports the needle inside the section, so a
# failure below is the mutation and not a broken extraction.
if doc_section "$BOUNDARY_LABEL" | grep -qF -- "$BOUNDARY_NEEDLE"; then
  ok "boundary control: the unmutated '$BOUNDARY_LABEL' section reports its own needle"
else
  no "boundary control: the unmutated '$BOUNDARY_LABEL' section reports its own needle"
fi

# (a) false positive -----------------------------------------------------------
plant_after_boundary "$REPO_ROOT/$DOC" "$BOUNDARY_DECOY" > "$BOUNDARY_DIR/decoy.md"
# The plant must actually have landed. If the doc ever restructures so no heading
# follows the boundary section, plant_after_boundary is a no-op and this case
# would pass by comparing the doc against itself — a green that checked nothing.
if cmp -s "$REPO_ROOT/$DOC" "$BOUNDARY_DIR/decoy.md"; then
  no "boundary (a): the decoy plant landed in the scratch copy"
else
  ok "boundary (a): the decoy plant landed in the scratch copy"
fi
if doc_section_prefix_rule "$BOUNDARY_LABEL" "$BOUNDARY_DIR/decoy.md" | grep -qF -- "$BOUNDARY_DECOY"; then
  ok "boundary (a): the pre-fix '### '-only rule sweeps the decoy in — this case reddens without the fix"
else
  no "boundary (a): the pre-fix '### '-only rule sweeps the decoy in — this case reddens without the fix"
fi
if doc_section "$BOUNDARY_LABEL" "$BOUNDARY_DIR/decoy.md" | grep -qF -- "$BOUNDARY_DECOY"; then
  no "boundary (a): a decoy planted in the next '## ' section stays out of the pinned body"
else
  ok "boundary (a): a decoy planted in the next '## ' section stays out of the pinned body"
fi

# (b) false negative / masking --------------------------------------------------
grep -vF -- "$BOUNDARY_NEEDLE" "$REPO_ROOT/$DOC" > "$BOUNDARY_DIR/base.md"
if cmp -s "$REPO_ROOT/$DOC" "$BOUNDARY_DIR/base.md"; then
  no "boundary (b): the needle deletion landed in the scratch copy"
else
  ok "boundary (b): the needle deletion landed in the scratch copy"
fi
plant_after_boundary "$BOUNDARY_DIR/base.md" "- $BOUNDARY_NEEDLE — relocated by the boundary regression" \
  > "$BOUNDARY_DIR/masked.md"
if cmp -s "$BOUNDARY_DIR/base.md" "$BOUNDARY_DIR/masked.md"; then
  no "boundary (b): the masking plant landed in the scratch copy"
else
  ok "boundary (b): the masking plant landed in the scratch copy"
fi
if doc_section_prefix_rule "$BOUNDARY_LABEL" "$BOUNDARY_DIR/masked.md" | grep -qF -- "$BOUNDARY_NEEDLE"; then
  ok "boundary (b): the pre-fix rule still reports the deleted needle — this case reddens without the fix"
else
  no "boundary (b): the pre-fix rule still reports the deleted needle — this case reddens without the fix"
fi
if doc_section "$BOUNDARY_LABEL" "$BOUNDARY_DIR/masked.md" | grep -qF -- "$BOUNDARY_NEEDLE"; then
  no "boundary (b): a needle deleted from the section reads as absent despite a copy further down"
else
  ok "boundary (b): a needle deleted from the section reads as absent despite a copy further down"
fi

# (c) same-level headings still close a section ---------------------------------
# A no-regression pin, not a fix proof: the old rule already closed at a sibling
# "### ", and widening the comparison to "shallower only" (RLENGTH < depth rather
# than <=) would silently drop that. Every assertion above is a presence check, so
# an over-wide section only ever gains content and all of them stay green — this
# is the one case that reads the loss. Step 5 must not see Step 6's needle; under
# a shallower-only rule Step 5 runs through Steps 6–10 to the "---" rule and does.
if doc_section "Step 5" | grep -qF -- "could not verify config.json is token-free"; then
  no "boundary (c): a section still closes at the next same-level '### ' heading"
else
  ok "boundary (c): a section still closes at the next same-level '### ' heading"
fi

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
