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
# structural string checks — the regression guard for the AC: the slash command
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
# HTML" requires. Dispatch ordering (AC#9) is proven by the module's unit tests
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

# assert_present_flat_re <desc> <ERE> — matched against the newline-flattened
# file so a prose assertion survives markdown line-wrapping.
assert_present_flat_re() {
  if tr '\n' ' ' < "$FILE" | grep -qiE -- "$2"; then ok "$1"; else no "$1: /$2/ did not match (flattened) in ${FILE##*/}"; fi
}

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
echo "AC#2: the budget set is resolved from the M6-6 config"
FILE="$SKILL_FILE"
assert_present "skill sources the shared config loader" 'bin/config.sh'
assert_present "skill reads the budgets array via _cfg_budgets" '_cfg_budgets'
assert_present "skill selects budgets through the tested module" 'selectBudgets'
assert_present_re "skill reads each entry's role/tag" 'role'
assert_present_re "skill names the business role tag" 'business'
assert_present_flat_re "skill forbids hardcoding a budget" \
  "no budget id|never hardcode a budget|No hardcoded budget"
# A UUID-shaped literal would be a hardcoded budget id — the exact AC violation.
assert_absent_re "skill contains no literal budget UUID" \
  '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
FILE="$COMMAND_FILE"
assert_absent_re "command contains no literal budget UUID" \
  '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

# ── AC#3 — namespaced, budget-scoped reads; reuse before re-fetch ─────────────
echo "AC#3: per-budget reads are namespaced, scoped, and reused"
FILE="$SKILL_FILE"
assert_present "skill uses the namespaced tool family" "${PREFIX}"
assert_present "skill defers concrete names to the tool SSoT" 'protocol/ynab-tools.md'
assert_present_re "skill scopes each fetch to a budget_id" 'budget_id'
assert_present_flat_re "skill reuses an existing per-budget output before re-fetching" \
  "reuse .{0,60}before you re-fetch|Reuse an existing per-budget review output|Reuse before re-fetching"

# ── AC#4 — all four rollup dimensions ─────────────────────────────────────────
echo "AC#4: the four aggregated dimensions"
assert_present_re "skill covers combined net worth"        'net worth'
assert_present_re "skill covers aggregate income"          'aggregate income'
assert_present_re "skill covers spending"                  'spending'
assert_present_re "skill covers cross-budget Ready-to-Assign" 'ready-to-assign'
assert_present_re "skill covers the unified health score"  'unified health score'

# ── AC#5 — milliunits converted before aggregation ────────────────────────────
echo "AC#5: milliunits are converted before aggregation"
assert_present_re "skill states milliunits convert exactly once" \
  'converted exactly once|milliunits are converted'
assert_present_flat_re "skill forbids summing raw milliunits" \
  "[Nn]ever sum raw +milliunits|never add a raw +milliunit"
assert_present "skill delegates the arithmetic to the tested module" 'portfolio-rollup.js'

# ── AC#6 — consolidated Schedule C into the M6-4 tracker ──────────────────────
echo "AC#6: one consolidated YTD tax picture"
assert_present_re "skill aggregates Schedule C"            'Schedule C'
assert_present "skill selects the business-tagged budgets" 'businessBudgets'
assert_present "skill aggregates them into one figure set" 'aggregateScheduleC'
assert_present "skill feeds the M6-4 tracker library"      'lib/tax/estimatedTax.mjs'
assert_present_flat_re "skill demands one picture, not per-budget fragments" \
  "not per-budget fragments|never one fragment per budget"
assert_present_flat_re "skill forbids hardcoded tax constants" \
  "No tax constant is ever written here|no hardcoded tax"
assert_present "skill carries the not-tax-advice disclaimer" 'Not tax advice'

# ── AC#9 — dispatch is severity-prefixed, most-severe first ───────────────────
echo "AC#9: dispatch ordering"
assert_present "skill orders findings through the tested ranking" 'orderFindings'
assert_present_re "skill states most-severe-first ordering" 'most-severe first'
assert_present "skill follows the frozen dispatch contract" 'docs/dispatch-format.md'
assert_present_re "skill spans all budgets in the dispatch" 'every.{0,20}budget|all budgets'

# ── AC#7/#8 — RENDER a Portfolio report and inspect the HTML ──────────────────
# Not a prose check: build a real report through the real writer and assert the
# frozen template's guarantees survived into the output.
echo "AC#7/#8: a rendered Portfolio report inherits the frozen template"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# Point the writer at a config-free sandbox: an absent YNAB_CONFIG_FILE makes
# _cfg emit nothing, so --output-dir/--template govern and no user config is read.
slot_args=()
while IFS= read -r name; do
  [ -n "$name" ] && slot_args+=(--slot "${name}=<div class=\"card\"><h2>${name}</h2></div>")
done < <(grep -oE '<!-- SLOT:[a-z0-9-]+ -->' "$TEMPLATE" | sed -E 's/^<!-- SLOT:([a-z0-9-]+) -->$/\1/' | sort -u)

# Give two slots the shapes the AC names: a KPI dashboard and a collapsible
# per-budget detail section.
# The `$3,500.00` and `${...}`-free HTML below are literal fixture text, not
# shell expansions — single quotes are deliberate.
# shellcheck disable=SC2016
for i in "${!slot_args[@]}"; do
  case "${slot_args[i]}" in
    kpi-dashboard=*)
      slot_args[i]='kpi-dashboard=<div class="kpi-grid"><div class="kpi"><div class="kpi__label">Combined net worth</div><div class="kpi__value is-positive">$3,500.00</div></div></div>' ;;
    section-10-anomalies=*)
      slot_args[i]='section-10-anomalies=<div class="card"><h2>Per-budget detail</h2><details><summary>Personal</summary><div class="details__body">detail</div></details></div>' ;;
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
  # AC#8 — the print CSS the prototype was missing. Assert the block AND its
  # substantive rules, so an empty `@media print {}` could never pass.
  assert_present "rendered HTML carries the @media print block" '@media print'
  assert_present_re "print CSS forces collapsibles open" 'details > \*:not\(summary\) *\{ *display: *block'
  assert_present_re "print CSS sets a page margin" '@page'
  # AC#7 — the dark theme tokens, the KPI dashboard, and collapsible per-budget detail.
  #
  # DELIBERATE DEVIATION on the warning token. The AC names the prototype's
  # `#e74c3c`, but the frozen template ships `--coral: #ef6e5e` — the SAME hue
  # family, darkened in place to clear WCAG 2.1 AA contrast (issue #29) and
  # pinned by tests/unit/report-contrast.test.mjs. Asserting the literal
  # `#e74c3c` here would require reverting an a11y fix the repo already gated,
  # so the rollup inherits the shipped token. The AC's real requirement — reuse
  # the frozen template's tokens instead of regenerating CSS — is what is
  # asserted, and it holds.
  for token in '#1a1a2e' '#16a085' '#ef6e5e' '#f39c12'; do
    assert_present "rendered HTML carries the dark-theme token $token" "$token"
  done
  assert_present "rendered HTML carries the KPI dashboard" 'class="kpi-grid"'
  assert_present "rendered HTML carries a collapsible per-budget section" '<details><summary>Personal</summary>'
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
