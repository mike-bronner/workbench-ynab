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

# ---- section-scoped assertions ------------------------------------------------
# Whole-file greps above are fine for needles that appear exactly once, or for
# genuinely document-level claims (the READ-ONLY banner, the write-verb bans).
# They are NOT fine where the needle also appears in unrelated prose: e.g.
# `bin/html-escape.sh` is named in §8's slot table (footer-persona) and
# `tax profile unavailable (<error.kind>)` is named in §4, so a whole-file check
# for either is satisfied by text that has nothing to do with the rule being
# pinned. Those assertions are scoped to the section that must carry the
# behaviour, mirroring tests/unit/portfolio-report.test.sh.

# skill_section <n> — emit the body of the skill's "## <n>. …" section, up to (not
# including) the next "## " heading or "---" rule. Empty when the section is
# deleted or renumbered, so every scoped assertion goes red when its section moves.
skill_section() {
  awk -v h="^## $1\\\\. " '
    $0 ~ h { f = 1; next }
    f && (/^## / || /^---$/) { exit }
    f
  ' "$SKILL"
}

# skill_subsection <heading-prefix> — emit the body of the skill's
# "### <heading-prefix>…" subsection, up to the next "## "/"### " heading or "---".
# Both extractors drop the heading line itself (`next`): a heading restates its own
# section's topic words, so including it would let the heading satisfy an assertion
# meant to pin the body.
skill_subsection() {
  awk -v h="$1" '
    index($0, "### " h) == 1 { f = 1; next }
    f && (/^## / || /^### / || /^---$/) { exit }
    f
  ' "$SKILL"
}

# flatten — collapse newlines/runs of spaces, so a prose assertion survives
# markdown line-wrapping.
flatten() { tr '\n' ' ' | tr -s ' '; }

# assert_in <desc> <text> <literal> — <text> must contain <literal>.
assert_in() {
  local desc="$1" text="$2" needle="$3"
  if printf '%s\n' "$text" | grep -qF -- "$needle"; then
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL — %s: %q not found in section\n' "$desc" "$needle"; fail=$((fail + 1))
  fi
}

# assert_in_flat_re <desc> <text> <regex> — <text>, newline-flattened, must match.
assert_in_flat_re() {
  local desc="$1" text="$2" re="$3"
  if printf '%s\n' "$text" | flatten | grep -qE -- "$re"; then
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL — %s: /%s/ did not match (flattened) in section\n' "$desc" "$re"; fail=$((fail + 1))
  fi
}

# assert_section_nonempty <desc> <text> — the extractor found the section at all.
# Without this, every scoped assertion below would fail with a confusing message
# (rather than "the section is gone") if a heading were renamed.
assert_section_nonempty() {
  local desc="$1" text="$2"
  if [ -n "$text" ]; then
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL — %s: section extractor returned nothing\n' "$desc"; fail=$((fail + 1))
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

# ---- a tax-loader failure never puts errors[] detail in the report (#235) -----
# `error.errors[]` is intentionally raw for programmatic callers (#225 AC #3):
# each entry's `path`/`params` embeds the offending JSON property name verbatim,
# and a property name can be secret-shaped. The report is human-facing output, so
# the unavailable-message must carry the redacted `error.kind` only — the old
# "tax profile unavailable: <error path>" form interpolated the raw path.
#
# Scoped to §4 (the section that states the rule): the unavailable-message string
# is now quoted in §8's trust-boundary contract too, so a whole-file check for it
# would pass even if §4 stopped restricting the message at all.
s4="$(skill_section 4)"
assert_section_nonempty "§4 (config loaders) is present and extractable" "$s4"

assert_absent_re "tax-unavailable message does not interpolate the raw error path" \
  'unavailable: <error'
# shellcheck disable=SC2016  # literal needles: markdown backticks, no expansion
assert_in "§4 tax-unavailable message reports error.kind" "$s4" \
  'tax profile unavailable (<error.kind>)'
# shellcheck disable=SC2016
assert_in "§4 pins error.kind to the fixed enum values" "$s4" \
  '`schema` / `io` / `parse` / `depth`'
# shellcheck disable=SC2016
assert_in "§4 raw errors[] detail is banned from the report" "$s4" \
  'never the `error.errors[]`'

# ---- error.message is scoped to the NON-HTML surface only (issue #273) --------
# The old wording ("Report only `error.kind` + `error.message`") named one rule for
# every surface, so it read as license to interpolate `error.message` into the
# `SLOT:section-12-tax-summary` HTML fragment. That message embeds the
# caller-supplied `tax_profile_path` / $YNAB_TAX_PROFILE_FILE through redact(),
# which masks home directories only and does NOT HTML-escape. §4 must now split the
# two surfaces explicitly and forbid the message on the markup side.
assert_in "§4 splits the two reporting surfaces" "$s4" \
  'Two surfaces, two different rules'
# shellcheck disable=SC2016
assert_in_flat_re "§4 forbids error.message in the HTML tax-summary fragment" "$s4" \
  'SLOT:section-12-tax-summary.*Never render .error\.message. there'
# Two assertions, same bullet — mirroring the pairing above. The first pins the
# surface itself (which surface, and why it is exempt: plain text, not markup).
# The second pins the allowance CLAUSE verbatim, and is the one that carries the
# `error.message` token: on its own the first regex stops at `error\.kind` and
# never mentions `error.message` at all, so a meaning-changing edit that revokes
# the allowance ("may report `error.kind` only. Never `error.message` here
# either") would leave it green. Pinning `may report `error.kind` + `error.message``
# as one contiguous clause means both directions redden — deleting the allowance,
# or narrowing it to the kind alone.
# shellcheck disable=SC2016
assert_in_flat_re "§4 scopes the non-HTML dispatch/session surface as plain text, not markup" "$s4" \
  'dispatch summary and the session output .* plain text, not markup .* report .error\.kind'
# shellcheck disable=SC2016
assert_in_flat_re "§4 allows error.message on that surface, by name" "$s4" \
  'dispatch summary and the session output .* may report .error\.kind. [+] .error\.message.'
# shellcheck disable=SC2016
assert_in_flat_re "§4 states redact() does not HTML-escape" "$s4" \
  'redact.*(does not HTML-escape|masks home-directory spellings)'

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

# ---- the tax-loader failure text is a NAMED, ESCAPED source (issue #273) ------
# Every needle below is scoped to the trust-boundary subsection. Both are
# genuinely ambiguous document-wide: `bin/html-escape.sh` appears in §8's slot
# table (footer-persona) and `tax profile unavailable (<error.kind>)` appears in
# §4, so whole-file checks would stay green with the trust-boundary contract
# deleted outright.
tb="$(skill_subsection 'Trust boundary')"
assert_section_nonempty "§8 trust-boundary subsection is present and extractable" "$tb"

assert_in_flat_re "trust boundary enumerates its escaped sources as four" "$tb" \
  'Four sources, one rule, no carve-outs'
# The "four" above is a prose claim; these four pin it to actual named sources, so
# the count cannot drift away from the list it describes.
assert_in "…source 1: payee names and memos" "$tb" \
  "**Payee names and memos**"
assert_in "…source 2: category and account names" "$tb" \
  "**Category and account names**"
assert_in "…source 3: formatted amounts (the off-the-wire currency_symbol)" "$tb" \
  "**Formatted amounts**"
assert_in "…source 4: the tax-loader failure text" "$tb" \
  "**The tax-loader failure text**"
# shellcheck disable=SC2016
assert_in "…identifying §4's profile-failure string" "$tb" \
  'tax profile unavailable (<error.kind>)'
# The §12 tax-year failure fills the SAME slot on the SAME failure class; naming
# only its sibling would ship the rule half-applied.
# shellcheck disable=SC2016
assert_in "…and the sibling tax-year failure string that fills the same slot" "$tb" \
  'tax year unresolvable (<error kind>)'
assert_in "…and the slot both of them reach" "$tb" \
  "SLOT:section-12-tax-summary"
# The escaper call itself, not just a mention of the helper: `--` before the value
# so a failure text starting `-h`/`--raw` is escaped as DATA, never a flag.
# shellcheck disable=SC2016
assert_in "routes the failure text through the shared escaper before the slot fill" "$tb" \
  'safe_tax_error="$(bash "${CLAUDE_PLUGIN_ROOT}/bin/html-escape.sh" -- "$tax_error")"'
assert_in_flat_re "trust boundary states config strings are a trust boundary" "$tb" \
  'trust boundary, not trusted input'
assert_in_flat_re "trust boundary admits no exemption beyond the pre-escaped persona name" "$tb" \
  'No string interpolated into a fragment is outside this rule'

# The §12 failure path must point back at the escaping contract where it is
# rendered, not only from §8 — an instruction is followed where it is read.
s12="$(skill_subsection '§12 call')"
assert_section_nonempty "§12 call subsection is present and extractable" "$s12"
assert_in_flat_re "§12 routes the tax-year failure text through the escaper too" "$s12" \
  'tax year unresolvable .*bin/html-escape\.sh. before it fills the slot'
# shellcheck disable=SC2016
assert_in_flat_re "§12 tax-year failure carries the kind only, never a thrown message" "$s12" \
  'carries the error \*\*kind\*\* only .* never a thrown error.s .message.'

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
