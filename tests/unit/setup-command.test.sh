#!/usr/bin/env bash
#
# tests/unit/setup-command.test.sh — structural guards for the
# /workbench-ynab:setup slash command (commands/setup.md, issue #15).
#
# A slash command is agent-executed prose, not a unit-testable function, so this
# guards the invariants that are easy to break and that the issue flags as
# CRITICAL: the command must carry a frontmatter description, target the
# canonical out-of-repo config path, reference the tool-name SSoT instead of
# inlining concrete names, use the plugin-namespaced tool prefix (never the bare
# mcp__<key>__ form), and never pre-approve a write tool by hard-coding a
# concrete tool name (which the swap-ready guard, bin/check-tool-name-sources.sh,
# also forbids tree-wide).
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

# The command file exists and is a regular file.
test_command_file_exists() {
  assert_file_exists "$CMD"
}

# It carries YAML frontmatter with a description (the AC's first bullet).
test_has_frontmatter_description() {
  assert_eq "---" "$(head -n 1 "$CMD")" "first line is the frontmatter fence"
  grep -qE '^description:[[:space:]]*\S' "$CMD" \
    || fail "no non-empty 'description:' in the frontmatter"
}

# It targets the canonical, update-surviving config path (not an in-repo path).
test_targets_canonical_config_path() {
  assert_contains "$(cat "$CMD")" "workbench-ynab-claude-workbench/config.json" \
    "command writes the plugin-data config.json"
}

# It manages the Keychain entry under the documented service/account.
test_references_keychain_entry() {
  local body; body="$(cat "$CMD")"
  assert_contains "$body" 'find-generic-password -s "ynab-mcp" -a "access-token"' "check-first"
  assert_contains "$body" 'add-generic-password -s "ynab-mcp" -a "access-token"' "store with -U"
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

# It never uses the wrong bare mcp__ynab__ form (the CRITICAL warning in the AC).
# The correct prefix (…workbench-ynab_ynab__) does NOT contain this substring.
test_never_uses_bare_form() {
  if grep -qF 'mcp__ynab__' "$CMD"; then
    fail "command contains the non-resolving bare 'mcp__ynab__' form"
  fi
}

# It inlines no concrete tool name — same invariant the swap-ready guard
# enforces. Concrete names (…_ynab_<op>) must come from the SSoT at runtime, so
# no write-tool name can be hard-coded into a pre-approval here either. The bare
# prefix and the family glob (…_ynab_*) are exempt — they end in non-[a-z_].
test_no_inlined_concrete_tool_name() {
  if grep -qE 'mcp__plugin_workbench-ynab_ynab__ynab_[a-z_]+' "$CMD"; then
    fail "command inlines a concrete tool name — reference skills/protocol/ynab-tools.md instead"
  fi
}

run_tests
