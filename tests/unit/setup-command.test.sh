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

# --- Step 1a Node-floor gate: extract-and-RUN (issue #3, review round 2) -----
# Grepping the whole command file for needles is hollow — both strings also
# appear in comment prose, so the test stayed green with the executable gate
# deleted. Instead, mirror the extract_step4_block convention
# (tests/unit/setup-config-write.test.sh): pull Step 1a's fenced bash block out
# and actually execute it against a stubbed environment.

# Extract the first fenced bash block of Step 1 (the prereq check ending in the
# Node-floor gate).
extract_step1a_block() {
  awk '/^## Step 1 /{s=1; next} s && /^## /{exit}
       s && /^```bash$/{f=1; next} f && /^```$/{exit} f{print}' "$CMD"
}

# run_step1a <floor-gate-rc> — execute the extracted block with CLAUDE_PLUGIN_ROOT
# pointing at a sandbox whose bin/node-floor.sh stub exits <floor-gate-rc>
# (printing the real gate's actionable STDERR line when non-zero), and with
# stubbed node/jq/security first on PATH. Captures S1_OUT / S1_ERR / S1_RC.
run_step1a() {
  local gate_rc="$1" sb block
  sb="$(mktemp -d)"
  mkdir -p "$sb/root/bin" "$sb/root/vendor/ynab-mcp" "$sb/stubs"
  printf '18\n' > "$sb/root/vendor/ynab-mcp/NODE_VERSION"
  if [ "$gate_rc" -eq 0 ]; then
    printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/root/bin/node-floor.sh"
  else
    printf '#!/usr/bin/env bash\necho "ynab-mcp: workbench-ynab requires Node >= 18; you have v17.0.0 — upgrade via nvm" 1>&2\nexit 1\n' \
      > "$sb/root/bin/node-floor.sh"
  fi
  printf '#!/usr/bin/env bash\necho "v18.20.0"\n' > "$sb/stubs/node"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/stubs/jq"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/stubs/security"
  chmod +x "$sb/root/bin/node-floor.sh" "$sb/stubs/node" "$sb/stubs/jq" "$sb/stubs/security"
  block="$(extract_step1a_block)"
  set +e
  S1_OUT="$(CLAUDE_PLUGIN_ROOT="$sb/root" PATH="$sb/stubs:$PATH" \
    bash -c "$block" 2>"$sb/err")"
  S1_RC=$?
  set -e
  S1_ERR="$(cat "$sb/err")"
  rm -rf "$sb"
}

# The extraction finds the right block: it must carry the executable gate and
# the canonical-marker read (needles scoped to the BLOCK, not comment prose).
test_step1a_block_extracts() {
  local block; block="$(extract_step1a_block)"
  # The needles are literal command source text — never expanded here.
  # shellcheck disable=SC2016
  assert_contains "$block" 'if ! bash "${CLAUDE_PLUGIN_ROOT}/bin/node-floor.sh"' \
    "the extracted Step 1a block runs the shared Node-floor gate as a hard stop"
  # shellcheck disable=SC2016
  assert_contains "$block" 'vendor/ynab-mcp/NODE_VERSION' \
    "the extracted Step 1a block reads the canonical floor marker"
}

# AC 5 enforcement: with a below-floor node (gate stub exits 1) the block must
# hard-stop — non-zero exit, the actionable message on stderr, and the gate
# itself adding ZERO stdout bytes. (The prior on-PATH check legitimately echoes
# its ✅ line to stdout — setup's stdout is not a protocol channel — so assert
# the gate's own stdout-cleanliness, not whole-flow emptiness.) Deleting the
# version-check block from the command makes this exit 0 and the test fail.
test_step1a_gate_blocks_below_floor_node() {
  run_step1a 1
  assert_eq 1 "$S1_RC" "Step 1a must exit non-zero when the floor gate fails"
  assert_contains "$S1_ERR" "workbench-ynab requires Node >=" \
    "the gate's actionable message must reach stderr"
  assert_eq "✅ node, jq, security all present" "$S1_OUT" \
    "stdout must end at the on-PATH ✅ line — the failed gate adds no bytes"
}

# With the gate passing, the block completes and reports both ✅ lines.
test_step1a_gate_passes_at_floor() {
  run_step1a 0
  assert_eq 0 "$S1_RC" "Step 1a must exit 0 when the floor gate passes"
  assert_contains "$S1_OUT" "✅ node, jq, security all present" \
    "the on-PATH check reports success"
  assert_contains "$S1_OUT" "meets the Node >= 18 floor" \
    "the version check reports the floor met (marker value + node stub)"
  assert_eq "" "$S1_ERR" "no stderr on the happy path"
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

# CRITICAL invariant (issue #15, Step 5): pre-approval covers READ tools only —
# the write family-wildcard and every concrete write name are excluded. This is
# the human-facing half: the command must say reads-only and note that writes
# stay gated until Sprint 4. Deleting the Step 5 block makes this fail (the
# phrases vanish), closing the "delete it and the suite still passes" gap.
test_step5_documents_write_exclusion() {
  local body; body="$(cat "$CMD")"
  assert_contains "$body" "read tools only" "Step 5 scopes pre-approval to reads"
  assert_contains "$body" "Sprint 4" "Step 5 notes write tools stay gated until Sprint 4"
}

# CRITICAL invariant (issue #15, Step 5): the enforcement half. No write tool may
# ever be ADDED to permissions.allow — neither a concrete write name nor the
# write family-wildcard may appear on an allow-mutating line. The wildcard may be
# MENTIONED elsewhere to forbid it; it must never be approved. The approval loop
# must source the names it adds from the SSoT read-tool list (READ_TOOLS).
test_step5_never_approves_a_write_tool() {
  local allow_lines; allow_lines="$(grep -F 'permissions.allow' "$CMD" || true)"
  if printf '%s\n' "$allow_lines" | grep -qE 'mcp__plugin_workbench-ynab_ynab__ynab_[a-z_]+'; then
    fail "a permissions.allow line hard-codes a concrete tool name — reads come from the SSoT, writes are never pre-approved"
  fi
  if printf '%s\n' "$allow_lines" | grep -qF 'mcp__plugin_workbench-ynab_ynab__ynab_*'; then
    fail "the write family-wildcard appears on a permissions.allow line — it would sweep in ledger-mutating writes"
  fi
  assert_contains "$(cat "$CMD")" "READ_TOOLS" \
    "Step 5 approval loop sources the names it adds from the SSoT read-tool list"
}

# Pin the fixed Step 4 token-leak guard so its correct form can't silently
# regress (the two defects Holmes caught on PR #127):
#   1. the scan AGGREGATES every string test with `| any` — a bare per-string
#      `test(…)` makes `jq -e` reflect only the LAST value, silently missing a
#      token in any non-final position;
#   2. it scans the STAGED `.tmp` and drops it (`rm -f`) on a hit, so a
#      token-bearing config is never `mv`'d into the published path.
test_step4_token_guard_is_aggregate_and_pre_publish() {
  local body; body="$(cat "$CMD")"
  assert_contains "$body" 'strings | test("^[0-9a-f]{64}$")] | any' \
    "Step 4 guard aggregates the per-string tests with | any (the ] proves the array wrap)"
  # The needle is literal command source text — never expanded here.
  # shellcheck disable=SC2016
  assert_contains "$body" 'rm -f "$CONFIG_FILE.tmp"' \
    "Step 4 guard drops the staged .tmp on a hit, before any mv into place"
}

run_tests
