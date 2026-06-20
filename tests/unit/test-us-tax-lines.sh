#!/usr/bin/env bash
# Unit tests for assets/tax/us-tax-lines.json — the default US tax ruleset
# line catalog (issue #21). Run directly: tests/unit/test-us-tax-lines.sh
#
# Style mirrors tests/unit/test-config.sh: raw bash, `set -u`, PASS/FAIL
# counters, and a non-zero exit when anything fails. Slots into the repo-wide
# test entrypoint (tests/unit/). Uses jq, the project's established JSON tool —
# node/ajv are not assumed present.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FILE="$REPO_ROOT/assets/tax/us-tax-lines.json"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
no() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# assert_jq <desc> <jq-filter> — passes when the filter evaluates to true.
assert_jq() {
  local desc="$1" filter="$2"
  if [ "$(jq -r "$filter" "$FILE" 2>/dev/null)" = "true" ]; then
    ok "$desc"
  else
    no "$desc"
  fi
}

# assert_eq <desc> <jq-filter> <expected> — passes when the filter's raw value
# equals <expected>. Mirrors assert_eq in tests/unit/test-config.sh so exact
# values are pinned, not just types.
assert_eq() {
  local desc="$1" filter="$2" expected="$3" actual
  actual="$(jq -r "$filter" "$FILE" 2>/dev/null)"
  if [ "$actual" = "$expected" ]; then
    ok "$desc"
  else
    no "$desc — expected: [$expected] got: [$actual]"
  fi
}

command -v jq >/dev/null 2>&1 || { echo "jq is required to run these tests"; exit 2; }

echo "== us-tax-lines.json =="

# AC: committed and valid JSON.
if jq empty "$FILE" >/dev/null 2>&1; then ok "file is present and valid JSON"; else no "file is present and valid JSON"; exit 1; fi

# AC: all Schedule C lines from the prototype, each with the required fields.
for ln in 1 8 10 11 13 17 18 22 25 27a; do
  assert_jq "schedC.$ln present with schedule C + required fields" \
    "any(.lines[]; .id==\"schedC.$ln\" and .schedule==\"C\" and (.lineNumber|type==\"string\") and (.lineLabel|length>0) and (.description|length>0) and (.category==\"income\" or .category==\"expense\") and .appliesToBusinessEntities==true)"
done
# AC: line 1 is income; the rest are expenses.
assert_jq "schedC.1 is income" 'any(.lines[]; .id=="schedC.1" and .category=="income")'
assert_jq "all Schedule C lines except line 1 are expenses" \
  '[.lines[] | select(.schedule=="C" and .id!="schedC.1") | .category] | all(.=="expense")'
assert_jq "every Schedule C line applies to business entities" \
  '[.lines[] | select(.schedule=="C") | .appliesToBusinessEntities] | all(.==true)'

# AC: four Schedule A itemized buckets, household-level. The category must match
# the bucket (guards against silent drift between id and category).
for bucket in medical salt interest charitable; do
  assert_jq "schedA.$bucket present, schedule A, category==$bucket, household-level" \
    "any(.lines[]; .id==\"schedA.$bucket\" and .schedule==\"A\" and .category==\"$bucket\" and (.lineLabel|length>0) and (.description|length>0) and .appliesToBusinessEntities==false)"
done

# AC: Schedule 1 adjustment lines (at minimum these three), household-level.
# Also assert lineLabel/description are present (the data carries them; pinning
# their presence guards against silent drift even though the AC is satisfied by id).
for adj in seTaxHalfDeduction studentLoanInterest iraContributions; do
  assert_jq "sched1.$adj present, schedule 1, labelled + described, household-level" \
    "any(.lines[]; .id==\"sched1.$adj\" and .schedule==\"1\" and (.lineLabel|length>0) and (.description|length>0) and .appliesToBusinessEntities==false)"
done

# AC: a Schedule SE record covering the SE tax line at the 15.3% rate.
assert_jq "schedSE present, schedule SE, household-level" \
  'any(.lines[]; .id=="schedSE" and .schedule=="SE" and .appliesToBusinessEntities==false)'
assert_jq "schedSE carries the 15.3% rate" \
  'any(.lines[]; .id=="schedSE" and .rate==0.153)'

# AC: standardDeductionByYear has the current tax year for all five filing statuses.
# Pin exact dollar amounts (not just type) so a corrupt value can't pass green —
# matches the assert_eq convention in test-config.sh and the pinned thresholds below.
# 2024 / 2025 IRS standard deductions per filing status: status="2024 2025".
for entry in "single=14600 15000" "mfj=29200 30000" "mfs=14600 15000" "hoh=21900 22500" "qw=29200 30000"; do
  fs="${entry%%=*}"; amounts="${entry#*=}"
  d2024="${amounts%% *}"; d2025="${amounts##* }"
  assert_eq "standardDeductionByYear.$fs 2024 amount is $d2024 dollars" \
    ".standardDeductionByYear.$fs[\"2024\"]" "$d2024"
  assert_eq "standardDeductionByYear.$fs 2025 amount is $d2025 dollars" \
    ".standardDeductionByYear.$fs[\"2025\"]" "$d2025"
done
# AC: structure matches schema #20 (filing-status → four-digit year → number),
# so adding a tax year is a pure data edit.
assert_jq "standardDeductionByYear is keyed filing-status then four-digit year" \
  '[.standardDeductionByYear | to_entries[] | select(.key|test("^[a-z]+$")) | .value | keys[]] | all(test("^[0-9]{4}$"))'

# AC: thresholds object with the three required keys and values.
assert_jq "thresholds.medicalAgiPercent == 0.075" '.thresholds.medicalAgiPercent==0.075'
assert_jq "thresholds.seTaxRate == 0.153" '.thresholds.seTaxRate==0.153'
assert_jq "thresholds.saltCap == 10000" '.thresholds.saltCap==10000'

# AC: monetary unit is explicitly documented (dollars, not milliunits). Match the
# "milli" stem rather than the exact "milliunit" token so a legitimate reword
# ("milli-units", "milliunits") doesn't false-fail this guard.
assert_jq "top-level \$comment documents dollars (not milliunits)" \
  '(.["$comment"] | ascii_downcase | (contains("dollar") and contains("milli")))'
assert_jq "moneyUnit field is dollars" '.moneyUnit=="dollars"'

# AC: no vendor keyword lists / payee heuristics leak in.
VENDORS='GitHub AWS Forge DigitalOcean Cloudflare Namecheap JetBrains OpenAI'
vendor_hit=0
for v in $VENDORS; do
  if grep -qi -- "$v" "$FILE"; then echo "    leaked vendor token: $v"; vendor_hit=1; fi
done
if [ "$vendor_hit" -eq 0 ]; then ok "no prototype vendor tokens appear in the file"; else no "no prototype vendor tokens appear in the file"; fi

# AC: purely declarative — no executable logic / template expressions. The arrow
# pattern is scoped to arrow-FUNCTION shapes (`) =>` or `=> {`/`=> (`) so a
# legitimate prose arrow in a description ("income => expense") doesn't false-fail.
if grep -qE 'function|\$\{|`|<%|\)[[:space:]]*=>|=>[[:space:]]*[{(]' "$FILE"; then
  no "file contains no executable logic or template expressions"
else
  ok "file contains no executable logic or template expressions"
fi

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
