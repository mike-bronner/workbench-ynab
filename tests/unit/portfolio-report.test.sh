#!/usr/bin/env bash
#
# portfolio-report.test.sh — the cross-budget portfolio rollup surfaces (M6-7,
# issue #85): commands/ynab-portfolio.md, skills/review/portfolio-ynab-review.md,
# and the `Portfolio` tier of bin/report-writer.sh.
#
# Run directly: bash tests/unit/portfolio-report.test.sh
# Exits 0 if all assertions pass, 1 otherwise. Style mirrors
# tests/review-commands.test.sh: raw bash, `set -u`, PASS/FAIL counters, a
# non-zero exit when anything fails. Auto-discovered by scripts/test.sh.
#
# The command and skill are static markdown assets, so their assertions are
# structural string checks — but SECTION-SCOPED ones (skill_section /
# assert_in_section*) wherever the needle is a word or identifier the skill
# mentions more than once. The skill's intro lists every module identifier by
# name, so a whole-file grep for `selectBudgets` (or any sibling) is satisfied by
# that prose list even when the owning section has stopped calling the function —
# vacuous, and proven so by mutation. Scope to the section that must carry the
# behaviour; whole-file checks are reserved for genuinely document-level claims
# (the not-tax-advice banner) and marked as such.
#
# The regression guard for the AC: the slash command
# exists with valid frontmatter (AC#1), the skill resolves budgets from config
# with no hardcoded budget (AC#2), fetches per budget via the namespaced tools
# and reuses before re-fetching (AC#3), names all four rollup dimensions (AC#4),
# delegates milliunit conversion to the tested module (AC#5), aggregates
# Schedule C across business-tagged budgets into the M6-4 tracker (AC#6), and
# stays strictly read-only (AC#10).
#
# The template/print assertions (AC#7/#8) are NOT string checks against the
# skill: they RENDER a real Portfolio report through the actual report writer
# and inspect the resulting HTML, which is what "verified by inspecting rendered
# HTML" requires. That render also carries the ESCAPING cases: BOTH
# config-controlled strings the report interpolates — a hostile budget label
# (`</summary><script>…`) and the tax-profile loader's error message (which
# quotes the `tax_profile_path` override or $YNAB_TAX_PROFILE_FILE) — are routed
# through bin/html-escape.sh exactly as the skill instructs and asserted to
# arrive as inert text. Config is a trust boundary (issue #28 / GAP-13), the
# writer never re-escapes a block slot, and redact() masks home directories
# rather than markup, so the skill's rule is the only defense on either string.
#
# The AC#8 print-CSS assertions are scoped to the EXTRACTED `@media print` rule
# (print_css_block), never the whole file: the template names `@media print` in
# five prose comments that survive assembly, so a whole-file grep for it passes
# even after the real rule is deleted.
# Dispatch ordering (AC#9) is proven by the module's unit tests
# (tests/unit/portfolio-rollup.test.mjs); asserted here only as the wiring that
# the skill calls that ranking rather than improvising one.
#
# Concrete tool names are assembled at runtime from the bare prefix (never
# matched by bin/check-tool-name-sources.sh) so this file stays clean under the
# swap-ready guard.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

COMMAND_FILE="${REPO_ROOT}/commands/ynab-portfolio.md"
SKILL_FILE="${REPO_ROOT}/skills/review/portfolio-ynab-review.md"
WRITER="${REPO_ROOT}/bin/report-writer.sh"
TEMPLATE="${REPO_ROOT}/assets/report/template.html"
ESCAPER="${REPO_ROOT}/bin/html-escape.sh"

PREFIX='mcp__plugin_workbench-ynab_ynab__'   # bare prefix — guard-safe

pass=0
fail=0
FILE=""

ok() { pass=$((pass + 1)); printf 'ok   — %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL — %s\n' "$1"; }

# assert_present <desc> <literal>
assert_present() {
  if grep -qF -- "$2" "$FILE"; then ok "$1"; else no "$1: $(printf '%q' "$2") not found in ${FILE##*/}"; fi
}

# assert_present_re <desc> <ERE, case-insensitive>
assert_present_re() {
  if grep -qiE -- "$2" "$FILE"; then ok "$1"; else no "$1: /$2/ did not match in ${FILE##*/}"; fi
}

# assert_absent_re <desc> <ERE>
assert_absent_re() {
  if grep -qE -- "$2" "$FILE"; then no "$1: /$2/ unexpectedly matched in ${FILE##*/}"; else ok "$1"; fi
}

# flatten — collapse a markdown stream to one whitespace-normalized line, so a
# prose assertion survives line-wrapping. Newlines become spaces AND runs of
# spaces are squeezed: a phrase wrapped mid-sentence leaves the newline plus the
# next line's indent, so an un-squeezed flatten still fails a single-space
# pattern — which silently pushed assertions onto whichever OTHER section of the
# file happened to phrase it unwrapped.
flatten() { tr '\n' ' ' | tr -s ' '; }

# assert_present_flat_re <desc> <ERE> — matched against the flattened file.
assert_present_flat_re() {
  if flatten < "$FILE" | grep -qiE -- "$2"; then ok "$1"; else no "$1: /$2/ did not match (flattened) in ${FILE##*/}"; fi
}

# ── section-scoped assertions ────────────────────────────────────────────────
# A whole-file grep for a word as common as `budget_id` or `spending` is
# satisfied by unrelated prose anywhere in ~300 lines, so it cannot prove the
# named step actually carries the behaviour. These scope the needle to ONE
# numbered section, the stronger pattern this repo already uses in
# tests/unit/fresh-install-test-doc.test.sh and tests/unit/pre-approval-globs.test.sh.
#
# skill_section <n> — emit the body of the skill's "## <n>. …" section, up to
# (not including) the next "## " heading or "---" rule. Empty when the section is
# absent or renumbered, so every scoped assertion below goes red the moment its
# section is deleted, renamed, or its content moves elsewhere.
skill_section() {
  awk -v h="^## $1\\\\. " '
    $0 ~ h { f = 1; next }
    f && (/^## / || /^---$/) { exit }
    f
  ' "$SKILL_FILE"
}

# assert_in_section <n> <desc> <literal>
assert_in_section() {
  if skill_section "$1" | grep -qF -- "$3"; then ok "$2"; else no "$2: $(printf '%q' "$3") not found in skill §$1"; fi
}

# assert_in_section_re <n> <desc> <ERE, case-insensitive>
assert_in_section_re() {
  if skill_section "$1" | grep -qiE -- "$3"; then ok "$2"; else no "$2: /$3/ did not match in skill §$1"; fi
}

# assert_in_section_flat_re <n> <desc> <ERE> — section-scoped and newline-flattened,
# so a prose assertion survives markdown line-wrapping.
assert_in_section_flat_re() {
  if skill_section "$1" | flatten | grep -qiE -- "$3"; then ok "$2"; else no "$2: /$3/ did not match (flattened) in skill §$1"; fi
}

# print_css_block <rendered-html> — emit the body of the report's REAL
# `@media print` CSS rule, brace-counted from the rule's opening `{` to its
# matching `}`. Empty when the rule is absent.
#
# Whole-file greps cannot prove AC#8. assets/report/template.html mentions the
# literal string `@media print` in five prose HTML comments, and
# bin/report-writer.sh substitutes only `<!-- SLOT:name -->` markers — it never
# strips comments — so all five reach the rendered file. A bare
# `grep -F '@media print'` therefore stays green after the entire real rule is
# deleted. This extractor requires the at-rule AND its opening brace on one
# line, which no comment in the template satisfies, and returns nothing once the
# rule is deleted — so every assertion scoped to it goes red on that mutation.
print_css_block() {
  awk '
    !inblock && /@media[[:space:]]+print[[:space:]]*\{/ { inblock = 1; depth = 0 }
    inblock {
      opens = gsub(/\{/, "{"); closes = gsub(/\}/, "}")
      depth += opens - closes
      print
      if (depth <= 0) exit
    }
  ' "$1"
}

# assert_in_print_css <desc> <ERE, case-insensitive> — scoped to $PRINT_CSS.
assert_in_print_css() {
  if printf '%s\n' "$PRINT_CSS" | grep -qiE -- "$2"; then ok "$1"; else no "$1: /$2/ did not match inside the @media print rule"; fi
}

# The scoping is only as good as the extractor: if skill_section silently
# returned nothing, every assertion above it would pass vacuously. Prove it
# extracts a real, bounded body before relying on it.
if [ "$(skill_section 3 | wc -c)" -gt 200 ] && ! skill_section 3 | grep -q '^## '; then
  ok "skill_section extracts a bounded section body"
else
  no "skill_section extracts a bounded section body (got $(skill_section 3 | wc -c) bytes)"
fi
if [ "$(skill_section 99 | wc -c)" -le 1 ]; then
  ok "skill_section is empty for a section that does not exist"
else
  no "skill_section is empty for a section that does not exist"
fi

echo "portfolio-report.test.sh — the M6-7 cross-budget rollup surfaces"

# ── AC#1 — the slash command exists and is valid ──────────────────────────────
echo "AC#1: the /ynab-portfolio slash command"
if [ -f "$COMMAND_FILE" ]; then ok "commands/ynab-portfolio.md exists"; else
  no "commands/ynab-portfolio.md exists"
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi
FILE="$COMMAND_FILE"
# A slash command is reachable from the picker only when it opens with YAML
# frontmatter carrying a `description:` — assert the OPENING delimiter is line 1
# and that the block closes, not merely that a `---` appears somewhere.
if [ "$(head -1 "$COMMAND_FILE")" = "---" ]; then ok "command opens with YAML frontmatter"; else no "command opens with YAML frontmatter"; fi
if [ "$(awk 'NR>1 && /^---$/{print NR; exit}' "$COMMAND_FILE")" != "" ]; then ok "command frontmatter block closes"; else no "command frontmatter block closes"; fi
if awk 'NR>1 && /^---$/{exit} NR>1 && /^description: ./{found=1} END{exit !found}' "$COMMAND_FILE"; then
  ok "command frontmatter declares a non-empty description"
else
  no "command frontmatter declares a non-empty description"
fi
# The needle is the LITERAL ${CLAUDE_PLUGIN_ROOT} text the command must contain,
# so single quotes (no expansion) are the point — same idiom as review-commands.test.sh.
# shellcheck disable=SC2016
assert_present "command runs the rollup skill via \${CLAUDE_PLUGIN_ROOT}" \
  '${CLAUDE_PLUGIN_ROOT}/skills/review/portfolio-ynab-review.md'
assert_absent_re "command has no hardcoded absolute/relative skill path" \
  '(/Users/|\.\./)[^ ]*skills/review/'

# ── AC#10 — strictly read-only, on both surfaces ──────────────────────────────
echo "AC#10: strictly read-only"
for f in "$COMMAND_FILE" "$SKILL_FILE"; do
  FILE="$f"
  assert_present_re "${f##*/} declares read-only" "read-only"
  assert_present_flat_re "${f##*/} states the rollup modifies nothing" \
    "modifies no budget|never (writes|modifies)|read \+ report only"
  # The callable form of a write verb must never appear. (scripts/check-readonly.sh
  # enforces this tree-wide; pinned here so the rollup surfaces carry their own guard.)
  assert_absent_re "${f##*/} calls no write verb" \
    "${PREFIX}ynab_(update|create|delete|reconcile|set_default)"
  assert_absent_re "${f##*/} uses no bare, non-resolving namespace" 'mcp__ynab__'
  assert_absent_re "${f##*/} inlines no concrete tool name" \
    "${PREFIX}ynab_[a-z_]+"
done

# ── AC#2 — budgets come from config, nothing is hardcoded ─────────────────────
# Scoped to §1 ("Resolve the budget set from config"), the step that must carry
# the resolution. The skill's intro (:27-29) LISTS every module identifier —
# `selectBudgets`, `businessBudgets`, `aggregatePortfolio`, `aggregateScheduleC`,
# `orderFindings` — so a whole-file grep for any of them is satisfied by that one
# prose list even after the owning section stops calling the function. Proven, not
# assumed: deleting the real `selectBudgets(budgets)` call from §1 left the
# unscoped assertion green.
echo "AC#2: the budget set is resolved from the M6-6 config"
FILE="$SKILL_FILE"
assert_in_section 1 "skill sources the shared config loader" 'bin/config.sh'
assert_in_section 1 "skill reads the budgets array via _cfg_budgets" '_cfg_budgets'
assert_in_section 1 "skill selects budgets through the tested module" 'selectBudgets'
assert_in_section_re 1 "skill reads each entry's role/tag" 'role'
assert_in_section_re 1 "skill names the business role tag" 'business'
assert_in_section_flat_re 1 "skill forbids hardcoding a budget" \
  "no budget id|never hardcode a budget|No hardcoded budget"
# A UUID-shaped literal would be a hardcoded budget id — the exact AC violation.
assert_absent_re "skill contains no literal budget UUID" \
  '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
FILE="$COMMAND_FILE"
assert_absent_re "command contains no literal budget UUID" \
  '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

# ── AC#3 — namespaced, budget-scoped reads; reuse before re-fetch ─────────────
# Scoped to §2 ("Get each budget's data"), the step that must actually carry the
# fetch policy — `budget_id` and the tool prefix appear in prose elsewhere.
echo "AC#3: per-budget reads are namespaced, scoped, and reused"
FILE="$SKILL_FILE"
assert_in_section 2 "skill uses the namespaced tool family" "${PREFIX}"
assert_in_section 2 "skill defers concrete names to the tool SSoT" 'protocol/ynab-tools.md'
assert_in_section_re 2 "skill scopes each fetch to a budget_id" 'budget_id'
assert_in_section_flat_re 2 "skill reuses an existing per-budget output before re-fetching" \
  "reuse .{0,60}before you re-fetch|Reuse an existing per-budget review output|Reuse before re-fetching"

# ── AC#4 — all four rollup dimensions ─────────────────────────────────────────
# Scoped to §3 ("Aggregate"), which carries the dimension→field table. Unscoped,
# words this ordinary ("spending", "net worth") match incidental prose anywhere.
echo "AC#4: the four aggregated dimensions"
assert_in_section_re 3 "skill covers combined net worth"        'net worth'
assert_in_section_re 3 "skill covers aggregate income"          'aggregate income'
assert_in_section_re 3 "skill covers spending"                  'spending'
assert_in_section_re 3 "skill covers cross-budget Ready-to-Assign" 'ready-to-assign'
assert_in_section_re 3 "skill covers the unified health score"  'unified health score'

# ── AC#5 — milliunits converted before aggregation, AND rendered at full scale ─
echo "AC#5: milliunits are converted before aggregation"
assert_in_section_re 3 "skill states milliunits convert exactly once" \
  'converted exactly once|milliunits are converted'
assert_in_section_flat_re 3 "skill forbids summing raw milliunits" \
  "[Nn]ever sum raw +milliunits|never add a raw +milliunit"
assert_present "skill delegates the arithmetic to the tested module" 'portfolio-rollup.js'
# The primary aggregation entry point — previously asserted nowhere at all, so
# §3 could have stopped calling it without a single test noticing. Scoped, for
# the same reason as every other identifier the intro pre-mentions.
assert_in_section 3 "skill aggregates through the module entry point" 'aggregatePortfolio'
# THE RENDER BOUNDARY. The module's outputs are already in currency units, but
# `formatMoney` takes RAW MILLIUNITS and divides again — instructing the plain
# helper here renders every figure 1000× too small. The skill must name
# `formatRollupMoney` (the boundary that converts back) and must say why plain
# `formatMoney` is wrong for a rollup total; the arithmetic itself is proven in
# tests/unit/portfolio-rollup.test.mjs, which renders a real total to a string.
assert_in_section 3 "skill renders amounts through the units-correct boundary" 'formatRollupMoney'
assert_in_section_flat_re 3 "skill warns that formatMoney takes raw milliunits, not rollup totals" \
  "formatMoney.{0,120}raw.{0,20}milliunits"
assert_in_section_flat_re 3 "skill forbids hand-scaling an amount at a call site" \
  "never .{0,40}multiplying by 1000"

# ── AC#6 — consolidated Schedule C into the M6-4 tracker ──────────────────────
# Scoped to §4 ("Consolidated tax view"), which must carry the whole chain.
echo "AC#6: one consolidated YTD tax picture"
assert_in_section_re 4 "skill aggregates Schedule C"            'Schedule C'
assert_in_section 4 "skill selects the business-tagged budgets" 'businessBudgets'
assert_in_section 4 "skill aggregates them into one figure set" 'aggregateScheduleC'
assert_in_section 4 "skill feeds the M6-4 tracker library"      'lib/tax/estimatedTax.mjs'
assert_in_section_flat_re 4 "skill demands one picture, not per-budget fragments" \
  "not per-budget fragments|never one fragment per budget"
assert_in_section_flat_re 4 "skill forbids hardcoded tax constants" \
  "No tax constant is ever written here|no hardcoded tax"
# Deliberately WHOLE-FILE, unlike its neighbours: the disclaimer is a
# document-level banner (the callout above §1, restated in Hard rules), not a
# step inside §4. Scoping it to §4 would assert a placement the skill does not —
# and should not — have.
assert_present "skill carries the not-tax-advice disclaimer" 'Not tax advice'

# ── AC#9 — dispatch is severity-prefixed, most-severe first ───────────────────
# Scoped to §6 ("Dispatch summary"), the step that must carry the ordering.
echo "AC#9: dispatch ordering"
assert_in_section 6 "skill orders findings through the tested ranking" 'orderFindings'
assert_in_section_re 6 "skill states most-severe-first ordering" 'most-severe first'
assert_in_section 6 "skill follows the frozen dispatch contract" 'docs/dispatch-format.md'
assert_in_section_flat_re 6 "skill spans all budgets in the dispatch" 'every.{0,20}budget|all budgets'

# ── AC#7/#8 — RENDER a Portfolio report and inspect the HTML ──────────────────
# Not a prose check: build a real report through the real writer and assert the
# frozen template's guarantees survived into the output.
echo "AC#7/#8: a rendered Portfolio report inherits the frozen template"

# First, the SKILL's own token claims — cross-checked against the real template
# rather than against a literal repeated here. The skill is the document an agent
# reads at runtime, so a stale hex in it survives every check that only inspects
# rendered output (the renderer never reads the skill). Every colour the skill
# lists as a dark-theme token must actually exist in template.html.
token_line="$(grep -m1 -- 'the dark theme tokens' "$SKILL_FILE" || true)"
skill_tokens="$(printf '%s' "$token_line" | grep -oE '#[0-9a-fA-F]{6}' || true)"
token_count="$(printf '%s' "$skill_tokens" | grep -c . || true)"
if [ "$token_count" -eq 4 ]; then
  ok "skill lists the four dark-theme tokens"
else
  no "skill lists the four dark-theme tokens (found $token_count)"
fi
for token in $skill_tokens; do
  if grep -qF -- "$token" "$TEMPLATE"; then
    ok "skill token $token really exists in the frozen template"
  else
    no "skill token $token is NOT in the frozen template — the skill would send an agent to a colour the template does not define"
  fi
done
FILE="$SKILL_FILE"
# …and the disambiguation itself: the AC names `#e74c3c`, the template ships
# `--coral: #ef6e5e`. The skill must say so explicitly, or the next reader
# "corrects" it back and silently reverts the issue #29 contrast fix.
assert_in_section_flat_re 5 "skill names the shipped warning token" '--coral: #ef6e5e'
assert_in_section_flat_re 5 "skill explicitly forbids the AC's stale #e74c3c" \
  "do not use .{0,10}#e74c3c"

# THE ESCAPING RULE MUST NOT CARVE OUT THE BUDGET LABEL. The label is
# config-sourced, and this repo already ruled config strings are a trust boundary
# (issue #28 / GAP-13: persona.name is bounded AND pre-escaped for exactly this
# reason). It lands in a `<details><summary>` in §5's slot table, and
# bin/report-writer.sh treats every block slot as opaque, pre-escaped markup it
# never re-processes — so nothing downstream compensates for an unescaped label.
# Pin the actual CALL LINE an agent copies, not a prose claim about it. A loose
# prose regex is not good enough here and this was proven, not assumed: an
# earlier draft of this assertion matched the very carve-out text it was meant to
# forbid, passing green against the unescaped-label version of §5.
# shellcheck disable=SC2016
assert_in_section 5 "skill shows the budget label going through the escaper" \
  'safe_label="$(bash "${CLAUDE_PLUGIN_ROOT}/bin/html-escape.sh" -- "$label")"'
# The sink must itself name the ESCAPED value, so an agent reading the slot table
# without reading the rule underneath it still cannot inject a raw label.
assert_in_section 5 "slot table names the escaped label at the sink" '{escaped budget label}'
assert_in_section 5 "skill names the one shared escaper" 'bin/html-escape.sh'
# The carve-out phrasing this blocker was about: labels set AGAINST the untrusted
# list rather than included in it. Goes red if the exemption is ever reinstated.
if skill_section 5 | flatten | grep -qiE "budget labels come from config, but"; then
  no "skill does not exempt budget labels from escaping (the 'come from config, but' carve-out is back)"
else
  ok "skill does not exempt budget labels from escaping"
fi

# THE SAME TRUST BOUNDARY, ON THE TAX-LOADER ERROR PATH. §4 renders
# loadProfile()'s failure message into section-12-tax-summary, and that message
# can embed the `tax_profile_path` override or $YNAB_TAX_PROFILE_FILE — config
# again. lib/containment.mjs's redact() masks home-directory spellings only, so
# it neutralizes nothing in HTML terms, and report-writer.sh never re-processes
# a block slot. Pin the CALL LINE in §4 (the line an agent copies), the escaped
# value at its sink, and the rule's own enumeration — the same three-way pin the
# label already carries, because a rule that names three of four sources is how
# the fourth one got left out.
# shellcheck disable=SC2016
assert_in_section 4 "skill shows the tax-loader error going through the escaper" \
  'safe_tax_error="$(bash "${CLAUDE_PLUGIN_ROOT}/bin/html-escape.sh" -- "$tax_error")"'
assert_in_section 4 "skill renders the ESCAPED tax error, not the raw message" \
  '{escaped error message}'
assert_in_section 5 "slot table names the escaped tax error at the sink" \
  '{escaped error message}'
assert_in_section_flat_re 5 "escaping rule enumerates the tax-loader error message" \
  "tax-profile loader's error message"
# The enumeration's own count must track the list. It read "Three sources" while
# the tax error was the unnamed fourth; a stale count is what an agent trusts
# instead of re-reading the bullets.
assert_in_section_flat_re 5 "escaping rule counts four sources, not three" \
  "Four sources, one rule, no carve-outs"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# Point the writer at a config-free sandbox: an absent YNAB_CONFIG_FILE makes
# _cfg emit nothing, so --output-dir/--template govern and no user config is read.
slot_args=()
while IFS= read -r name; do
  [ -n "$name" ] && slot_args+=(--slot "${name}=<div class=\"card\"><h2>${name}</h2></div>")
done < <(grep -oE '<!-- SLOT:[a-z0-9-]+ -->' "$TEMPLATE" | sed -E 's/^<!-- SLOT:([a-z0-9-]+) -->$/\1/' | sort -u)

# A HOSTILE, CONFIG-SOURCED BUDGET LABEL — the trust-boundary case. A user's
# config is not a safe input: the label lands in a `<details><summary>`, and the
# writer never re-escapes a block slot. This is the label routed through the one
# shared escaper exactly as §5 instructs; the assertions after the render prove
# the payload arrives as inert TEXT, not live markup.
HOSTILE_LABEL='</summary><script>alert(1)</script><img src=x onerror=alert(2)>'
HOSTILE_LABEL_ESCAPED="$(bash "$ESCAPER" -- "$HOSTILE_LABEL")"
# The escaper must actually have neutralized it before it is ever embedded —
# otherwise the render assertions below would be testing the fixture, not the
# escaper. Fail loudly here rather than silently injecting live markup.
case "$HOSTILE_LABEL_ESCAPED" in
  *'<script>'*|*'</summary>'*|*'<img'*)
    no "the escaper neutralizes a hostile budget label (raw markup survived: $HOSTILE_LABEL_ESCAPED)" ;;
  *'&lt;script&gt;'*)
    ok "the escaper neutralizes a hostile budget label" ;;
  *)
    no "the escaper neutralizes a hostile budget label (unexpected output: $HOSTILE_LABEL_ESCAPED)" ;;
esac

# A HOSTILE TAX-PROFILE ERROR MESSAGE — the second config-controlled string that
# reaches this report as markup. loadProfile()'s failure message quotes the path
# it was given, which comes from the `tax_profile_path` config override or
# $YNAB_TAX_PROFILE_FILE, and redact() only rewrites home-directory spellings.
# No `</summary>` in this payload, deliberately: the `</summary>` count assertion
# below belongs to the LABEL case, and reusing that byte here would let a tax-error
# regression hide inside the label's own count.
HOSTILE_TAX_ERROR='tax profile unavailable: /tmp/<script>alert(3)</script><img src=x onerror=alert(4)>.json'
HOSTILE_TAX_ERROR_ESCAPED="$(bash "$ESCAPER" -- "$HOSTILE_TAX_ERROR")"
case "$HOSTILE_TAX_ERROR_ESCAPED" in
  *'<script>'*|*'<img'*)
    no "the escaper neutralizes a hostile tax-profile error (raw markup survived: $HOSTILE_TAX_ERROR_ESCAPED)" ;;
  *'&lt;script&gt;'*)
    ok "the escaper neutralizes a hostile tax-profile error" ;;
  *)
    no "the escaper neutralizes a hostile tax-profile error (unexpected output: $HOSTILE_TAX_ERROR_ESCAPED)" ;;
esac

# Give two slots the shapes the AC names: a KPI dashboard and a collapsible
# per-budget detail section.
# The `$3,500.00` and `${...}`-free HTML below are literal fixture text, not
# shell expansions — single quotes are deliberate.
# shellcheck disable=SC2016
for i in "${!slot_args[@]}"; do
  case "${slot_args[i]}" in
    kpi-dashboard=*)
      slot_args[i]='kpi-dashboard=<div class="kpi-grid"><div class="kpi"><div class="kpi__label">Combined net worth</div><div class="kpi__value is-positive">$3,500.00</div></div></div>' ;;
    # TWO budgets, deliberately: a rollup exists to combine several budgets, so a
    # single-`<details>` fixture never exercises the multi-budget collapsible
    # rendering that is the whole point — nor the print rule that must force
    # EVERY collapsible open, not just the first.
    section-10-anomalies=*)
      slot_args[i]="section-10-anomalies=<div class=\"card\"><h2>Per-budget detail</h2><details><summary>Personal</summary><div class=\"details__body\">personal detail</div></details><details><summary>Business</summary><div class=\"details__body\">business detail</div></details><details><summary>${HOSTILE_LABEL_ESCAPED}</summary><div class=\"details__body\">hostile detail</div></details></div>" ;;
    # §4's loader-failure path, escaped exactly as the skill instructs.
    section-12-tax-summary=*)
      slot_args[i]="section-12-tax-summary=<div class=\"card\"><h2>Tax summary</h2><p>${HOSTILE_TAX_ERROR_ESCAPED}</p></div>" ;;
  esac
done

report_path=""
writer_rc=0
report_path="$(YNAB_CONFIG_FILE="$SANDBOX/absent-config.json" bash "$WRITER" \
  --tier Portfolio --date 2026-07-24 \
  --template "$TEMPLATE" --output-dir "$SANDBOX/out" \
  "${slot_args[@]}" 2>"$SANDBOX/writer.err")" || writer_rc=$?

if [ "$writer_rc" -eq 0 ] && [ -f "$report_path" ]; then
  ok "the writer accepts --tier Portfolio and writes a report"
else
  no "the writer accepts --tier Portfolio and writes a report (rc=$writer_rc): $(cat "$SANDBOX/writer.err")"
fi

if [ -f "$report_path" ]; then
  FILE="$report_path"
  case "${report_path##*/}" in
    YNAB-Portfolio-Review-2026-07-24.html) ok "the report filename carries the Portfolio tier" ;;
    *) no "the report filename carries the Portfolio tier (got ${report_path##*/})" ;;
  esac
  # AC#8 — the print CSS the prototype was missing. Every assertion here is
  # scoped to the EXTRACTED RULE BODY, never the whole file: the template
  # discusses `@media print` in five prose HTML comments (lines 10, 32, 92, 199,
  # 212) that the writer passes through verbatim, so a whole-file grep for the
  # bare string survives deleting the real rule outright — proven by mutation.
  # print_css_block only matches the rule's opening line (`@media print` AND `{`
  # on the same line), so no comment can satisfy it, and it returns nothing when
  # the rule is gone — which reddens the extractor self-test and all three
  # assertions below together.
  PRINT_CSS="$(print_css_block "$report_path")"
  if [ "$(printf '%s' "$PRINT_CSS" | wc -c)" -gt 200 ] && ! printf '%s\n' "$PRINT_CSS" | grep -qF '</style>'; then
    ok "print_css_block extracts a bounded @media print rule body"
  else
    no "print_css_block extracts a bounded @media print rule body (got $(printf '%s' "$PRINT_CSS" | wc -c) bytes)"
  fi
  assert_in_print_css "print CSS forces colors to print" \
    'print-color-adjust: *exact'
  assert_in_print_css "print CSS forces collapsibles open" \
    'details > \*:not\(summary\) *\{ *display: *block'
  assert_in_print_css "print CSS sets a page margin" '@page *\{ *margin:'
  # AC#7 — the dark theme tokens, the KPI dashboard, and collapsible per-budget detail.
  #
  # DELIBERATE DEVIATION on the warning token. The AC names the prototype's
  # `#e74c3c`, but the frozen template ships `--coral: #ef6e5e` — the SAME hue
  # family, lightened in place to clear WCAG 2.1 AA contrast (issue #29) and
  # pinned by tests/unit/report-contrast.test.mjs. Asserting the literal
  # `#e74c3c` here would require reverting an a11y fix the repo already gated,
  # so the rollup inherits the shipped token. The AC's real requirement — reuse
  # the frozen template's tokens instead of regenerating CSS — is what is
  # asserted, and it holds.
  for token in '#1a1a2e' '#16a085' '#ef6e5e' '#f39c12'; do
    assert_present "rendered HTML carries the dark-theme token $token" "$token"
  done
  assert_present "rendered HTML carries the KPI dashboard" 'class="kpi-grid"'
  # Both budgets' collapsibles must survive assembly — the rollup's defining
  # shape is one <details> PER budget, so assert the second one too and pin the
  # count, which a single-fixture check could never do.
  assert_present "rendered HTML carries the first budget's collapsible" '<details><summary>Personal</summary>'
  assert_present "rendered HTML carries the second budget's collapsible" '<details><summary>Business</summary>'
  # Match the fixture's exact `<details><summary>` shape, not a bare `<details>`:
  # the template's own comments discuss `<details>/<summary>` in prose, which a
  # looser count would tally as rendered collapsibles.
  details_count="$(grep -oF -- '<details><summary>' "$report_path" | wc -l | tr -d ' ')"
  if [ "$details_count" -eq 3 ]; then
    ok "every per-budget collapsible survives assembly (3 <details>)"
  else
    no "every per-budget collapsible survives assembly (expected 3 <details>, got $details_count)"
  fi

  # THE TRUST BOUNDARY, AT THE SINK. A hostile config-sourced label must reach
  # the file as inert text. The writer documents block slots as opaque and
  # pre-escaped (bin/report-writer.sh), so this proves the ONLY defense — the
  # skill's escaping rule — actually holds end to end.
  assert_present "hostile budget label renders as escaped text" '&lt;script&gt;alert(1)&lt;/script&gt;'
  # Whole-file by design, and named for it: these two cover EVERY hostile payload
  # in the render (the label and the tax-loader error alike), so no unescaped
  # string from any source can reach the file as live markup.
  assert_absent_re "no hostile payload injects a live script element" '<script'
  assert_absent_re "no hostile payload injects a live img/onerror element" '<img[^>]*onerror'
  # The `</summary>` half of the payload is the one that would break OUT of the
  # summary element. The template legitimately contains no `</summary>` of its
  # own beyond the three fixtures', so an escaped payload leaves exactly three.
  close_summary_count="$(grep -oF -- '</summary>' "$report_path" | wc -l | tr -d ' ')"
  if [ "$close_summary_count" -eq 3 ]; then
    ok "hostile label does not break out of its <summary> (3 </summary>)"
  else
    no "hostile label does not break out of its <summary> (expected 3 </summary>, got $close_summary_count)"
  fi
  # THE TAX-LOADER ERROR PATH, AT ITS SINK. Same proof as the label, on the
  # fourth string the escaping rule now names: it must arrive as inert text in
  # section-12-tax-summary. The `<script` / `onerror` absent-assertions above are
  # whole-file, so they cover this payload too — this one pins that the escaped
  # form is actually PRESENT, which an absent-check alone can never show.
  assert_present "hostile tax-profile error renders as escaped text" \
    '&lt;script&gt;alert(3)&lt;/script&gt;'
  assert_present "hostile tax-profile error's img payload renders as escaped text" \
    '&lt;img src=x onerror=alert(4)&gt;'
  assert_present "rendered HTML reports the Portfolio tier" 'Portfolio YNAB Review'
  # The disclaimer is hardcoded in the template, so the rollup inherits it too.
  assert_present_re "rendered HTML carries the not-tax-advice disclaimer" 'not tax advice'
  # No slot marker may survive assembly.
  assert_absent_re "no unfilled SLOT marker survives" '<!-- SLOT:'
fi

# An invalid tier must still be refused — the enum was widened, not removed.
if YNAB_CONFIG_FILE="$SANDBOX/absent-config.json" bash "$WRITER" \
     --tier Rollup --date 2026-07-24 --template "$TEMPLATE" --output-dir "$SANDBOX/out" \
     >/dev/null 2>&1; then
  no "the writer still rejects an unknown tier"
else
  ok "the writer still rejects an unknown tier"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
