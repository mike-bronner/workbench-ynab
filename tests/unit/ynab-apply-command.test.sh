#!/usr/bin/env bash
#
# tests/unit/ynab-apply-command.test.sh — structural guards for the
# /workbench-ynab:ynab-apply slash command (commands/ynab-apply.md, issue #59).
#
# A slash command is agent-executed prose, not a unit-testable function, so this
# guards the invariants the issue's acceptance criteria flag as load-bearing: the
# command carries a frontmatter description; loads the pending change-set from the
# canonical plugin-data proposal path (and exits cleanly when none exists); is
# idempotent against the M4-3 audit log; groups ops into typed batches; dry-runs
# each batch through the M4-4 executor before asking anything; runs the
# three-options decision protocol via AskUserQuestion; flags destructive ops and
# excludes stale ops from the apply-as-is option; gates every apply behind the
# M4-2 guardrail; performs the only dry_run=false write in the plugin; documents
# the config-split contract; uses the plugin-namespaced tool prefix (never the
# bare mcp__<key>__ form); and inlines no concrete tool name (which the swap-ready
# guard, bin/check-tool-name-sources.sh, also forbids tree-wide).
#
# Follows the repo harness convention (issue #4, tests/lib/assert.sh): raw bash
# with `set -euo pipefail`, sources tests/lib/assert.sh, defines `test_*`
# functions, ends with `run_tests`. scripts/test.sh auto-discovers it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"

CMD="$REPO_ROOT/commands/ynab-apply.md"

# The command file exists at the path the AC pins.
test_command_file_exists() {
  assert_file_exists "$CMD"
}

# It carries YAML frontmatter with a non-empty description (AC bullet 1).
test_has_frontmatter_description() {
  assert_eq "---" "$(head -n 1 "$CMD")" "first line is the frontmatter fence"
  grep -qE '^description:[[:space:]]*\S' "$CMD" \
    || fail "no non-empty 'description:' in the frontmatter"
}

# Step 1 — loads the pending change-set from the canonical plugin-data proposal
# path and exits cleanly when none exists.
test_loads_proposal_from_plugin_data() {
  local body; body="$(cat "$CMD")"
  assert_contains "$body" "workbench-ynab-claude-workbench/proposals" \
    "Step 1 reads the proposal from the plugin-data proposals dir"
  assert_contains "$body" "No pending proposal" \
    "Step 1 exits cleanly with a no-pending-proposal message"
}

# Config-split contract: reads plugin config from the canonical out-of-repo path.
test_targets_canonical_config_path() {
  assert_contains "$(cat "$CMD")" "workbench-ynab-claude-workbench/config.json" \
    "command reads the plugin-data config.json"
}

# It reads config through the sourced loader, not ad-hoc jq plumbing.
test_uses_config_loader() {
  assert_contains "$(cat "$CMD")" 'bin/config.sh' \
    "command sources the config loader"
}

# Step 1b — idempotency guard cross-references the M4-3 audit log.
test_idempotency_via_audit_log() {
  local body; body="$(cat "$CMD")"
  assert_contains "$body" 'bin/audit-log.sh' "idempotency reads the audit log"
  assert_contains "$body" "already applied" "skipped-as-already-applied summary is shown"
}

# Step 2 — groups into typed batches (the four ledger-only op types named,
# including the destructive delete_duplicate / dedupe — the safety-relevant one).
test_groups_into_typed_batches() {
  local body; body="$(cat "$CMD")"
  assert_contains "$body" "categorize" "names the categorize batch"
  assert_contains "$body" "allocate" "names the allocate batch"
  assert_contains "$body" "delete_duplicate" "names the dedupe (delete_duplicate) batch — the destructive op type"
  assert_contains "$body" "reconcile" "names the reconcile batch"
  assert_contains "$body" "one batch at a time" "presents batches one at a time, not a flat list"
}

# Step 3 — dry-runs each batch through the executor before asking anything, and
# divides milliunits by 1000 for display.
test_dry_run_diff_per_batch() {
  local body; body="$(cat "$CMD")"
  assert_contains "$body" "dryRun: true" "executor runs dry-run before any prompt"
  assert_contains "$body" "1000" "milliunits are divided by 1000 for display"
  assert_contains "$body" "rationale" "diff shows the per-op rationale"
}

# Step 3b — destructive ops are flagged and require a stronger confirmation.
test_destructive_flag_and_stronger_confirmation() {
  local body; body="$(cat "$CMD")"
  assert_contains "$body" "destructive" "destructive ops are called out"
  assert_contains "$body" "Confirm delete" "destructive ops get a stronger confirmation gate"
}

# Step 4 — three-options decision protocol via AskUserQuestion, with the three
# canonical options present.
test_three_options_decision_protocol() {
  local body; body="$(cat "$CMD")"
  assert_contains "$body" "AskUserQuestion" "uses AskUserQuestion for the per-batch choice"
  assert_contains "$body" "Apply the whole batch as-is" "option (a) present"
  assert_contains "$body" "Apply a subset" "option (b) present"
  assert_contains "$body" "Reject the batch" "option (c) present"
}

# Step 4b — stale ops are excluded from option (a) by default.
test_stale_ops_excluded_from_apply_as_is() {
  local body; body="$(cat "$CMD")"
  assert_contains "$body" "stale" "stale ops are surfaced"
  assert_contains "$body" "excluded from option (a)" "stale ops are excluded from apply-as-is by default"
}

# Step 5 — applies the approved ops with the executor's only dry_run=false call,
# then reads the audit-log summary back. The "only dry_run=false call" and the
# audit-log readback are pinned to load-bearing phrases (a bare "only" is
# tautological — the word appears in many unrelated contexts).
test_apply_is_the_only_dry_run_false_call() {
  local body; body="$(cat "$CMD")"
  assert_contains "$body" "dryRun: false" "the apply step sets dry_run=false"
  assert_contains "$body" "the only \`dry_run=false\` call" \
    "the apply step is pinned as the only dry_run=false call in the plugin"
  assert_contains "$body" "approved ops only" "applies only the approved ops, not the whole proposal"
  assert_contains "$body" 'audit-log.sh" last' \
    "Step 5 reads the audit-log summary back via 'audit-log.sh last' after applying"
}

# Step 4.0 — guardrail gate runs before any apply (and before the choice) and
# surfaces blocked ops.
test_guardrail_gate_before_apply() {
  local body; body="$(cat "$CMD")"
  assert_contains "$body" "evaluateChangeset" "runs the M4-2 guardrail over the batch"
  assert_contains "$body" "never calls the executor with \`dry_run=false\` past a guardrail block" \
    "never applies past a guardrail block"
}

# Config-split contract is explicitly documented in the body. The MCP-never-reads
# invariant is pinned to its load-bearing phrase (a bare "never" is tautological —
# the word appears ~20× in unrelated contexts).
test_documents_config_split() {
  local body; body="$(cat "$CMD")"
  assert_contains "$body" "Config split" "config-split contract is documented"
  assert_contains "$body" "never reads \`config.json\`" \
    "the config-split contract pins that the vendored MCP never reads config.json"
}

# It sources tool names from the SSoT rather than inlining them.
test_references_tool_ssot() {
  assert_contains "$(cat "$CMD")" "skills/protocol/ynab-tools.md" \
    "command points at the tool-name single source of truth"
}

# It uses the correct plugin-namespaced prefix.
test_uses_namespaced_prefix() {
  assert_contains "$(cat "$CMD")" "mcp__plugin_workbench-ynab_ynab__" \
    "command uses the plugin-namespaced tool prefix"
}

# It never uses the wrong bare mcp__ynab__ form. The correct prefix
# (…workbench-ynab_ynab__) does NOT contain this substring.
test_never_uses_bare_form() {
  if grep -qF 'mcp__ynab__' "$CMD"; then
    fail "command contains the non-resolving bare 'mcp__ynab__' form"
  fi
}

# It inlines no concrete tool name — same invariant the swap-ready guard enforces.
# The bare prefix and the family glob (…_ynab_*) are exempt — they end in non-[a-z_].
test_no_inlined_concrete_tool_name() {
  if grep -qE 'mcp__plugin_workbench-ynab_ynab__ynab_[a-z_]+' "$CMD"; then
    fail "command inlines a concrete tool name — reference skills/protocol/ynab-tools.md instead"
  fi
}

# Numbered-step structure mirrors commands/setup.md. Pinned to the real count —
# the command has six top-level '## Step' sections (1, 1b, 2, 3, 4, 5; the
# guardrail gate is a 4.0 sub-step). A loose '>= 4' would let a third of the steps
# vanish undetected.
test_structure_mirrors_setup() {
  local steps; steps="$(grep -cE '^## Step ' "$CMD")"
  if [ "$steps" -lt 6 ]; then
    fail "expected the numbered-step structure of setup.md (>=6 '## Step' sections: 1, 1b, 2, 3, 4, 5), found $steps"
  fi
}

run_tests
