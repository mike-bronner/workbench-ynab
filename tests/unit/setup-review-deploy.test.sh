#!/usr/bin/env bash
#
# tests/unit/setup-review-deploy.test.sh — structural + executable guards for
# the unified `ynab-review` scheduled-task deployment step in
# /workbench-ynab:setup (commands/setup.md Step 8) and its prompt template
# (assets/prompt-templates/ynab-review.prompt.md), issue #38 / M2-11.
#
# Scheduled-task deployment is agent-driven MCP prose, not a unit-testable
# function, so — like tests/unit/setup-monitor-deploy.test.sh — this guards the
# invariants the AC pins and that are easy to regress:
#   * the prompt template exists, invokes /workbench-ynab:ynab-review, pauses
#     (never fabricates / auto-completes) when no user is present, and clarifies
#     the router handles all tiers WITHOUT listing per-tier commands (AC #1–#3);
#   * config.schema.json carries a schedules.review block with cron default
#     "0 7 * * 1" and enabled default true (AC #4);
#   * the deploy reads schedules.review.cron and passes it as cronExpression —
#     no hardcoded cron (AC #5);
#   * the deploy uses the distinct `ynab-review` task id, creates AND syncs it
#     idempotently (AC #10/#11/#15);
#   * enabled:false removes/disables the task — proven by RUNNING the extracted
#     jq gate, not just grepping for it (AC #6);
#   * each of the three prerequisite gates blocks deployment when unmet — the
#     config-absent gate is proven by RUNNING it; the two MCP-reachability gates
#     are prose-guarded by their halt messages (AC #7/#8/#9/#14);
#   * the confirmation states "ONE task deployed … routes all tiers" (AC #12);
#   * the summary carries the re-sync-after-update guidance (AC #13);
#   * the review step never mutates the monitor task (symmetric #12 safety).
#
# Follows the repo harness convention (issue #4, tests/lib/assert.sh): raw bash
# with `set -euo pipefail`, sources tests/lib/assert.sh, defines `test_*`
# functions, ends with `run_tests`. scripts/test.sh auto-discovers it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"

CMD="$REPO_ROOT/commands/setup.md"
PROMPT="$REPO_ROOT/assets/prompt-templates/ynab-review.prompt.md"
SCHEMA="$REPO_ROOT/assets/config.schema.json"

# Extract the Step 8 section (its heading through the next `## Step` heading) so
# the deploy-step assertions never leak into Step 7 (monitor) or Step 9 (summary).
step8() { awk '/^## Step 8 /{f=1} f&&/^## Step 9 /{exit} f' "$CMD"; }

# ── Prompt template (AC #1–#3) ──────────────────────────────────────────────

test_prompt_template_exists() {
  assert_file_exists "$PROMPT"
}

# AC #1 — the template instructs the agent to invoke the unified router.
test_prompt_invokes_ynab_review() {
  assert_contains "$(cat "$PROMPT")" "/workbench-ynab:ynab-review" \
    "the prompt template invokes /workbench-ynab:ynab-review"
}

# AC #2 — pause at the first interactive prompt when no user is present; never
# fabricate, never auto-complete.
test_prompt_pauses_and_never_fabricates() {
  local body; body="$(cat "$PROMPT")"
  assert_contains "$body" "pause" "the prompt tells the agent to pause when no user is present"
  assert_contains "$body" "fabricate" "the prompt forbids fabricating responses"
  assert_contains "$body" "auto-complete" "the prompt forbids auto-completing the review"
}

# AC #3 — clarify the router routes ALL tiers; it must NOT list per-tier slash
# commands (those exist for manual single-tier runs only).
test_prompt_routes_all_tiers_no_per_tier_commands() {
  local body; body="$(cat "$PROMPT")"
  for tier in weekly monthly quarterly-tax annual; do
    assert_contains "$body" "$tier" "the prompt names the $tier tier the router covers"
  done
  # A per-tier command name in the template would contradict AC #3.
  for cmd in ynab-weekly-review ynab-monthly-review ynab-quarterly-tax-review ynab-annual-review; do
    if grep -qF "$cmd" "$PROMPT"; then
      fail "the prompt lists the per-tier command $cmd — AC #3 forbids per-tier commands"
    fi
  done
}

# ── Config schema (AC #4) ───────────────────────────────────────────────────

# AC #4 — schedules.review carries cron (string, default "0 7 * * 1") and
# enabled (boolean, default true). Parse the real schema so a default/type
# regression is caught, not just the key's presence.
test_schema_has_review_block_with_defaults() {
  command -v jq >/dev/null 2>&1 || { printf '  (skipped: jq unavailable)\n'; return 0; }
  local base='.properties.schedules.properties.review.properties'
  assert_eq "string"    "$(jq -r "$base.cron.type"       "$SCHEMA")" "schedules.review.cron is a string"
  assert_eq "0 7 * * 1" "$(jq -r "$base.cron.default"    "$SCHEMA")" "schedules.review.cron defaults to \"0 7 * * 1\""
  assert_eq "boolean"   "$(jq -r "$base.enabled.type"    "$SCHEMA")" "schedules.review.enabled is a boolean"
  assert_eq "true"      "$(jq -r "$base.enabled.default" "$SCHEMA")" "schedules.review.enabled defaults to true"
}

# ── Deploy step (AC #5, #10, #11, #15) ──────────────────────────────────────

# AC #10/#11/#15 — deploys via create_scheduled_task AND syncs via
# update_scheduled_task (together the idempotent create-or-sync path).
test_deploys_and_syncs_idempotently() {
  local body; body="$(step8)"
  assert_contains "$body" "mcp__scheduled-tasks__create_scheduled_task" \
    "the review step deploys via create_scheduled_task"
  assert_contains "$body" "mcp__scheduled-tasks__update_scheduled_task" \
    "the review step syncs an existing task via update_scheduled_task (idempotent re-run)"
}

# AC #10 — the deployed task id is the distinct ynab-review id.
test_uses_ynab_review_task_id() {
  assert_contains "$(step8)" "ynab-review" "the review step deploys the ynab-review task id"
}

# AC #5 — cadence is config-driven: cron read from schedules.review.cron and
# passed as cronExpression, never hardcoded into the deploy call.
test_cron_is_config_driven() {
  local body; body="$(step8)"
  assert_contains "$body" "schedules.review.cron" \
    "the review step reads the cron from schedules.review.cron (config-driven)"
  assert_contains "$body" "cronExpression" \
    "the review step passes the config cron as cronExpression"
}

# AC #10 — the task prompt is sourced from the shipped template, not only inlined.
test_prompt_sourced_from_template() {
  assert_contains "$(step8)" "assets/prompt-templates/ynab-review.prompt.md" \
    "the review step resolves the task prompt from the ynab-review template"
}

# ── Enabled gate (AC #6) — RUN the extracted jq program ──────────────────────

# AC #6 EXECUTION — the disable gate doesn't just EXIST, it RESOLVES. Extract
# the REAL jq gate program from setup.md and run it against four configs. A
# `jq '… // true …'` gate silently coerces enabled:false → "true" (the `//`
# alternative operator falls through on false as well as null), leaving the
# delete branch permanently dead code — the exact bug this test catches.
test_enabled_gate_resolves_false_when_disabled() {
  command -v jq >/dev/null 2>&1 || { printf '  (skipped: jq unavailable)\n'; return 0; }
  local gate_line prog
  gate_line="$(grep -E 'REV_ENABLED="\$\(jq' "$CMD" | head -1)"
  [ -n "$gate_line" ] || fail "no REV_ENABLED jq gate line found in $CMD"
  prog="$(printf '%s\n' "$gate_line" | sed -E "s/.*jq -r '([^']*)'.*/\1/")"
  [ "$prog" != "$gate_line" ] || fail "could not extract the jq gate program from: $gate_line"

  local out
  out="$(printf '{"schedules":{"review":{"enabled":false}}}' | jq -r "$prog")"
  assert_eq "false" "$out" "enabled:false must disable the review task"
  out="$(printf '{"schedules":{"review":{"enabled":true}}}' | jq -r "$prog")"
  assert_eq "true" "$out" "enabled:true keeps the review enabled"
  out="$(printf '{"schedules":{"review":{}}}' | jq -r "$prog")"
  assert_eq "true" "$out" "an empty review block defaults to enabled"
  out="$(printf '{}' | jq -r "$prog")"
  assert_eq "true" "$out" "an absent schedules block defaults to enabled"
}

# AC #6 — enabled:false removes/disables the task, keyed off the config flag.
test_enabled_false_removes_task() {
  local body; body="$(step8)"
  assert_contains "$body" "schedules.review.enabled" \
    "the review step branches on schedules.review.enabled"
  assert_contains "$body" "mcp__scheduled-tasks__delete_scheduled_task" \
    "the review step removes the task via delete_scheduled_task when disabled"
}

# ── Prerequisite gates (AC #7/#8/#9/#14) ────────────────────────────────────

# AC #7/#8 — the two MCP-reachability gates block deployment when unmet. They
# are agent-driven MCP calls (not shell-executable), so guard their halt
# messages: removing a gate drops its distinct ❌ message and fails this test.
test_mcp_reachability_gates_halt() {
  local body; body="$(step8)"
  assert_contains "$body" "mcp__scheduled-tasks__list_scheduled_tasks" \
    "AC #7 — the review step probes the scheduled-tasks MCP via list_scheduled_tasks"
  assert_contains "$body" "scheduled-tasks MCP not reachable" \
    "AC #7 — an unreachable scheduled-tasks MCP halts with a clear error"
  assert_contains "$body" "YNAB MCP not reachable" \
    "AC #8 — an unreachable YNAB MCP halts with a clear error"
}

# AC #9/#14 EXECUTION — the config-absent gate BLOCKS deployment. Extract the
# real gate line and run it: a missing config must exit non-zero, a present one
# must pass. Proven by execution, not a prose grep.
test_config_absent_gate_blocks() {
  local gate
  gate="$(grep -E '\[ -f "\$CONFIG_FILE" \].*cannot deploy' "$CMD" | head -1)"
  [ -n "$gate" ] || fail "no config-present gate found in the review step of $CMD"

  local rc=0
  ( CONFIG_FILE="/nonexistent/watson-review-$$.json"; eval "$gate" ) >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "config-absent gate must block deployment (exit 1) when config is missing"

  local tmp; tmp="$(mktemp)"
  rc=0
  ( CONFIG_FILE="$tmp"; eval "$gate" ) >/dev/null 2>&1 || rc=$?
  rm -f "$tmp"
  assert_eq "0" "$rc" "config-present gate must pass (exit 0) when config exists"
}

# ── Confirmation + guidance (AC #12/#13) ────────────────────────────────────

# AC #12 — the confirmation explicitly states ONE task routes all tiers.
test_confirmation_states_one_task_all_tiers() {
  local body; body="$(cat "$CMD")"
  assert_contains "$body" "ONE task deployed" \
    "the confirmation states ONE task deployed (not four)"
  assert_contains "$body" "routes all tiers" \
    "the confirmation states the one task routes all tiers"
}

# AC #13 — the summary instructs re-running setup after a plugin update to
# re-sync the scheduled-task prompt.
test_resync_guidance_in_summary() {
  assert_contains "$(cat "$CMD")" "re-sync the" \
    "the summary instructs re-syncing the scheduled-task prompt after a plugin update"
}

# ── Symmetric safety (#12) ──────────────────────────────────────────────────

# The review step confines every mutating scheduled-task call to ynab-review and
# never touches ynab-monitor (the mirror of the monitor step's guard).
test_never_mutates_ynab_monitor() {
  local body mutating_lines
  body="$(step8)"
  mutating_lines="$(printf '%s\n' "$body" | grep -E 'mcp__scheduled-tasks__(create|update|delete)_scheduled_task' || true)"
  [ -n "$mutating_lines" ] || fail "no scheduled-task mutating call found in the review step — the deploy step is missing"
  if printf '%s\n' "$mutating_lines" | grep -q 'ynab-monitor'; then
    fail "the review step targets ynab-monitor in a mutating call — the monitor task must be untouched"
  fi
}

run_tests
