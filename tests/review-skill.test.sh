#!/usr/bin/env bash
#
# review-skill.test.sh — verifies the universal review protocol skill (issue #40).
#
# Self-contained: no test framework required. Run directly:
#   bash tests/review-skill.test.sh
# Exits 0 if all assertions pass, 1 otherwise. Style mirrors
# tests/report-template.test.sh: raw bash, `set -u`, PASS/FAIL counters, a
# non-zero exit when anything fails. Auto-discovered by scripts/test.sh.
#
# The skill is a static markdown asset, so the assertions are structural string
# checks against the file's contents — the regression guard for the contract in
# the issue #40 acceptance criteria (read-only, swap-ready tool loading, config
# via loaders, all 12 sections + 4 tiers, the frozen-template slot hand-off, and
# the milliunit rule).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILL="${REPO_ROOT}/skills/review/ynab-review.md"

pass=0
fail=0

# assert_present <desc> <needle> — the skill must contain <needle> (literal).
assert_present() {
  local desc="$1" needle="$2"
  if grep -qF -- "$needle" "$SKILL"; then
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL — %s: %q not found\n' "$desc" "$needle"; fail=$((fail + 1))
  fi
}

# assert_present_re <desc> <regex> — the skill must match <regex> (ERE).
assert_present_re() {
  local desc="$1" re="$2"
  if grep -qE -- "$re" "$SKILL"; then
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL — %s: /%s/ did not match\n' "$desc" "$re"; fail=$((fail + 1))
  fi
}

# assert_absent_re <desc> <regex> — the skill must NOT match <regex> (ERE).
assert_absent_re() {
  local desc="$1" re="$2"
  if grep -qE -- "$re" "$SKILL"; then
    printf 'FAIL — %s: /%s/ unexpectedly matched\n' "$desc" "$re"; fail=$((fail + 1))
  else
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  fi
}

# ---- the skill exists at the AC-specified path --------------------------------
if [ ! -f "$SKILL" ]; then
  printf 'FAIL — skill missing at %s\n' "$SKILL"
  printf '\n0 passed, 1 failed\n'
  exit 1
fi
printf 'ok   — skill exists at skills/review/ynab-review.md\n'; pass=$((pass + 1))

# ---- frontmatter name (AC) ----------------------------------------------------
assert_present "frontmatter declares name: ynab-review" "name: ynab-review"

# ---- hard READ-ONLY banner + not-tax-advice (AC) ------------------------------
assert_present_re "hard READ-ONLY banner at top" "READ-ONLY"
assert_present "states it never writes to YNAB"  "never writes to YNAB"
assert_present "not-tax-advice disclaimer"       "Not tax advice"

# ---- no write verbs appear anywhere (AC) -------------------------------------
assert_absent_re "no ynab_update_* write verb"    "ynab_update_"
assert_absent_re "no ynab_create_* write verb"    "ynab_create_"
assert_absent_re "no ynab_delete_* write verb"    "ynab_delete_"
assert_absent_re "no ynab_reconcile_* write verb" "ynab_reconcile_"

# ---- swap-ready tool loading: no concrete name, never the bare prefix (AC) ----
# The guard pattern itself (a concrete suffix) must never appear; the bare
# prefix and family glob are allowed and expected.
assert_absent_re "no hard-coded concrete tool name" "mcp__plugin_workbench-ynab_ynab__ynab_[a-z_]+"
assert_absent_re "no un-namespaced mcp__ynab__ reference" "mcp__ynab__"
assert_present "references the tool-name source of truth" "ynab-tools.md"
assert_present "single batched ToolSearch load" "ToolSearch"
assert_present "documents InputValidationError gotcha" "InputValidationError"

# ---- config via the shared loaders, never inline (AC) ------------------------
assert_present "persona via bin/persona.sh"        "persona.sh"
assert_present "budget/business via bin/config.sh" "config.sh"
assert_present "tax profile via loadProfile.mjs"   "loadProfile.mjs"
assert_present "config never forwarded to the MCP" "never forwarded to the vendored MCP"
assert_present "no hardcoded tax constants rule"   "No hardcoded tax constants"

# ---- all 12 methodology sections (AC) ----------------------------------------
sections=(
  "Transaction Classification"
  "Duplicate Detection"
  "Cost-Cutting"
  "Uncategorized"
  "Stale Uncleared"
  "Budget Health"
  "Unusual / Large"
  "Reconciliation Status"
  "Health Score"
  "Forecast"
  "Recommended Actions"
  "Tax Summary YTD"
)
if [ "${#sections[@]}" -eq 12 ]; then
  printf 'ok   — section checklist enumerates exactly 12 sections\n'; pass=$((pass + 1))
else
  printf 'FAIL — section checklist is not 12 entries (%d)\n' "${#sections[@]}"; fail=$((fail + 1))
fi
for s in "${sections[@]}"; do
  assert_present "section present: $s" "$s"
done
# Health Score must call out the six 1-10 sub-scores.
assert_present_re "health score has six 1-10 sub-scores" "[Ss]ix .*1-10.* sub-scores"

# ---- all four tiers in the tier matrix (AC) ----------------------------------
for tier in "weekly" "monthly" "quarterly-tax" "annual"; do
  assert_present "tier present: $tier" "$tier"
done
assert_present "tier matrix is a table" "Tier matrix"

# ---- consumes the orchestrator plan block, does not recompute schedule (AC) --
assert_present "consumes the orchestrator plan block" "plan block"
assert_present_re "does not recompute the schedule"   "[Nn]ever recompute|do .*not recompute"

# ---- frozen-template slot hand-off: all 14 slots (AC) ------------------------
slots=(
  "SLOT:kpi-dashboard"
  "SLOT:section-1-classification"
  "SLOT:section-2-income"
  "SLOT:section-3-spending"
  "SLOT:section-4-budget-adherence"
  "SLOT:section-5-cash-flow"
  "SLOT:section-6-categories"
  "SLOT:section-7-accounts"
  "SLOT:section-8-goals"
  "SLOT:section-9-net-worth"
  "SLOT:section-10-anomalies"
  "SLOT:section-11-recommendations"
  "SLOT:section-12-tax-summary"
  "SLOT:footer-persona"
)
if [ "${#slots[@]}" -eq 14 ]; then
  printf 'ok   — slot checklist enumerates exactly 14 slots\n'; pass=$((pass + 1))
else
  printf 'FAIL — slot checklist is not 14 entries (%d)\n' "${#slots[@]}"; fail=$((fail + 1))
fi
for slot in "${slots[@]}"; do
  assert_present "slot referenced: $slot" "$slot"
done
assert_present "never regenerates the whole HTML" "Never regenerate the whole HTML"

# ---- scalar slots passed through (AC) ----------------------------------------
assert_present "scalar slot {{tier}}"        "{{tier}}"
assert_present "scalar slot {{report_date}}" "{{report_date}}"
assert_present "scalar slot {{output_path}}" "{{output_path}}"

# ---- writer integration: the skill calls report-writer.sh as its FINAL assembly
#      step and surfaces the returned absolute path (issue #46) -----------------
assert_present    "has an Assemble & save final step"          "Assemble & save"
assert_present    "calls the report-writer helper"             "bin/report-writer.sh"
# shellcheck disable=SC2016  # a literal needle: no $ / backtick expansion wanted
assert_present    "captures the writer's stdout as report_path" 'report_path="$('
assert_present_re "surfaces the saved path (\$report_path) to the user" 'Surface.*report_path'
# ---- dispatch summary points at its format contract (issue #43) ---------------
assert_present    "references the dispatch-format contract" "docs/dispatch-format.md"

# ---- trust boundary: HTML-escape YNAB strings --------------------------------
assert_present "HTML-escapes untrusted YNAB strings" "HTML-escape"
# The escaping must route through the ONE shared, audited helper (issue #30), not
# ad-hoc hand-escaping — so the section emitters and persona/report-writer all use
# a single implementation that can't drift.
assert_present "routes YNAB strings through the shared escaper" "bin/html-escape.sh"

# ---- milliunit rule (AC) -----------------------------------------------------
assert_present_re "divides milliunits by 1000" "milliunit|/ ?1000|by .*1000"

# ---- multi-currency: currency_format read + formatMoney (issue #34) ----------
# The currency_format read must be WIRED, not merely mentioned: it must request
# JSON (else the MCP's markdown renderer drops six of the seven fields) and hold
# the object for the session, and every amount must route through formatMoney.
assert_present_re "currency_format read requests response_format json" \
  'response_format.*(json|"json")'
assert_present "currency_format is held for the whole session"  "holding it for the whole session"
assert_present "renders amounts via the shared formatMoney" "formatMoney"
assert_present "references the shared money helper file"    "assets/format-money.js"
assert_present "rounds by decimal_digits, not a fixed 2"    "decimal_digits"
assert_present_re "currency scope keeps the tax engine US-only" "tax engine.*US-only|US-only.*tax"
# A formatted amount carries an untrusted symbol → must be HTML-escaped (§5/§8).
assert_present_re "formatted amounts are HTML-escaped at the boundary" \
  'formatted amount is not a bare number|escape every rendered amount|formatted amount.*[Uu]ntrusted'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
