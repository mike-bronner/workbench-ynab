#!/usr/bin/env bash
#
# tests/unit/setup-monitor-deploy.test.sh — structural guards for the
# ynab-monitor scheduled-task deployment step in /workbench-ynab:setup
# (commands/setup.md, issue #79 / M6-1 AC #11 + #12).
#
# Scheduled-task deployment is agent-driven MCP prose, not a unit-testable
# function, so — like tests/unit/setup-command.test.sh — this guards the
# invariants the AC pins and that are easy to regress:
#   * the setup command actually deploys the task (create) AND syncs it on a
#     re-run (update) — the idempotency the AC requires (#11);
#   * the task id is the distinct `ynab-monitor` (never the weekly `ynab-review`);
#   * cadence comes from config (schedules.monitor.cron), never a hardcoded cron;
#   * enabled:false removes/disables the task (#12);
#   * NO mutating scheduled-task call ever targets `ynab-review` (#12 safety);
#   * the deploy is gated on the Step 1b scheduled-tasks-MCP probe;
#   * the task prompt is sourced from the template, not inlined only.
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

# The command file exists (the deploy step has to live somewhere).
test_command_file_exists() {
  assert_file_exists "$CMD"
}

# AC #11 — deploys via create_scheduled_task AND syncs via update_scheduled_task
# (the two together are the idempotent create-or-sync path the AC requires).
test_deploys_and_syncs_idempotently() {
  local body; body="$(cat "$CMD")"
  assert_contains "$body" "mcp__scheduled-tasks__create_scheduled_task" \
    "setup deploys the task via create_scheduled_task"
  assert_contains "$body" "mcp__scheduled-tasks__update_scheduled_task" \
    "setup syncs an existing task via update_scheduled_task (idempotent re-run)"
}

# AC #11 — the deployed task id is the distinct monitor id.
test_uses_ynab_monitor_task_id() {
  assert_contains "$(cat "$CMD")" "ynab-monitor" \
    "setup deploys the ynab-monitor task id"
}

# AC #11 — cadence is config-driven: the cron is read from schedules.monitor.cron
# and passed as cronExpression, never hardcoded into the deploy call.
test_cron_is_config_driven() {
  local body; body="$(cat "$CMD")"
  assert_contains "$body" "schedules.monitor.cron" \
    "setup reads the cron from schedules.monitor.cron (config-driven)"
  assert_contains "$body" "cronExpression" \
    "setup passes the config cron as cronExpression"
}

# AC #12 — enabled:false removes or disables the task, keyed off the config flag.
test_enabled_false_removes_task() {
  local body; body="$(cat "$CMD")"
  assert_contains "$body" "schedules.monitor.enabled" \
    "setup branches on schedules.monitor.enabled"
  assert_contains "$body" "mcp__scheduled-tasks__delete_scheduled_task" \
    "setup removes the task via delete_scheduled_task when disabled"
}

# AC #12 EXECUTION — the disable gate doesn't just EXIST, it actually RESOLVES.
# The greps above prove the delete branch is present in prose; this extracts the
# REAL jq gate program from the command file and RUNS it against four configs.
# A `jq '… // true …'` gate silently coerces enabled:false → "true" (the `//`
# alternative operator falls through on false as well as null), leaving the
# delete branch permanently dead code — a regression no prose grep can see, and
# the exact bug this test exists to catch. It pipes each fixture through the
# extracted program (no temp files, no cleanup trap — a RETURN trap whose rm
# succeeds would reset $? and mask a real failure), so it stays coupled to
# whatever expression setup.md actually ships.
test_enabled_gate_resolves_false_when_disabled() {
  command -v jq >/dev/null 2>&1 || { printf '  (skipped: jq unavailable)\n'; return 0; }
  local gate_line prog
  gate_line="$(grep -E 'MON_ENABLED="\$\(jq' "$CMD" | head -1)"
  [ -n "$gate_line" ] || fail "no MON_ENABLED jq gate line found in $CMD"
  # Pull the jq program out from between `jq -r '` and its closing quote. The
  # program uses only double quotes internally, so [^']* captures all of it.
  prog="$(printf '%s\n' "$gate_line" | sed -E "s/.*jq -r '([^']*)'.*/\1/")"
  [ "$prog" != "$gate_line" ] || fail "could not extract the jq gate program from: $gate_line"

  local out
  # enabled:false MUST resolve to "false" so Step 7.4's delete branch is reachable.
  out="$(printf '{"schedules":{"monitor":{"enabled":false}}}' | jq -r "$prog")"
  assert_eq "false" "$out" "enabled:false must disable the monitor task"
  # enabled:true resolves to "true".
  out="$(printf '{"schedules":{"monitor":{"enabled":true}}}' | jq -r "$prog")"
  assert_eq "true" "$out" "enabled:true keeps the monitor enabled"
  # An empty monitor block defaults to enabled ("true").
  out="$(printf '{"schedules":{"monitor":{}}}' | jq -r "$prog")"
  assert_eq "true" "$out" "an empty monitor block defaults to enabled"
  # A wholly absent schedules block defaults to enabled ("true").
  out="$(printf '{}' | jq -r "$prog")"
  assert_eq "true" "$out" "an absent schedules block defaults to enabled"
}

# AC #12 SAFETY — the weekly-review task is never a target of a mutating
# scheduled-task call. Every create/update/delete line must carry ONLY the
# ynab-monitor id, never ynab-review.
test_never_mutates_ynab_review() {
  local mutating_lines
  mutating_lines="$(grep -E 'mcp__scheduled-tasks__(create|update|delete)_scheduled_task' "$CMD" || true)"
  [ -n "$mutating_lines" ] || fail "no scheduled-task mutating call found — the deploy step is missing"
  if printf '%s\n' "$mutating_lines" | grep -q 'ynab-review'; then
    fail "a scheduled-task mutating call targets ynab-review — the weekly review must be untouched"
  fi
}

# The deploy step is gated on the Step 1b scheduled-tasks-MCP probe, so an
# unreachable MCP skips it instead of erroring.
test_deploy_is_gated_on_probe() {
  assert_contains "$(cat "$CMD")" "SCHEDULING_AVAILABLE" \
    "the deploy step gates on the Step 1b SCHEDULING_AVAILABLE probe result"
}

# The task prompt is sourced from the shipped template (a prompt edit is a
# one-file change), not only inlined into the command.
test_prompt_sourced_from_template() {
  assert_contains "$(cat "$CMD")" "assets/prompt-templates/ynab-monitor.prompt.md" \
    "the deploy step resolves the task prompt from the ynab-monitor template"
}

run_tests
