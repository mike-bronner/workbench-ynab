#!/usr/bin/env bash
#
# report-disclaimer.test.sh — verifies the canonical not-tax-advice disclaimer
# (issue #18) is (a) present in a RENDERED report sample assembled by
# bin/report-writer.sh from the frozen template, and (b) invariant across all four
# user-facing surfaces (report, dispatch, README, setup/docs) plus the canonical
# source file skills/shared/disclaimer.md.
#
# Self-contained: no framework. Raw bash, `set -u`, PASS/FAIL counters, a non-zero
# exit when anything fails — the style of tests/report-template.test.sh. Auto-
# discovered by scripts/test.sh via the *.test.sh glob.
#
# AC #7 asks specifically for a check against a "rendered report sample output", so
# this renders a real report through the writer (not just greps the template) and
# asserts the disclaimer survived assembly. AC #6 asks that the SAME string appears
# on all four surfaces, so the same literal tag is asserted against each file.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WRITER="${REPO_ROOT}/bin/report-writer.sh"
TEMPLATE="${REPO_ROOT}/assets/report/template.html"

# The canonical compact tag — the invariant string that must appear byte-for-byte
# on every surface. Its single source of truth is skills/shared/disclaimer.md; it
# is kept literal here so this test is the byte oracle that pins the wording.
TAG="⚠️ Estimates only — not tax advice. Consult a qualified professional before filing or paying."

pass=0
fail=0

# assert_file_contains <desc> <file> <needle> — <file> must contain <needle> (literal).
assert_file_contains() {
  local desc="$1" file="$2" needle="$3"
  if grep -qF -- "$needle" "$file"; then
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL — %s: %q not found in %s\n' "$desc" "$needle" "$file"; fail=$((fail + 1))
  fi
}

# ---- render a real report sample through the writer --------------------------
# Every block slot is supplied as the `no findings` sentinel (a legitimate empty
# section) so the render is deterministic and coupled only to the template's static
# chrome — where the disclaimer is hardcoded. HOME is sandboxed so the ~-default
# output path can never touch the developer's real ~/Documents.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

rendered="$(
  HOME="$SANDBOX" YNAB_CONFIG_FILE="$SANDBOX/none.json" \
  bash "$WRITER" \
    --tier Quarterly-Tax --date 2026-06-30 \
    --output-dir "$SANDBOX/reports" \
    --slot 'kpi-dashboard=no findings' \
    --slot 'section-1-classification=no findings' \
    --slot 'section-2-income=no findings' \
    --slot 'section-3-spending=no findings' \
    --slot 'section-4-budget-adherence=no findings' \
    --slot 'section-5-cash-flow=no findings' \
    --slot 'section-6-categories=no findings' \
    --slot 'section-7-accounts=no findings' \
    --slot 'section-8-goals=no findings' \
    --slot 'section-9-net-worth=no findings' \
    --slot 'section-10-anomalies=no findings' \
    --slot 'section-11-recommendations=no findings' \
    --slot 'section-12-tax-summary=no findings' \
    --slot 'footer-persona=Hobbes'
)" || {
  printf 'FAIL — report-writer did not render a sample report\n'
  printf '\n%d passed, %d failed\n' "$pass" "$((fail + 1))"
  exit 1
}

if [ -f "$rendered" ]; then
  printf 'ok   — writer rendered a sample report\n'; pass=$((pass + 1))
else
  printf 'FAIL — writer printed a path but no file exists: %s\n' "$rendered"; fail=$((fail + 1))
fi

# ---- (AC #7) the canonical disclaimer is present in the RENDERED output -------
if [ -f "$rendered" ]; then
  assert_file_contains "rendered report carries the canonical disclaimer tag" "$rendered" "$TAG"
  assert_file_contains "rendered report carries the full-disclaimer supporting text" \
    "$rendered" "estimates for organizational purposes only"
fi

# ---- (AC #6) the SAME tag is invariant across all four surfaces + source ------
assert_file_contains "report template carries the tag"  "$TEMPLATE"                                "$TAG"
assert_file_contains "dispatch spec carries the tag"     "${REPO_ROOT}/docs/dispatch-format.md"     "$TAG"
assert_file_contains "README carries the tag"            "${REPO_ROOT}/README.md"                   "$TAG"
assert_file_contains "setup output carries the tag"      "${REPO_ROOT}/commands/setup.md"           "$TAG"
assert_file_contains "canonical source defines the tag"  "${REPO_ROOT}/skills/shared/disclaimer.md" "$TAG"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
