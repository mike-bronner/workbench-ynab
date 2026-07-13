#!/usr/bin/env bash
#
# dispatch-format.test.sh — verifies the dispatch-summary format spec (issue #43).
#
# Self-contained: no test framework required. Run directly:
#   bash tests/dispatch-format.test.sh
# Exits 0 if all assertions pass, 1 otherwise. Style mirrors
# tests/review-skill.test.sh: raw bash, `set -u`, PASS/FAIL counters, a
# non-zero exit when anything fails. Auto-discovered by scripts/test.sh.
#
# docs/dispatch-format.md is a static markdown contract, so the assertions are
# structural string checks against the file's contents — the regression guard
# for the issue #43 acceptance criteria (exactly five findings, the three
# severity emoji aligned with the M2-5 badges, the per-finding structure, the
# persona sign-off, the report pointer, all four tier examples, tier-agnostic,
# presentation-only).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SPEC="${REPO_ROOT}/docs/dispatch-format.md"

pass=0
fail=0

# assert_present <desc> <needle> — the spec must contain <needle> (literal).
assert_present() {
  local desc="$1" needle="$2"
  if grep -qF -- "$needle" "$SPEC"; then
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL — %s: %q not found\n' "$desc" "$needle"; fail=$((fail + 1))
  fi
}

# assert_present_re <desc> <regex> — the spec must match <regex> (ERE).
assert_present_re() {
  local desc="$1" re="$2"
  if grep -qE -- "$re" "$SPEC"; then
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL — %s: /%s/ did not match\n' "$desc" "$re"; fail=$((fail + 1))
  fi
}

# assert_absent <desc> <needle> — the spec must NOT contain <needle> (literal).
assert_absent() {
  local desc="$1" needle="$2"
  if grep -qF -- "$needle" "$SPEC"; then
    printf 'FAIL — %s: %q unexpectedly found\n' "$desc" "$needle"; fail=$((fail + 1))
  else
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  fi
}

# ---- the spec exists at the AC-specified path ---------------------------------
if [ ! -f "$SPEC" ]; then
  printf 'FAIL — spec missing at %s\n' "$SPEC"
  printf '\n0 passed, 1 failed\n'
  exit 1
fi
printf 'ok   — spec exists at docs/dispatch-format.md\n'; pass=$((pass + 1))

# ---- exactly five findings, ranked descending (AC) ----------------------------
assert_present    "declares exactly five findings"     "five (5) findings"
assert_present    "no more, no fewer"                  "never more, never fewer"
assert_present_re "ranked severity/impact descending"  "ranked by severity/impact[[:space:]]+.*descending|severity/impact.*descending"

# ---- three severity emoji with one-line semantics (AC) ------------------------
assert_present "severity emoji 🔴 action required"    "🔴"
assert_present "severity emoji 🟡 attention needed"   "🟡"
assert_present "severity emoji 🟢 good/informational" "🟢"
assert_present_re "🔴 semantics: action required"     "🔴.*action required"
assert_present_re "🟡 semantics: attention needed"    "🟡.*attention needed"
assert_present_re "🟢 semantics: good/informational"  "🟢.*good"

# ---- per-finding structure template (AC) --------------------------------------
assert_present "per-finding structure template" \
  '{emoji} **Bold one-line statement.** 1–2 sentence action.'

# ---- persona sign-off, configurable, never hard-coded (AC) --------------------
assert_present "sign-off via bin/persona.sh signoff"  "persona.sh"
assert_present "sign-off subcommand is signoff"       "signoff"
assert_present "sign-off uses the {persona} token"    "— {persona}, your financial assistant"
assert_present "sign-off name resolved via persona precedence (M2-1)" "persona.md"
# The name must never be hard-coded into the dispatch: no literal persona name.
assert_absent  "no hard-coded persona name (Hobbes)"  "Hobbes"

# ---- report pointer to the saved report path (AC) -----------------------------
assert_present    "report pointer line"                "📄 Full report:"
assert_present    "pointer uses the writer output path" "output_path"
assert_present    "references the M2-9 report-writer"  "report-writer"
assert_present_re "pointer filename shape"             "YNAB-\{Tier\}-Review-\{date\}\.html"

# ---- severity emoji aligned with the M2-5 badge taxonomy (AC) -----------------
assert_present "cross-references the frozen HTML template (M2-5)" "assets/report/template.html"
assert_present "aligns 🟢 with badge is-good"       "is-good"
assert_present "aligns 🟡 with badge is-attention"  "is-attention"
assert_present "aligns 🔴 with badge is-warning"    "is-warning"
assert_present "names the M2-5 milestone reference" "M2-5"

# ---- explicitly tier-agnostic, no branching (AC) ------------------------------
assert_present    "declares itself tier-agnostic"        "Tier-agnostic"
assert_present_re "no tier-specific sections / branching" "[Nn]o tier-specific sections and no branching"
assert_present    "only the candidate findings differ per tier" "candidate findings differ per tier"

# ---- worked examples for all four tiers, each with exactly five findings (AC) -
for heading in "Weekly tier" "Monthly tier" "Quarterly-Tax tier" "Annual tier"; do
  assert_present "worked example: $heading" "#### $heading"
done

# Count the finding lines inside each tier's worked-example block. A finding line
# is the only kind that carries bold (`**`) inside a `#### <Tier> tier` block, so
# counting `**`-bearing lines per block is locale-safe (no multibyte-emoji match
# needed) and yields exactly five per tier.
counts="$(awk '
  /^#### / { tier=$0; next }        # enter a tier example block
  /^## /   { tier="" }              # a level-2 heading ends the examples section
  tier!="" && /\*\*/ { n[tier]++ }
  END { for (t in n) printf "%d\t%s\n", n[t], t }
' "$SPEC")"

expected_tiers=("#### Weekly tier" "#### Monthly tier" "#### Quarterly-Tax tier" "#### Annual tier")
for t in "${expected_tiers[@]}"; do
  c="$(printf '%s\n' "$counts" | awk -F'\t' -v want="$t" '$2==want {print $1}')"
  if [ "${c:-0}" -eq 5 ]; then
    printf 'ok   — %s renders exactly 5 findings\n' "$t"; pass=$((pass + 1))
  else
    printf 'FAIL — %s renders %s findings, expected 5\n' "$t" "${c:-0}"; fail=$((fail + 1))
  fi
done

# ---- presentation contract only: no analysis logic, no ranking algorithm (AC) -
assert_present    "presentation contract, not analysis logic" "Presentation contract only"
assert_present_re "no analysis logic"                         "[Nn]o analysis logic"
assert_present_re "not a ranking algorithm"                   "[Nn]ot a ranking algorithm|no ranking algorithm"
assert_present    "findings arrive pre-ranked"                "pre-ranked"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
