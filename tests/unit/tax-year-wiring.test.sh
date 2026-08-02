#!/usr/bin/env bash
#
# tests/unit/tax-year-wiring.test.sh — the active tax-year rule is actually WIRED
# into the review path, not just implemented in lib/tax (issue #17, AC #5 / #7).
#
# WHY THIS FILE EXISTS
#   lib/tax/taxYear.mjs and computeTaxSummary's boundary branch are covered by
#   tests/unit/tax-year.test.mjs and tests/unit/tax-engine.test.mjs. Those prove the
#   RULE. They cannot prove the rule is REACHED: the review path is an
#   LLM-executed markdown protocol (skills/review/ynab-review.md) driven by a
#   markdown planner (agents/ynab-orchestrator.md), so for that half the prose IS
#   the implementation. A first pass at this issue shipped a correct, well-tested
#   library that no document ever called — the January changeover would have thrown
#   on a real run, and the header label had no producer connected to it. This file
#   pins the connections so that regression cannot recur silently.
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

# --- the extractor itself, proven before anything relies on it ----------------

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
