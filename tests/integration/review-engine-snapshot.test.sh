#!/usr/bin/env bash
#
# tests/integration/review-engine-snapshot.test.sh — the M2 review-engine
# golden-snapshot integration test (issue #39, the milestone exit gate).
#
# It feeds the committed synthetic fixtures (tests/fixtures/review-engine/)
# through the REAL deterministic seams of the review engine —
#   * bin/report-writer.sh   the report assembly path (M2-9, #46)
#   * lib/tax/index.mjs       the tax engine (via tax-verdict.mjs), for the
#                             itemize-vs-standard verdict (M2-2)
#   * bin/persona.sh          the persona name/sign-off resolver (M2-1)
# — and asserts the assembled report + dispatch reproduce the proven review and
# carry the frozen template's print + accessibility contract. Nothing here is
# mocked: the fragments are the review skill's canonical output shape, and every
# structural, print, a11y, and tax-math property is asserted against the REAL
# assembled HTML.
#
# Auto-discovered by scripts/test.sh via the *.test.sh glob; run alone with
#   scripts/test.sh tests/integration/review-engine-snapshot.test.sh
# or directly with `bash tests/integration/review-engine-snapshot.test.sh`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"

FIX="$REPO_ROOT/tests/fixtures/review-engine"
FRAGS="$FIX/fragments"
WRITER="$REPO_ROOT/bin/report-writer.sh"
PERSONA="$REPO_ROOT/bin/persona.sh"
TEMPLATE="$REPO_ROOT/assets/report/template.html"
TXNS="ynab/list-transactions.json"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX"                     # never touch the developer's real ~
CFG="$SANDBOX/config.json"                 # a config with no persona → default
printf '{}\n' > "$CFG"

# Compute the itemize-vs-standard verdict for one tax-profile fixture through the
# real engine, echoing the JSON the driver prints ({recommendation, ...}).
tax_verdict() {
  YNAB_CONFIG_FILE="$CFG" node "$FIX/tax-verdict.mjs" \
    --profile "$1" --transactions "$TXNS" --itemized 22000 --as-of 2025-05-01
}

# Assemble a full report from the 14 slots (12 committed fragments + a
# verdict-driven section-12 + the live persona footer) and echo the absolute
# path the writer wrote. $1 = recommendation ('itemize'|'standard'), $2 = the
# standard-deduction figure to render, $3 = output dir.
assemble_report() {
  local rec="$1" stdded="$2" outdir="$3"
  local label
  if [ "$rec" = "itemize" ]; then label="Itemize"; else label="Standard deduction"; fi
  local sec12
  sec12="<div class=\"card\"><h2>12. Tax summary</h2>"
  sec12+="<table aria-label=\"Itemized versus standard deduction\">"
  sec12+="<thead><tr><th scope=\"col\">Basis</th><th scope=\"col\">Amount</th></tr></thead>"
  sec12+="<tbody><tr><th scope=\"row\">Itemized total</th><td class=\"num\">\$22,000</td></tr>"
  sec12+="<tr><th scope=\"row\">Standard deduction</th><td class=\"num\">\$${stdded}</td></tr></tbody></table>"
  sec12+="<p>Recommendation: <strong>${label}</strong> for this filing year.</p></div>"
  local persona
  persona="$(YNAB_CONFIG_FILE="$CFG" bash "$PERSONA" html-name)"
  YNAB_CONFIG_FILE="$CFG" bash "$WRITER" --template "$TEMPLATE" --output-dir "$outdir" \
    --tier Quarterly-Tax --date 2025-05-01 \
    --slot "kpi-dashboard=$(cat "$FRAGS/kpi-dashboard.html")" \
    --slot "section-1-classification=$(cat "$FRAGS/section-1-classification.html")" \
    --slot "section-2-income=$(cat "$FRAGS/section-2-income.html")" \
    --slot "section-3-spending=$(cat "$FRAGS/section-3-spending.html")" \
    --slot "section-4-budget-adherence=$(cat "$FRAGS/section-4-budget-adherence.html")" \
    --slot "section-5-cash-flow=$(cat "$FRAGS/section-5-cash-flow.html")" \
    --slot "section-6-categories=$(cat "$FRAGS/section-6-categories.html")" \
    --slot "section-7-accounts=$(cat "$FRAGS/section-7-accounts.html")" \
    --slot "section-8-goals=$(cat "$FRAGS/section-8-goals.html")" \
    --slot "section-9-net-worth=$(cat "$FRAGS/section-9-net-worth.html")" \
    --slot "section-10-anomalies=$(cat "$FRAGS/section-10-anomalies.html")" \
    --slot "section-11-recommendations=$(cat "$FRAGS/section-11-recommendations.html")" \
    --slot "section-12-tax-summary=$sec12" \
    --slot "footer-persona=$persona"
}

# ── AC#3: fixtures exist, are valid JSON, and carry no secrets/real data ────────
test_fixtures_are_valid_and_synthetic() {
  for f in ynab/list-transactions ynab/categories ynab/accounts ynab/months \
           tax-profile-low-deduction tax-profile-high-deduction; do
    assert_file_exists "$FIX/$f.json"
    assert_json_valid  "$FIX/$f.json"
  done
  # No YNAB token shape and no obvious real-account markers anywhere in fixtures.
  if grep -rInE 'ynab-[a-z0-9]{20,}|[0-9]{12,19}|BEGIN [A-Z ]*PRIVATE KEY' "$FIX" ; then
    fail "a fixture contains a token/real-account-shaped string"
  fi
  return 0
}

# ── AC#8: changing standard_deduction flips the verdict (real tax engine) ───────
test_standard_deduction_flip_drives_verdict() {
  local low high
  low="$(tax_verdict tax-profile-low-deduction.json)"
  high="$(tax_verdict tax-profile-high-deduction.json)"
  assert_eq "itemize"  "$(printf '%s' "$low"  | jq -r '.recommendation')" "low std deduction ⇒ itemize"
  assert_eq "standard" "$(printf '%s' "$high" | jq -r '.recommendation')" "high std deduction ⇒ standard"
  # The ONLY input that changed is the configured standard deduction.
  assert_eq "15000" "$(printf '%s' "$low"  | jq -r '.standardDeduction')"
  assert_eq "30000" "$(printf '%s' "$high" | jq -r '.standardDeduction')"
  assert_eq "22000" "$(printf '%s' "$low"  | jq -r '.itemizedTotal')" "itemized total held fixed across the flip"
  assert_eq "22000" "$(printf '%s' "$high" | jq -r '.itemizedTotal')" "itemized total held fixed across the flip"
}

# ── AC#4/#5/#6/#11 + print CSS: assemble and assert the rendered report ─────────
test_assembled_report_is_complete_and_accessible() {
  local out html
  out="$(assemble_report itemize 15000 "$SANDBOX/report-low")"
  assert_file_exists "$out"
  html="$(cat "$out")"

  # AC#6: every slot substituted — no leftover markers.
  case "$html" in *"<!-- SLOT:"*) fail "leftover SLOT marker in the rendered report" ;; esac

  # AC#4: all 12 section headings present, KPI dashboard populated (4 cards).
  local n
  for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
    assert_contains "$html" "<h2>$n. " "section $n heading present"
  done
  assert_contains "$html" 'class="kpi-grid"' "KPI dashboard grid present"
  assert_contains "$html" "Health score"     "KPI health-score card present"
  local kpi_cards
  # Count occurrences, not matching lines — `grep -c` counts lines even with -o
  # (GNU grep), so a card duplicated onto an existing line would slip past. Match
  # the repo idiom in bin/report-writer.sh:330; wrap the grep (not the pipeline)
  # to stay `set -euo pipefail`-safe when the count is zero.
  kpi_cards="$({ grep -o 'class="kpi__label"' "$out" || true; } | wc -l | tr -d '[:space:]')"
  assert_eq "4" "$kpi_cards" "exactly four KPI cards populated"

  # AC#5 + print CSS: the frozen @media print contract survived assembly.
  assert_contains "$html" "@media print"                 "@media print block present"
  assert_contains "$html" "print-color-adjust: exact"    "print color-adjust rule present"
  assert_contains "$html" "page-break-inside: avoid"     "page-break rule present"

  # AC#11 (a11y): severity badges carry text labels + aria-hidden emoji.
  assert_contains "$html" '<span aria-hidden="true">🟢</span> Good'            "Good badge shape"
  assert_contains "$html" '<span aria-hidden="true">🟡</span> Attention'       "Attention badge shape"
  assert_contains "$html" '<span aria-hidden="true">🔴</span> Action required' "Action-required badge shape"
  # AC#11 (a11y): tables labelled with scope'd headers + an aria-label.
  assert_contains "$html" 'aria-label="Transaction classification by tax line"' "table aria-label present"
  assert_contains "$html" '<th scope="col">' "table header cells carry scope"
  # AC#11 (a11y): gauges are meters with the full aria-value set. Bind the
  # assertion to the health-score gauge specifically (role + name on one element)
  # and to its complete value triple, so stripping role=meter or any aria-value*
  # from the KPI health gauge fails even though the goals gauge also renders one.
  assert_contains "$html" 'role="meter" aria-label="Financial health score"' "health-score gauge is a labelled meter"
  assert_contains "$html" 'aria-valuenow="78" aria-valuemin="0" aria-valuemax="100"' "health-score gauge carries the full aria-value set"
  local meters
  # Occurrence count, not line count (see the KPI-card note above).
  meters="$({ grep -o 'role="meter"' "$out" || true; } | wc -l | tr -d '[:space:]')"
  assert_eq "2" "$meters" "both gauges (health score + goals) render as meters"

  # Chrome invariant: the hardcoded not-tax-advice disclaimer is present.
  assert_contains "$html" "not tax advice" "not-tax-advice disclaimer present in chrome"
}

# ── AC#8 (visible in output): the flipped verdict renders into the report ───────
test_verdict_is_visible_in_the_assembled_output() {
  local out_low out_high html_low html_high low high
  # Drive the report from the REAL engine output — both the verdict and the
  # deduction figure come from tax-verdict.mjs, not hardcoded literals — so a
  # broken engine→render hand-off actually fails this test instead of the join
  # being asserted by construction.
  low="$(tax_verdict tax-profile-low-deduction.json)"
  high="$(tax_verdict tax-profile-high-deduction.json)"
  out_low="$(assemble_report \
    "$(printf '%s' "$low"  | jq -r '.recommendation')" \
    "$(printf '%s' "$low"  | jq -r '.standardDeduction')" "$SANDBOX/vis-low")"
  out_high="$(assemble_report \
    "$(printf '%s' "$high" | jq -r '.recommendation')" \
    "$(printf '%s' "$high" | jq -r '.standardDeduction')" "$SANDBOX/vis-high")"
  html_low="$(cat "$out_low")"; html_high="$(cat "$out_high")"
  assert_contains "$html_low"  "Recommendation: <strong>Itemize</strong>"            "low-deduction report recommends itemizing"
  assert_contains "$html_high" "Recommendation: <strong>Standard deduction</strong>" "high-deduction report recommends the standard deduction"
  # The reports genuinely differ on the verdict, not by coincidence of shared text.
  case "$html_low"  in *"Recommendation: <strong>Standard deduction</strong>"*) fail "low report also shows the standard verdict" ;; esac
  case "$html_high" in *"Recommendation: <strong>Itemize</strong>"*)            fail "high report also shows the itemize verdict" ;; esac
}

# ── AC#7: the dispatch summary has exactly 5 findings + a persona-signed footer ─
test_dispatch_summary_shape() {
  local out dispatch signoff
  out="$(assemble_report itemize 15000 "$SANDBOX/disp")"
  signoff="$(YNAB_CONFIG_FILE="$CFG" bash "$PERSONA" signoff)"
  # Render the golden dispatch: substitute the live report path + persona sign-off.
  dispatch="$(sed -e "s#{{output_path}}#$out#" -e "s#{{signoff}}#$signoff#" "$FIX/dispatch-summary.txt")"

  # Exactly five findings, each opening with one of the three valid severity emoji.
  local findings
  findings="$(printf '%s\n' "$dispatch" | grep -cE '^(🔴|🟡|🟢) ' || true)"
  assert_eq "5" "$findings" "dispatch carries exactly five severity-prefixed findings"
  # No other severity glyph masquerades as a finding.
  local bad
  bad="$(printf '%s\n' "$dispatch" | grep -cE '^(🟠|⚫|🔵) ' || true)"
  assert_eq "0" "$bad" "no invalid severity prefix appears"
  # Persona-signed footer closes the dispatch, in the configured persona's voice.
  local last
  last="$(printf '%s\n' "$dispatch" | sed -e '/^[[:space:]]*$/d' | tail -1)"
  case "$last" in
    "— "*", your financial assistant") : ;;
    *) fail "dispatch does not close with a persona-signed footer: [$last]" ;;
  esac
  # The report pointer resolved to the real assembled path.
  assert_contains "$dispatch" "📄 Full report: $out" "report pointer names the assembled report"
}

run_tests
