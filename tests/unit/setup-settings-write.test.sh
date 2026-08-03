#!/usr/bin/env bash
#
# tests/unit/setup-settings-write.test.sh — behavioral guards for the Step 5
# settings.json pre-approval block in /workbench-ynab:setup (commands/setup.md,
# issue #280).
#
# Step 5 used to stage `$SETTINGS.tmp` under the ambient umask and `mv` it over
# the real file. `mv` on one filesystem is a rename(2): the destination inode is
# replaced outright, so the published file's mode is the STAGED file's mode. A
# settings.json a user had hardened to 0600 came back at the umask default
# (commonly 0644, world-readable) the first time a pre-approval was added — and
# Claude Code's settings.json can carry `env`, `hooks`, and `mcpServers` blocks
# that in practice hold inline secrets.
#
# These tests EXTRACT the real Step 5 block from setup.md and EXECUTE it in a
# sandbox (the setup-config-write.test.sh extract-and-run convention), so they
# stay coupled to whatever code the command actually ships:
#   * a pre-existing 0600 settings.json is still 0600 after the rewrite;
#   * a pre-existing 0644 settings.json is still 0644 — the mode is PRESERVED,
#     not replaced by an opinion of ours (settings.json is Claude Code's own
#     shared config, outside SECURITY.md's plugin-owned artifact inventory);
#   * a settings.json the command CREATES is owner-only, never world-readable
#     at the ambient umask;
#   * the staged .tmp is owner-only AT CREATION (proved by neutralizing the
#     mode-restoring chmod, so only the `umask 077` staging subshell is left);
#   * every failure path fails CLOSED — the .tmp is dropped, the real file is
#     byte-for-byte untouched, and the ✅ line is never printed.
#
# Every case runs under `umask 022`, which is what makes the mode assertions
# discriminating: an unhardened block would stage the .tmp at 0644 and publish
# that mode over whatever the user chose.
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

# The bare, guard-safe plugin prefix (bin/check-tool-name-sources.sh forbids a
# concrete tool name in this file). The two fixture "tools" below are built from
# it, so they are prefix-shaped without naming a real tool.
PREFIX="mcp__plugin_workbench-ynab_ynab__"
TOOL_A="${PREFIX}alpha_read"
TOOL_B="${PREFIX}beta_read"

REAL_JQ="$(command -v jq)"

# Portable octal-perms read: GNU `stat -c '%a'` probed FIRST (on GNU, `stat -f`
# is "filesystem status" and misreads `%Lp`), BSD/macOS `stat -f '%Lp'` as the
# fallback. Same helper the report-writer / audit-log / setup-config-write
# suites use for mode-bit assertions.
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# Print the first ```bash fenced block whose body contains <needle> — the same
# needle-scoped extraction setup-command.test.sh uses. Deleting or restructuring
# the block empties the output, which reddens test_step5_block_extracts below.
extract_block_containing() {
  local needle="$1"
  awk -v needle="$needle" '
    /^[[:space:]]*```bash[[:space:]]*$/ { inb=1; buf=""; next }
    inb && /^[[:space:]]*```[[:space:]]*$/ { inb=0; if (index(buf, needle)) printf "%s", buf; next }
    inb { buf = buf $0 "\n" }
  ' "$CMD"
}

# The needle is literal command source text — never expanded here.
# shellcheck disable=SC2016
STEP5_NEEDLE='SETTINGS="$HOME/.claude/settings.json"'

extract_step5_block() { extract_block_containing "$STEP5_NEEDLE"; }

# run_step5 [block] — build a sandbox HOME, execute the Step 5 block under
# `umask 022` with a two-entry $READ_TOOLS, and capture:
#   S5_HOME / S5_SETTINGS — the sandbox and the settings path
#   S5_OUT / S5_RC        — combined output and exit code
#   S5_TMP_LEFT           — 1 if a stale $SETTINGS.tmp was left behind
# Shape the sandbox (pre-existing file, its mode, PATH stubs) BEFORE calling.
# The optional <block> replaces the extracted one, for mutation tests.
run_step5() {
  local block="${1:-$(extract_step5_block)}" rc=0
  S5_OUT="$( umask 022; env HOME="$S5_HOME" PATH="$S5_BIN:$PATH" \
    READ_TOOLS="$TOOL_A
$TOOL_B" "${BASH:-/bin/bash}" -c "$block" 2>&1 )" || rc=$?
  S5_RC="$rc"
  S5_TMP_LEFT=0
  [ -e "$S5_SETTINGS.tmp" ] && S5_TMP_LEFT=1
  return 0
}

# new_sandbox — a fresh HOME with .claude/ present but NO settings.json, plus an
# empty PATH-shim dir. Sets S5_HOME / S5_BIN / S5_SETTINGS.
new_sandbox() {
  S5_HOME="$(mktemp -d)"
  mkdir -p "$S5_HOME/.claude" "$S5_HOME/bin"
  S5_BIN="$S5_HOME/bin"
  S5_SETTINGS="$S5_HOME/.claude/settings.json"
}

# A settings.json shaped like a real one: an unrelated top-level key, an
# unrelated permission, and a sibling plugin's entry — none of which the
# pre-approval may disturb.
write_settings() {
  cat > "$1" <<'EOF'
{
  "model": "opus",
  "permissions": {
    "allow": [
      "Bash(git status:*)",
      "mcp__plugin_workbench-bujo_scribe__bujo_read"
    ]
  }
}
EOF
}

# The extraction still finds the right block (and it is the settings block, not
# the SSoT-read block earlier in Step 5).
test_step5_block_extracts() {
  local block; block="$(extract_step5_block)"
  [ -n "$block" ] || fail "could not extract the Step 5 settings-write block"
  # The needles are literal command source text — never expanded here.
  # shellcheck disable=SC2016
  assert_contains "$block" 'mv "$SETTINGS.tmp" "$SETTINGS"' \
    "the extracted block contains the publish mv"
  assert_contains "$block" 'permissions.allow' \
    "the extracted block contains the permissions.allow rewrite"
}

# The happy path still works: both SSoT read tools land, and the unrelated keys
# and sibling-plugin entry survive.
test_pre_approval_adds_the_read_tools_and_disturbs_nothing() {
  new_sandbox
  write_settings "$S5_SETTINGS"
  run_step5
  assert_eq "0" "$S5_RC" "the pre-approval block exits zero on the happy path: $S5_OUT"
  assert_contains "$S5_OUT" "✅" "the success line is printed"
  assert_json_valid "$S5_SETTINGS"
  local allow; allow="$(jq -r '.permissions.allow[]' "$S5_SETTINGS")"
  assert_exact_line "$allow" "$TOOL_A" "the first read tool is pre-approved"
  assert_exact_line "$allow" "$TOOL_B" "the second read tool is pre-approved"
  assert_exact_line "$allow" "Bash(git status:*)" "an unrelated permission survives"
  assert_exact_line "$allow" "mcp__plugin_workbench-bujo_scribe__bujo_read" \
    "a sibling plugin's entry survives"
  assert_eq "opus" "$(jq -r '.model' "$S5_SETTINGS")" "an unrelated top-level key survives"
  assert_eq "0" "$S5_TMP_LEFT" "no stale settings.json.tmp is left behind"
  rm -rf "$S5_HOME"
}

# Re-running is still idempotent — no duplicate entries (the `index($p)` guard).
test_pre_approval_is_idempotent() {
  new_sandbox
  write_settings "$S5_SETTINGS"
  run_step5
  run_step5
  assert_eq "1" "$(jq --arg p "$TOOL_A" '[.permissions.allow[] | select(. == $p)] | length' "$S5_SETTINGS")" \
    "a re-run does not duplicate an already-approved tool"
  rm -rf "$S5_HOME"
}

# Issue #280 core: a settings.json the user hardened to 0600 must STILL be 0600
# after the rewrite. Under the ambient `umask 022` an unhardened `jq > tmp; mv`
# publishes 0644 here — the exact regression this test exists to catch.
test_hardened_mode_survives_the_rewrite() {
  new_sandbox
  write_settings "$S5_SETTINGS"
  chmod 600 "$S5_SETTINGS"
  assert_eq "600" "$(mode_of "$S5_SETTINGS")" "the fixture starts owner-only (0600)"
  run_step5
  assert_eq "0" "$S5_RC" "the rewrite succeeds over a 0600 settings.json: $S5_OUT"
  assert_eq "600" "$(mode_of "$S5_SETTINGS")" \
    "a settings.json hardened to 0600 is still 0600 after the pre-approval rewrite"
  rm -rf "$S5_HOME"
}

# The mode is PRESERVED, not replaced by an opinion of ours: a settings.json the
# user left at 0644 stays 0644. This is the assertion the mode-restoring `chmod`
# owns — drop it and the `umask 077` staging subshell publishes 0600 instead,
# reddening this test while the 0600 case above stays green. The pair
# discriminates the two hardening layers from each other.
test_loose_mode_is_preserved_not_overridden() {
  new_sandbox
  write_settings "$S5_SETTINGS"
  chmod 644 "$S5_SETTINGS"
  assert_eq "644" "$(mode_of "$S5_SETTINGS")" "the fixture starts loose (0644)"
  run_step5
  assert_eq "0" "$S5_RC" "the rewrite succeeds over a 0644 settings.json: $S5_OUT"
  assert_eq "644" "$(mode_of "$S5_SETTINGS")" \
    "the user's chosen 0644 is preserved — the plugin does not re-mode a file it does not own"
  rm -rf "$S5_HOME"
}

# A settings.json the command CREATES is its own to mode, and it is born
# owner-only — never left world-readable by the ambient umask. Without the
# `( umask 077; … )` creation subshell the file is 0644 under `umask 022` here.
test_freshly_created_settings_is_not_world_readable() {
  new_sandbox
  [ ! -e "$S5_SETTINGS" ] || fail "the sandbox must start with no settings.json"
  run_step5
  assert_eq "0" "$S5_RC" "the rewrite succeeds with no pre-existing settings.json: $S5_OUT"
  assert_file_exists "$S5_SETTINGS"
  assert_eq "600" "$(mode_of "$S5_SETTINGS")" \
    "a settings.json created by setup is owner-only, not the ambient umask default"
  assert_exact_line "$(jq -r '.permissions.allow[]' "$S5_SETTINGS")" "$TOOL_A" \
    "the pre-approval still lands in the freshly created file"
  rm -rf "$S5_HOME"
}

# The staged .tmp is owner-only AT CREATION, not by a later chmod — so the
# pending rewrite never sits world-readable beside the real file.
#
# The end-state tests above cannot tell WHICH layer set the mode: a bare `>`
# redirect plus the mode-restoring chmod produces the same end state while
# leaving exactly that window open. So neutralize the chmod (rewrite it to a `:`
# no-op, keeping the surrounding fail-closed `if` intact) over a 0644 original
# under `umask 022`. If the jq `>` were staging at the ambient umask the
# published file would be 0644; only the `( umask 077; … )` subshell can make it
# 0600.
#
# This is the standing mutation test for the creation-time guarantee: deleting
# `umask 077` from the staging subshell reddens THIS test while every other test
# in this file stays green (the chmod still covers them).
test_staged_tmp_is_owner_only_at_creation() {
  local block
  # The sed script and the case pattern are LITERAL command source text to match
  # — the `$SETTINGS_MODE` in each is the command's own shell, never an
  # expansion here — so SC2016 is a false positive on both.
  # shellcheck disable=SC2016
  block="$(extract_step5_block | sed 's/chmod "$SETTINGS_MODE" /: /')"
  # The sed must actually have found its target — otherwise this test silently
  # degrades into a duplicate of the one above and proves nothing.
  # shellcheck disable=SC2016
  case "$block" in
    *'chmod "$SETTINGS_MODE" '*) fail "the chmod-neutralizing sed did not fire — test would be vacuous" ;;
  esac
  new_sandbox
  write_settings "$S5_SETTINGS"
  chmod 644 "$S5_SETTINGS"
  run_step5 "$block"
  assert_eq "0" "$S5_RC" "the block still succeeds with the chmod neutralized: $S5_OUT"
  assert_eq "600" "$(mode_of "$S5_SETTINGS")" \
    "the staged .tmp was born 0600 — the umask 077 subshell, not the chmod"
  rm -rf "$S5_HOME"
}

# Fail closed when the mode cannot be READ: publishing the rewrite would reset
# the mode to the ambient umask, so the step refuses instead. `stat` is stubbed
# to fail both ways, which is the only way to reach that branch.
test_unreadable_mode_fails_closed() {
  new_sandbox
  write_settings "$S5_SETTINGS"
  chmod 600 "$S5_SETTINGS"
  cp "$S5_SETTINGS" "$S5_HOME/before"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$S5_BIN/stat"
  chmod +x "$S5_BIN/stat"
  run_step5
  assert_contains "$S5_OUT" "Could not read the permission mode" \
    "the unreadable mode is reported"
  case "$S5_OUT" in *"✅"*) fail "a refused pre-approval must not print the success line" ;; esac
  cmp -s "$S5_SETTINGS" "$S5_HOME/before" \
    || fail "settings.json was modified despite an unreadable mode — it must be left untouched"
  assert_eq "600" "$(mode_of "$S5_SETTINGS")" "the original mode is left alone"
  assert_eq "0" "$S5_TMP_LEFT" "no stale settings.json.tmp is left behind"
  rm -rf "$S5_HOME"
}

# Fail closed when the jq rewrite itself fails: the truncated .tmp is dropped,
# the real file is byte-for-byte untouched, and the ✅ is withheld. The stub
# passes `stat` through (the mode read must still succeed) and fails only the
# rewrite, so this exercises the rewrite gate alone.
test_failed_rewrite_fails_closed() {
  new_sandbox
  write_settings "$S5_SETTINGS"
  chmod 600 "$S5_SETTINGS"
  cp "$S5_SETTINGS" "$S5_HOME/before"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$S5_BIN/jq"
  chmod +x "$S5_BIN/jq"
  run_step5
  assert_contains "$S5_OUT" "jq rewrite failed" "the failed rewrite is reported"
  assert_contains "$S5_OUT" "left untouched" "the report says the original was not modified"
  case "$S5_OUT" in *"✅"*) fail "a failed rewrite must not print the success line" ;; esac
  cmp -s "$S5_SETTINGS" "$S5_HOME/before" \
    || fail "a failed rewrite modified settings.json — it must be left untouched"
  assert_eq "0" "$S5_TMP_LEFT" "the truncated .tmp is cleaned up, not left beside the real file"
  rm -rf "$S5_HOME"
}

# Fail closed when the mode cannot be RE-APPLIED to the staged file: the .tmp is
# dropped and the real file is untouched, rather than published at the umask's
# mode. `chmod` is stubbed to fail; the stub passes every other invocation
# through so the sandbox's own setup is unaffected.
test_failed_mode_restore_fails_closed() {
  new_sandbox
  write_settings "$S5_SETTINGS"
  chmod 600 "$S5_SETTINGS"
  cp "$S5_SETTINGS" "$S5_HOME/before"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$S5_BIN/chmod"
  chmod +x "$S5_BIN/chmod"
  run_step5
  assert_contains "$S5_OUT" "Could not restore mode" "the failed mode restore is reported"
  assert_contains "$S5_OUT" "left untouched" "the report says the original was not modified"
  case "$S5_OUT" in *"✅"*) fail "a failed mode restore must not print the success line" ;; esac
  cmp -s "$S5_SETTINGS" "$S5_HOME/before" \
    || fail "a failed mode restore modified settings.json — it must be left untouched"
  assert_eq "0" "$S5_TMP_LEFT" "the staged .tmp is cleaned up, not left beside the real file"
  rm -rf "$S5_HOME"
}

# The real jq must actually be reachable for the happy-path cases above — if it
# were not, they would pass vacuously on an unwritten file.
test_real_jq_is_available() {
  [ -n "$REAL_JQ" ] || fail "jq is not on PATH — the happy-path cases would be vacuous"
}

run_tests
