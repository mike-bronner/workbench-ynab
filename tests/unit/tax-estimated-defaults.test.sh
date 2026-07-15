#!/usr/bin/env bash
# Unit tests for the estimated-tax additions to the default US ruleset
# (assets/tax/us-tax-lines.json, issue #82): the income-tax marginal brackets,
# the quarterly due-date schedule with its uneven income-attribution boundaries,
# and the estimated-tax payment-detection matchers.
#
# Style mirrors tests/unit/us-tax-lines.test.sh: raw bash, `set -u`, PASS/FAIL
# counters, jq for JSON. node/ajv are not assumed present.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FILE="$REPO_ROOT/assets/tax/us-tax-lines.json"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
no() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

assert_jq() {
  local desc="$1" filter="$2"
  if [ "$(jq -r "$filter" "$FILE" 2>/dev/null)" = "true" ]; then ok "$desc"; else no "$desc"; fi
}
assert_eq() {
  local desc="$1" filter="$2" expected="$3" actual
  actual="$(jq -r "$filter" "$FILE" 2>/dev/null)"
  if [ "$actual" = "$expected" ]; then ok "$desc"; else no "$desc — expected: [$expected] got: [$actual]"; fi
}

command -v jq >/dev/null 2>&1 || { echo "jq is required to run these tests"; exit 2; }

echo "== us-tax-lines.json — estimated-tax defaults (#82) =="

jq empty "$FILE" >/dev/null 2>&1 && ok "file is valid JSON" || { no "file is valid JSON"; exit 1; }

# --- income-tax marginal brackets ------------------------------------------
# Brackets exist for every filing status and the two seeded tax years.
for fs in single mfj mfs hoh qw; do
  for yr in 2024 2025; do
    assert_jq "incomeTaxBracketsByYear.$fs.$yr is a non-empty array" \
      ".incomeTaxBracketsByYear.$fs[\"$yr\"] | type==\"array\" and length>0"
  done
done
# Brackets are ascending and the top bracket is unbounded (no upTo).
assert_jq "mfj 2025 brackets ascend by upTo (top omits upTo)" \
  '[.incomeTaxBracketsByYear.mfj["2025"][] | .upTo // 1e15] | (. == (sort))'
assert_jq "mfj 2025 top bracket omits upTo (unbounded)" \
  '.incomeTaxBracketsByYear.mfj["2025"][-1] | has("upTo") | not'
# Every rate is a fraction in (0,1] (never a percentage like 22). del the
# annotation-only $comment first so the walk only visits status objects.
assert_jq "every bracket rate is a fraction in (0,1]" \
  '[.incomeTaxBracketsByYear | del(.["$comment"]) | .[][][].rate] | all(. > 0 and . <= 1)'
# Pin a couple of known thresholds so a transposed digit fails green.
assert_eq "single 2025 first bracket upTo is 11925" \
  '.incomeTaxBracketsByYear.single["2025"][0].upTo' "11925"
assert_eq "mfj 2025 top rate is 0.37" \
  '.incomeTaxBracketsByYear.mfj["2025"][-1].rate' "0.37"
# qw mirrors mfj (Qualifying Surviving Spouse uses the MFJ schedule).
assert_jq "qw 2025 brackets equal mfj 2025 brackets" \
  '.incomeTaxBracketsByYear.qw["2025"] == .incomeTaxBracketsByYear.mfj["2025"]'

# --- quarterly due dates + uneven income-attribution boundaries -------------
assert_jq "quarterlyEstimatedDueDates has four quarters" \
  '.quarterlyEstimatedDueDates | length == 4'
assert_jq "every quarter carries period boundaries" \
  '[.quarterlyEstimatedDueDates[] | has("periodStartMonth") and has("periodEndMonth")] | all'
# Standard federal schedule: Apr 15 / Jun 15 / Sep 15 / Jan 15.
for entry in "1=4 15" "2=6 15" "3=9 15" "4=1 15"; do
  q="${entry%%=*}"; md="${entry#*=}"; mm="${md%% *}"; dd="${md##* }"
  assert_eq "Q$q due month is $mm" ".quarterlyEstimatedDueDates[] | select(.quarter==$q) | .month" "$mm"
  assert_eq "Q$q due day is $dd"   ".quarterlyEstimatedDueDates[] | select(.quarter==$q) | .day" "$dd"
done
# Uneven boundaries: Q2 covers Apr–May, Q4 covers Sep–Dec (period end is December,
# NOT the January due date).
assert_eq "Q2 income period starts in April" \
  '.quarterlyEstimatedDueDates[] | select(.quarter==2) | .periodStartMonth' "4"
assert_eq "Q4 income period ends in December" \
  '.quarterlyEstimatedDueDates[] | select(.quarter==4) | .periodEndMonth' "12"

# --- estimated-tax payment detection matchers -------------------------------
assert_jq "estimatedTaxPayments.payeeKeywords is a non-empty array" \
  '.estimatedTaxPayments.payeeKeywords | type=="array" and length>0'
assert_jq "payee keywords include the generic IRS signal" \
  '[.estimatedTaxPayments.payeeKeywords[] | ascii_downcase] | any(contains("irs"))'
# Owner-specific surfaces (category/account names) stay empty in the shareable
# default — a user adds their own in the profile instance.
for k in categoryNames categoryGroups accounts; do
  assert_jq "estimatedTaxPayments.$k is empty in the bundled default" \
    ".estimatedTaxPayments.$k | type==\"array\" and length==0"
done

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
