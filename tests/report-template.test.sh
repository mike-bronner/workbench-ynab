#!/usr/bin/env bash
#
# report-template.test.sh — verifies the frozen report template (issue #42).
#
# Self-contained: no test framework required. Run directly:
#   bash tests/report-template.test.sh
# Exits 0 if all assertions pass, 1 otherwise. Style mirrors
# tests/persona-loader.test.sh: raw bash, `set -u`, PASS/FAIL counters, a
# non-zero exit when anything fails. Slots into the repo-wide test entrypoint
# (issue #4) once it lands.
#
# The template is a static asset, so the assertions are structural string checks
# against the file's contents — the regression guard for the contract documented
# in assets/report/SLOTS.md.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE="${REPO_ROOT}/assets/report/template.html"

pass=0
fail=0

# assert_present <desc> <needle> — the template must contain <needle> (literal).
assert_present() {
  local desc="$1" needle="$2"
  if grep -qF -- "$needle" "$TEMPLATE"; then
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL — %s: %q not found\n' "$desc" "$needle"; fail=$((fail + 1))
  fi
}

# assert_present_re <desc> <regex> — the template must match <regex> (ERE).
assert_present_re() {
  local desc="$1" re="$2"
  if grep -qE -- "$re" "$TEMPLATE"; then
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL — %s: /%s/ did not match\n' "$desc" "$re"; fail=$((fail + 1))
  fi
}

# assert_absent <desc> <needle> — the template must NOT contain <needle>.
assert_absent() {
  local desc="$1" needle="$2"
  if grep -qF -- "$needle" "$TEMPLATE"; then
    printf 'FAIL — %s: %q unexpectedly present\n' "$desc" "$needle"; fail=$((fail + 1))
  else
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  fi
}

# ---- the template exists ------------------------------------------------------
if [ ! -f "$TEMPLATE" ]; then
  printf 'FAIL — template missing at %s\n' "$TEMPLATE"
  printf '\n0 passed, 1 failed\n'
  exit 1
fi
printf 'ok   — template exists at assets/report/template.html\n'; pass=$((pass + 1))

# ---- all 14 named slot comments are present (core AC) -------------------------
slots=(
  "<!-- SLOT:kpi-dashboard -->"
  "<!-- SLOT:section-1-classification -->"
  "<!-- SLOT:section-2-income -->"
  "<!-- SLOT:section-3-spending -->"
  "<!-- SLOT:section-4-budget-adherence -->"
  "<!-- SLOT:section-5-cash-flow -->"
  "<!-- SLOT:section-6-categories -->"
  "<!-- SLOT:section-7-accounts -->"
  "<!-- SLOT:section-8-goals -->"
  "<!-- SLOT:section-9-net-worth -->"
  "<!-- SLOT:section-10-anomalies -->"
  "<!-- SLOT:section-11-recommendations -->"
  "<!-- SLOT:section-12-tax-summary -->"
  "<!-- SLOT:footer-persona -->"
)
if [ "${#slots[@]}" -eq 14 ]; then
  printf 'ok   — slot checklist enumerates exactly 14 slots\n'; pass=$((pass + 1))
else
  printf 'FAIL — slot checklist is not 14 entries (%d)\n' "${#slots[@]}"; fail=$((fail + 1))
fi
for slot in "${slots[@]}"; do
  assert_present "slot present: $slot" "$slot"
done

# ---- a @media print block exists (core AC) -----------------------------------
assert_present_re "an @media print block exists" "@media[[:space:]]+print"

# ---- no hardcoded persona name (core AC) -------------------------------------
assert_absent "no hardcoded \"Hobbes\" — persona is always a slot value" "Hobbes"

# ---- print contract (SKILL.md 154-162) ---------------------------------------
assert_present "print: -webkit-print-color-adjust: exact" "-webkit-print-color-adjust: exact"
assert_present "print: print-color-adjust: exact"         "print-color-adjust: exact"
assert_present "print: page-break-inside: avoid"          "page-break-inside: avoid"
assert_present "print: page-break-before: always"         "page-break-before: always"
assert_present "print: @page margin 0.75in"               "@page { margin: 0.75in; }"
assert_present "print: body font-size 11pt"               "font-size: 11pt"
assert_present "print: table font-size 10pt"              "font-size: 10pt"

# ---- dark-theme palette (AC) ---------------------------------------------------
# Coral was audited against the dark backgrounds and adjusted in-place for WCAG
# AA (issue #29): stock #e74c3c failed 4.5:1, replaced by #ef6e5e. The ratio
# audit itself is tests/unit/report-contrast.test.mjs.
assert_present "palette: navy #1a1a2e"  "#1a1a2e"
assert_present "palette: teal #16a085"  "#16a085"
assert_present "palette: coral #ef6e5e (AA-adjusted)" "#ef6e5e"
assert_present "palette: amber #f39c12" "#f39c12"
assert_absent  "palette: stock sub-AA coral #e74c3c is gone" "#e74c3c"

# ---- accessibility baseline (issue #29) ----------------------------------------
assert_present "a11y: baseline checklist comment references docs/a11y-baseline.md" "<!-- a11y-baseline: docs/a11y-baseline.md -->"
assert_present "a11y: summary keeps a visible keyboard focus outline" "summary:focus-visible"
if [ -f "${REPO_ROOT}/docs/a11y-baseline.md" ]; then
  printf 'ok   — a11y: docs/a11y-baseline.md exists\n'; pass=$((pass + 1))
else
  printf 'FAIL — a11y: docs/a11y-baseline.md missing\n'; fail=$((fail + 1))
fi

# ---- per-page print footer (AC) ----------------------------------------------
assert_present "footer renders the Generated-by line" "Generated by"
assert_present "footer carries the {{tier}} scalar slot" "{{tier}} YNAB Review"

# ---- not-tax-advice disclaimer, hardcoded (issue #18) ------------------------
# The canonical compact tag and the full banner are hardcoded into the template —
# never a slot — so fragment-stitching can never omit them.
DISCLAIMER_TAG="⚠️ Estimates only — not tax advice. Consult a qualified professional before filing or paying."
assert_present "disclaimer: canonical compact tag is hardcoded"        "$DISCLAIMER_TAG"
assert_present "disclaimer: full banner supporting text is hardcoded"  "estimates for organizational purposes only"
assert_present "disclaimer: full banner is a hardcoded section"        "class=\"disclaimer\""
assert_present "disclaimer: compact tag repeats at the top of the tax section" "class=\"tax-disclaimer\""
assert_absent  "disclaimer: never a SLOT injection point"             "SLOT:disclaimer"

# ---- scalar slots (date, tier, output path are slot values) ------------------
assert_present "scalar slot: {{tier}}"        "{{tier}}"
assert_present "scalar slot: {{report_date}}" "{{report_date}}"
assert_present "scalar slot: {{output_path}}" "{{output_path}}"

# ---- self-contained: no external assets (AC) ---------------------------------
assert_absent "no external stylesheet link" "rel=\"stylesheet\""
assert_absent "no external/any <script>"    "<script"
assert_absent "no <img> image reference"    "<img"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
