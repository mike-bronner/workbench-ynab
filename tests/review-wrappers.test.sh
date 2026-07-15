#!/usr/bin/env bash
#
# review-wrappers.test.sh — verifies the four thin tier-wrapper skills (issue #41).
#
# Self-contained: no test framework required. Run directly:
#   bash tests/review-wrappers.test.sh
# Exits 0 if all assertions pass, 1 otherwise. Style mirrors
# tests/review-skill.test.sh: raw bash, `set -u`, PASS/FAIL counters, a non-zero
# exit when anything fails. Auto-discovered by scripts/test.sh.
#
# The wrappers are static markdown assets, so the assertions are structural
# string checks — the regression guard for the contract in issue #41: each
# wrapper is THIN (defers to the universal protocol via ${CLAUDE_PLUGIN_ROOT},
# sets its tier, expects the router plan block or runs the orchestrator ad-hoc,
# reaffirms read-only + the namespaced tool prefix) and carries ZERO duplicated
# methodology.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REVIEW_DIR="${REPO_ROOT}/skills/review"

pass=0
fail=0
FILE=""  # the wrapper currently under test (set per-tier below)

# assert_present <desc> <needle> — the wrapper must contain <needle> (literal).
assert_present() {
  local desc="$1" needle="$2"
  if grep -qF -- "$needle" "$FILE"; then
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL — %s: %q not found in %s\n' "$desc" "$needle" "${FILE##*/}"; fail=$((fail + 1))
  fi
}

# assert_present_re <desc> <regex> — the wrapper must match <regex> (ERE).
assert_present_re() {
  local desc="$1" re="$2"
  if grep -qiE -- "$re" "$FILE"; then
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL — %s: /%s/ did not match in %s\n' "$desc" "$re" "${FILE##*/}"; fail=$((fail + 1))
  fi
}

# assert_absent_re <desc> <regex> — the wrapper must NOT match <regex> (ERE).
assert_absent_re() {
  local desc="$1" re="$2"
  if grep -qE -- "$re" "$FILE"; then
    printf 'FAIL — %s: /%s/ unexpectedly matched in %s\n' "$desc" "$re" "${FILE##*/}"; fail=$((fail + 1))
  else
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  fi
}

# Every wrapper must satisfy the shared thin-wrapper contract (AC, all tiers).
check_common() {
  local tier="$1"
  FILE="${REVIEW_DIR}/${tier}-ynab-review.md"

  if [ ! -f "$FILE" ]; then
    printf 'FAIL — wrapper missing at skills/review/%s-ynab-review.md\n' "$tier"
    fail=$((fail + 1)); return
  fi
  printf 'ok   — wrapper exists at skills/review/%s-ynab-review.md\n' "$tier"; pass=$((pass + 1))

  # Frontmatter name (this repo's skill convention).
  assert_present "[$tier] frontmatter declares name" "name: ${tier}-ynab-review"

  # Defers to the universal protocol via the plugin-root variable — no hardcoded path.
  # The needle is the literal ${CLAUDE_PLUGIN_ROOT} text the wrapper must contain.
  # shellcheck disable=SC2016
  assert_present "[$tier] references the universal protocol via \${CLAUDE_PLUGIN_ROOT}" \
    '${CLAUDE_PLUGIN_ROOT}/skills/review/ynab-review.md'
  assert_absent_re "[$tier] no hardcoded absolute/relative protocol path" \
    '(/Users/|\.\./)[^ ]*skills/review/ynab-review\.md'

  # Sets its tier.
  assert_present "[$tier] sets tier = ${tier}" "tier = ${tier}"

  # Expects the router plan block OR runs the orchestrator ad-hoc, filtered to its tier.
  assert_present "[$tier] expects a plan block" "plan block"
  assert_present "[$tier] names the /ynab-review router" "/ynab-review"
  assert_present_re "[$tier] runs the orchestrator ad-hoc, filtered to its tier" \
    "ynab-orchestrator.*ad-hoc|ad-hoc.*ynab-orchestrator|filter its output to the .*${tier}"

  # Reaffirms read-only + the namespaced tool prefix.
  assert_present_re "[$tier] reaffirms read-only" "read-only"
  assert_present "[$tier] reaffirms the namespaced tool prefix" \
    'mcp__plugin_workbench-ynab_ynab__*'

  # No hardcoded concrete tool name (swap-ready invariant, issue #87).
  assert_absent_re "[$tier] no hardcoded concrete tool name" \
    "mcp__plugin_workbench-ynab_ynab__ynab_[a-z_]+"

  # THIN: zero duplicated methodology. None of the universal protocol's
  # methodology machinery may live in a wrapper.
  assert_present_re "[$tier] declares no methodology lives here" \
    "no methodology lives here|belongs in the universal protocol"
  assert_absent_re "[$tier] no frozen-template SLOT machinery" "SLOT:"
  assert_absent_re "[$tier] no milliunit conversion rule" "milliunit"
  assert_absent_re "[$tier] no 12-section methodology body" "12-section methodology"
}

# ---- shared contract across all four tiers ------------------------------------
for tier in weekly monthly quarterly-tax annual; do
  check_common "$tier"
done

# ---- tier-specific framing notes (AC) ----------------------------------------
FILE="${REVIEW_DIR}/weekly-ynab-review.md"
assert_present_re "[weekly] notes the 7-day lookback"        "7[ -]day|past 7 days"
assert_present_re "[weekly] notes carryover uncategorized"   "carryover.*uncategorized|uncategorized.*carryover"

FILE="${REVIEW_DIR}/monthly-ynab-review.md"
assert_present_re "[monthly] notes the full prior month"     "prior (calendar )?month"
assert_present_re "[monthly] notes deeper budget-health"     "budget[ -]health"
assert_present_re "[monthly] notes forecast emphasis"        "forecast"

FILE="${REVIEW_DIR}/quarterly-tax-ynab-review.md"
assert_present_re "[quarterly-tax] notes Schedule C P&L"     "Schedule C"
assert_present_re "[quarterly-tax] notes estimated payments" "estimated[ -]payment"
assert_present_re "[quarterly-tax] notes due-date anchoring" "due date|getQuarterlyDueDates"
assert_present_re "[quarterly-tax] notes itemize-vs-standard" "itemize[ -]vs[ -]standard"

FILE="${REVIEW_DIR}/annual-ynab-review.md"
assert_present_re "[annual] notes full-year tax readiness"   "tax year|full[ -]year"
assert_present_re "[annual] notes final itemize-vs-standard" "itemize[ -]vs[ -]standard"
assert_present_re "[annual] notes missed-deductions sweep"   "missed[ -]deductions"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
