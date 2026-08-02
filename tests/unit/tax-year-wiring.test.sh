#!/usr/bin/env bash
#
# tests/unit/tax-year-wiring.test.sh — the active tax-year rule is actually WIRED
# into the review path, not just implemented in lib/tax
# (issue #17, AC #5 / #6 / #7).
#
# WHY THIS FILE EXISTS
#   lib/tax/taxYear.mjs and computeTaxSummary's boundary branch are covered by
#   tests/unit/tax-year.test.mjs and tests/unit/tax-engine.test.mjs. Those prove the
#   RULE. They cannot prove the rule is REACHED: the review path is an
#   LLM-executed markdown protocol (skills/review/ynab-review.md) driven by a
#   markdown planner (agents/ynab-orchestrator.md), so for that half the prose IS
#   the implementation. A first pass at this issue shipped a correct, well-tested
#   library that no document ever called — the January changeover would have thrown
#   on a real run, and the header label had no producer connected to it. A second
#   pass shipped the same shape one layer up: `_cfg_tax_year` and `resolveTaxYear`
#   were both correct and both unit-tested, while no command resolved the first or
#   forwarded its value to the second — a user could set `config.tax_year` and see
#   no behavioural change anywhere. This file pins the connections, hop by hop, so
#   neither regression can recur silently.
#
# SCOPING RULE (repo lesson: whole-file greps go vacuous on documents)
#   Every assertion here is scoped to the SECTION it names, via section_of(), and
#   section_of DROPS THE HEADING LINE — a heading that restates the section's own
#   topic ("§12 call — the tax summary and the active tax year") would otherwise
#   satisfy a check meant to pin the body. The vocabulary these assertions search
#   for ("tax_year", "resolveTaxYear", "changeover") appears many times across both
#   documents, so an unscoped grep would pass on a real regression.
#
# Harness convention: issue #4 / tests/lib/assert.sh — `test_*` functions,
# `run_tests` at the end, auto-discovered by scripts/test.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"

SKILL="$REPO_ROOT/skills/review/ynab-review.md"
AGENT="$REPO_ROOT/agents/ynab-orchestrator.md"
TAX_SKILL="$REPO_ROOT/skills/estimated-tax/SKILL.md"

# Every command that dispatches the orchestrator. The router is the scheduled
# path; the other four are the ad-hoc single-tier paths. The override has to
# reach ALL of them — a user who pins config.tax_year and then runs
# /ynab-weekly-review must not silently get a different year than the scheduled
# run gives them.
DISPATCH_COMMANDS=(
  "$REPO_ROOT/commands/ynab-review.md"
  "$REPO_ROOT/commands/ynab-weekly-review.md"
  "$REPO_ROOT/commands/ynab-monthly-review.md"
  "$REPO_ROOT/commands/ynab-quarterly-tax-review.md"
  "$REPO_ROOT/commands/ynab-annual-review.md"
)

# section_of <file> <heading-literal> — the BODY of the markdown section whose
# heading line contains <heading-literal>, up to the next heading of the same or a
# higher level. The heading line itself is excluded (see SCOPING RULE above).
section_of() {
  local file="$1" needle="$2"
  awk -v needle="$needle" '
    # Depth of a heading line ("### x" → 3); 0 when the line is not a heading.
    function depth(s,   n) { if (s !~ /^#+ /) return 0; n = index(s, " "); return n - 1 }
    !inside {
      if (depth($0) > 0 && index($0, needle) > 0) { inside = 1; want = depth($0) }
      next
    }
    { d = depth($0); if (d > 0 && d <= want) { inside = 0; next } ; print }
  ' "$file"
}

# assert_section_contains <file> <heading> <literal> <desc>
assert_section_contains() {
  local file="$1" heading="$2" needle="$3" desc="$4" body
  body="$(section_of "$file" "$heading")"
  [ -n "$body" ] || fail "$desc — section '$heading' not found in $(basename "$file") (or empty)"
  assert_contains "$body" "$needle" "$desc"
}

# assert_section_lacks <file> <heading> <literal> <desc>
assert_section_lacks() {
  local file="$1" heading="$2" needle="$3" desc="$4" body
  body="$(section_of "$file" "$heading")"
  [ -n "$body" ] || fail "$desc — section '$heading' not found in $(basename "$file") (or empty)"
  case "$body" in
    *"$needle"*) fail "$desc (found '$needle')" ;;
  esac
  return 0
}

# prompt_block_of <file> — the body of the FENCED CODE BLOCK that carries the
# orchestrator dispatch prompt, identified by its `budget_name:` line. Fences
# themselves are excluded. Scoping to this block matters: `tax_year` appears in
# prose in every one of these files, so a section- or file-scoped grep would pass
# on a command that resolved the override and then forgot to forward it — which is
# the exact regression AC #6 shipped with. The block is buffered and only emitted
# once `budget_name:` is seen inside it, so preceding shell/js blocks (which also
# mention tax_year) are skipped rather than matched.
prompt_block_of() {
  awk '
    /^```/ { if (inside) { if (found) printf "%s", buf; inside = 0; found = 0; buf = "" }
             else { inside = 1; found = 0; buf = "" }
             next }
    inside { buf = buf $0 "\n"; if (index($0, "budget_name:") > 0) found = 1 }
  ' "$1"
}

# --- the extractor itself, proven before anything relies on it ----------------

test_prompt_block_of_selects_only_the_dispatch_block() {
  # If this returned the whole file (or the wrong block), the boundary assertions
  # below would be unscoped greps wearing a disguise. The fixture plants the needle
  # in three places it must NOT be found: prose, an earlier fenced block, and a
  # later fenced block — none of which carry `budget_name:`.
  local fixture body
  fixture="$(mktemp)"
  printf '%s\n' \
    'tax_year: DECOY_PROSE' \
    '```bash' \
    'tax_year: DECOY_EARLIER_BLOCK' \
    '```' \
    'more prose' \
    '```' \
    'budget_name: <the real one>' \
    'tax_year: REAL' \
    '```' \
    '```' \
    'tax_year: DECOY_LATER_BLOCK' \
    '```' > "$fixture"
  body="$(prompt_block_of "$fixture")"
  rm -f "$fixture"

  assert_contains "$body" "tax_year: REAL" "the dispatch block's own lines are returned"
  assert_contains "$body" "budget_name:" "the block is the one carrying budget_name"
  for decoy in DECOY_PROSE DECOY_EARLIER_BLOCK DECOY_LATER_BLOCK; do
    case "$body" in
      *"$decoy"*) fail "prompt_block_of leaked $decoy — it is not scoped to the dispatch block" ;;
    esac
  done
  case "$body" in
    *'```'*) fail "prompt_block_of returned a fence line" ;;
  esac
  return 0
}

test_section_of_excludes_the_heading_and_stops_at_the_next_peer() {
  # If section_of silently returned the whole file (or the heading line), every
  # "scoped" assertion below would be an unscoped grep wearing a disguise. Prove it
  # on a fixture with a deliberate decoy: the needle appears in the heading and in a
  # LATER sibling section, and must be found in neither.
  local fixture body
  fixture="$(mktemp)"
  printf '%s\n' \
    '## Alpha DECOY' \
    'alpha body' \
    '### Alpha child' \
    'child body' \
    '## Beta' \
    'DECOY in beta' > "$fixture"
  body="$(section_of "$fixture" "Alpha")"
  rm -f "$fixture"

  assert_contains "$body" "alpha body" "section body is returned"
  assert_contains "$body" "child body" "a deeper sub-section stays inside the section"
  case "$body" in
    *DECOY*) fail "section_of leaked the heading line or a sibling section (DECOY present)" ;;
  esac
  case "$body" in
    *"in beta"*) fail "section_of ran past the next peer heading into Beta" ;;
  esac
  return 0
}

# --- AC #6: the config override actually reaches a run ------------------------
#
# `_cfg_tax_year` (shell) and `resolveTaxYear` (engine) were both correct and both
# unit-tested while NOTHING called the first or forwarded its value to the second.
# A user could set config.tax_year and see zero behavioural change. These pin the
# two hops in between: command resolves it, command forwards it.

test_every_dispatch_command_resolves_the_tax_year_override() {
  local file
  for file in "${DISPATCH_COMMANDS[@]}"; do
    local name; name="$(basename "$file")"
    assert_contains "$(cat "$file")" '_cfg_tax_year' \
      "$name resolves config.tax_year through the shared loader"
    # Fail-closed, like _cfg_timezone beside it: a malformed year must stop the run,
    # not fall back to the review date and report a year the user did not ask for.
    # shellcheck disable=SC2016  # single quotes are deliberate: these are literal
    # needles searched for in a document, not expansions to perform.
    assert_contains "$(cat "$file")" 'tax_year="$(_cfg_tax_year)" || exit 1' \
      "$name resolves the override as a hard stop"
  done
}

test_every_dispatch_command_forwards_tax_year_in_its_prompt() {
  # The hop that was missing. Scoped to the dispatch prompt block itself, because
  # every one of these files already says "tax_year" in prose.
  local file
  for file in "${DISPATCH_COMMANDS[@]}"; do
    local name block; name="$(basename "$file")"
    block="$(prompt_block_of "$file")"
    [ -n "$block" ] || fail "$name has no orchestrator dispatch prompt block"
    assert_contains "$block" "tax_year:" \
      "$name forwards tax_year to the orchestrator"
    # An unset override must send NO line, so plan.tax_year.override is null and the
    # engine derives the year. A command that sent an empty `tax_year:` would hand
    # the planner a value to interpret.
    assert_contains "$block" "omit this line entirely when it is empty" \
      "$name omits the tax_year line when no override is set"
  done
}

test_orchestrator_inputs_contract_accepts_tax_year() {
  # The receiving end. The planner is barred from reading config.json, so if its
  # Inputs contract has no tax_year field, a forwarded value has nowhere to land.
  local h='## Inputs'
  # Single quotes are deliberate: these are literal needles searched for in a
  # document, not expansions to perform.
  # shellcheck disable=SC2016
  assert_section_contains "$AGENT" "$h" '`tax_year`' \
    "the orchestrator's Inputs contract declares tax_year"
  assert_section_contains "$AGENT" "$h" '_cfg_tax_year' \
    "the Inputs contract names the dispatcher-side resolver it comes from"
  assert_section_contains "$AGENT" "$h" 'plan.tax_year.override' \
    "the Inputs contract says where the value goes"
}

test_orchestrator_override_row_points_at_the_prompt_not_the_config_file() {
  # The contradiction Holmes found: the override row told the planner to read
  # `config.tax_year` while a bullet above forbade it reading config at all. The row
  # must name the prompt as the source, or the instruction is unfollowable.
  local h='Tax-year inputs' body
  body="$(section_of "$AGENT" "$h")"
  [ -n "$body" ] || fail "the orchestrator's tax-year section is missing"
  local row
  row="$(printf '%s\n' "$body" | grep -F "| \`override\` |")"
  [ -n "$row" ] || fail "the tax-year table has no override row"
  assert_contains "$row" 'your prompt' \
    "the override row sources the value from the dispatch prompt"
  assert_contains "$row" 'never read the config file yourself' \
    "the override row restates that the planner does not read config.json"
}

test_estimated_tax_tracker_resolves_the_override_itself() {
  # The parallel path. /ynab-tax does not go through the orchestrator, so it has to
  # source the loader itself; it previously referenced `config.tax_year` as if some
  # earlier step had already resolved it, and no step had.
  local h='Procedure'
  # Single quotes are deliberate: these are literal needles searched for in a
  # document, not expansions to perform.
  # shellcheck disable=SC2016
  assert_section_contains "$TAX_SKILL" "$h" 'tax_year="$(_cfg_tax_year)" || exit 1' \
    "the tracker resolves the override as a hard stop"
  assert_section_contains "$TAX_SKILL" "$h" '_cfg_timezone' \
    "the tracker resolves the zone from the same loader"
}

test_the_reminder_window_is_deliberately_off_the_override_chain() {
  # A guard against a plausible WRONG fix: Step 1d's due-date window is the CALENDAR
  # year by design. Applying config.tax_year there would silence every reminder for a
  # user who pinned a year. Pinned so the reasoning survives the next reader.
  local body
  body="$(section_of "$REPO_ROOT/commands/ynab-review.md" 'Dispatch quarterly estimated-tax reminders')"
  [ -n "$body" ] || fail "the reminder step is missing from the router"
  assert_contains "$body" 'Number(today.slice(0, 4))' \
    "the reminder window keys on the calendar year of today"
  assert_contains "$body" 'deliberately NOT the resolved' \
    "the reminder step says the tax-year override does not apply to it"
}

# --- AC #5 / #7: the review skill actually calls the engine -------------------

CALL_H='§12 call'

test_review_skill_calls_compute_tax_summary_with_the_resolved_inputs() {
  # AC #7's real content: the year reaches the report because the skill CALLS the
  # engine with the plan's inputs. Each field is pinned separately — a call site
  # that kept `asOfDate` but dropped `timezone` would still resolve, off the host
  # zone, which is the exact bug the rule exists to prevent.
  assert_section_contains "$SKILL" "$CALL_H" "computeTaxSummary(profile, {" \
    "the skill shows a concrete computeTaxSummary call"
  assert_section_contains "$SKILL" "$CALL_H" "asOfDate:        plan.tax_year.review_date" \
    "the anchor comes from the plan's review date"
  assert_section_contains "$SKILL" "$CALL_H" "timezone:        plan.tax_year.timezone" \
    "the configured zone is passed, not the host zone"
  assert_section_contains "$SKILL" "$CALL_H" "taxYearOverride: plan.tax_year.override" \
    "config.tax_year is threaded through as the override"
  assert_section_contains "$SKILL" "$CALL_H" "summary.meta.taxYearLabel" \
    "the header label is read back off the engine's result"
}

test_review_skill_forbids_supplying_a_tax_year() {
  # The staleness bug is re-introduced by PASSING a year, so the instruction not to
  # is load-bearing prose, not commentary.
  assert_section_contains "$SKILL" "$CALL_H" "**Never pass a tax year.**" \
    "the skill forbids supplying a tax year"
  assert_section_contains "$SKILL" "$CALL_H" "getStandardDeduction(summary.meta.taxYear" \
    "year-keyed accessors use the RESOLVED year"
}

test_review_skill_wires_the_january_changeover() {
  # Holmes's blocker: computeTaxSummary THROWS in this window without priorYearClose,
  # so a skill that never mentions it turns every Jan 1–14 run into a hard failure.
  assert_section_contains "$SKILL" "$CALL_H" "priorYearClose" \
    "the changeover's required input is named"
  assert_section_contains "$SKILL" "$CALL_H" "summary.yearBoundary.priorYearClose" \
    "both years are rendered from the engine's boundary result"
  assert_section_contains "$SKILL" "$CALL_H" "plan.tax_year.changeover" \
    "the changeover is driven by the plan, not recomputed"
}

test_fetch_discipline_exempts_the_changeover_window() {
  # "Don't widen the pull" barred the one fetch a dual-year report needs. The carve-
  # out has to live in the fetch-discipline section itself — stating it only in §12
  # leaves the contradiction in force at the place the skill actually reads it.
  assert_section_contains "$SKILL" "Fetch discipline" "changeover" \
    "fetch discipline addresses the changeover window"
  assert_section_contains "$SKILL" "Fetch discipline" "already unioned" \
    "the prior-year window is inside the plan, so fetching it is not widening"
  assert_section_contains "$SKILL" "Fetch discipline" "do **not** widen the pull yourself" \
    "a missing changeover window stays a planning bug, not a skill workaround"
}

test_plan_inputs_table_carries_the_tax_year_fields() {
  # §1 is where the skill learns what the plan gives it. All four fields, or the
  # call in §12 has no documented source.
  local h='1. Inputs — the orchestrator plan block'
  for field in review_date timezone override changeover; do
    assert_section_contains "$SKILL" "$h" "plan.tax_year.$field" \
      "the plan-inputs table documents plan.tax_year.$field"
  done
}

# --- the orchestrator produces those inputs ----------------------------------

test_orchestrator_emits_the_tax_year_inputs() {
  local h='Tax-year inputs'
  for field in review_date timezone override changeover; do
    assert_section_contains "$AGENT" "$h" "$field" \
      "the orchestrator's tax-year section defines $field"
  done
  assert_section_contains "$AGENT" "$h" "prior_year_window" \
    "the changeover carries a prior-year pull window"
  assert_section_contains "$AGENT" "$h" "union" \
    "the prior-year window is unioned into data_pull"
}

test_orchestrator_never_writes_the_label_itself() {
  # Two producers of the label is exactly the drift AC #7 forbids. The planner is
  # told to emit INPUTS; if it ever emitted a rendered label, the writer's shape gate
  # would happily accept it and nothing downstream would notice.
  local h='Tax-year inputs'
  # Pinned on BODY text, not the heading — the heading already says "never the
  # label", and section_of drops it precisely so a restated heading cannot satisfy
  # an assertion meant to pin the instruction itself.
  assert_section_contains "$AGENT" "$h" "You do **not** own the year itself or" \
    "the section states the planner owns neither the year nor its label"
  assert_section_contains "$AGENT" "$h" "**second producer**" \
    "the section gives the reason: a second producer of the label would drift"
  assert_section_lacks "$AGENT" "$h" 'Tax Year 2' \
    "the orchestrator's tax-year section renders no 'Tax Year YYYY' label"
}

# --- single producer: the guarantee behind the writer's shape gate ------------

test_the_header_label_has_exactly_one_producer() {
  # bin/report-writer.sh checks the label's SHAPE; it cannot check provenance. The
  # provenance guarantee is that exactly one place in the tree BUILDS the string.
  # Search for the template that produces it (`Tax Year ${...}`), excluding tests,
  # docs and vendored code — a second producer anywhere in shipped code is the
  # regression this pins.
  local hits
  # shellcheck disable=SC2016  # single quotes are deliberate: `${` is the literal
  # template-substitution needle being searched for, not an expansion to perform.
  hits="$(grep -rlF 'Tax Year ${' "$REPO_ROOT/lib" "$REPO_ROOT/bin" "$REPO_ROOT/assets" \
            "$REPO_ROOT/skills" "$REPO_ROOT/agents" "$REPO_ROOT/commands" 2>/dev/null || true)"
  assert_eq "$REPO_ROOT/lib/tax/taxYear.mjs" "$hits" \
    "exactly one file builds the 'Tax Year …' label"
}

test_estimated_tax_tracker_shares_the_same_year_rule() {
  # The sibling consumer. It used to take its year straight off profile.taxYear, so
  # the tracker and the report could count different years from the same config.
  local h='Procedure'
  assert_section_contains "$TAX_SKILL" "$h" "resolveTaxYear" \
    "the tracker resolves its year through the shared rule"
  assert_section_contains "$TAX_SKILL" "$h" "not \`profile.taxYear\`" \
    "the tracker is told the stored profile year is not the active year"
}

run_tests
