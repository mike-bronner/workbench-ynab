#!/usr/bin/env bash
#
# tests/unit/setup-config-write.test.sh — behavioral guards for the Step 4
# config-write block in /workbench-ynab:setup (commands/setup.md, issue #154).
#
# Step 4 used to fail OPEN: a malformed pre-existing config.json made the jq
# merge exit non-zero while the > redirect truncated the .tmp to 0 bytes, the
# token gate also failed to parse the empty file and was skipped, and the empty
# .tmp was mv'd over the user's real config with a ✅ — data loss reported as
# success. These tests EXTRACT the real Step 4 fenced block from setup.md and
# EXECUTE it in a sandbox (the setup-monitor-deploy.test.sh extract-and-run
# pattern), so they stay coupled to whatever code the command actually ships:
#   * a malformed pre-existing config aborts, ❌, non-zero — file untouched;
#   * a failed merge (bad $NEW_JSON) aborts the same way;
#   * no abort path leaves a stale $CONFIG_FILE.tmp behind;
#   * the happy paths (fresh write, merge preserving unknown keys) still work;
#   * the token gate still refuses a token-shaped value pre-publish.
#
# The synthetic token below is BUILT at runtime — a literal 64-hex string in
# the tree would trip bin/secret-scan.sh (the point of that scanner).
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

# Portable octal-perms read: GNU `stat -c '%a'` probed FIRST (on GNU, `stat -f`
# misreads `%Lp`), BSD/macOS `stat -f '%Lp'` as the fallback. Same helper the
# report-writer / audit-log suites use for mode-bit assertions.
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# Pull the first ```bash fenced block out of the "## Step 4" section — the
# config-write code as shipped. Restructuring Step 4 breaks the extraction
# guard test below, which is the signal to update this test.
extract_step4_block() {
  awk '/^## Step 4 /{s=1; next} s && /^## /{exit}
       s && /^```bash$/{f=1; next} f && /^```$/{exit} f{print}' "$CMD"
}

# Run the extracted block in sandbox dir $1 with NEW_JSON $2. Prints combined
# stdout+stderr; the block's exit code is this function's return value.
run_step4() {
  CONFIG_DIR="$1" CONFIG_FILE="$1/config.json" NEW_JSON="$2" \
    bash -c "$(extract_step4_block)" 2>&1
}

# The extraction still finds the block (and it's the merge block, not another).
test_step4_block_extracts() {
  local block; block="$(extract_step4_block)"
  # The needles are literal command source text — never expanded here.
  # shellcheck disable=SC2016
  assert_contains "$block" 'jq --argjson new "$NEW_JSON"' \
    "the extracted Step 4 block contains the jq merge"
  # shellcheck disable=SC2016
  assert_contains "$block" 'mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"' \
    "the extracted Step 4 block contains the publish mv"
}

# Happy path — no pre-existing file: the write succeeds and reports ✅.
test_fresh_write_succeeds() {
  local dir out
  dir="$(mktemp -d)"
  out="$(run_step4 "$dir" '{"schema_version":1,"budget":{"name":"Test"}}')" \
    || fail "fresh write exited non-zero: $out"
  assert_contains "$out" "✅ Wrote" "fresh write reports success"
  assert_json_valid "$dir/config.json"
  assert_eq "Test" "$(jq -r '.budget.name' "$dir/config.json")" "new value landed"
  rm -rf "$dir"
}

# Happy path — a well-formed pre-existing config merges, and keys this command
# doesn't manage (hand-added mapping_rules) survive. No behavior change.
test_merge_preserves_unknown_keys() {
  local dir out
  dir="$(mktemp -d)"
  printf '{"budget":{"name":"Old"},"mapping_rules":{"x":1}}\n' > "$dir/config.json"
  out="$(run_step4 "$dir" '{"budget":{"name":"New"}}')" \
    || fail "merge over a valid config exited non-zero: $out"
  assert_eq "New" "$(jq -r '.budget.name' "$dir/config.json")" "new value wins"
  assert_eq "1" "$(jq -r '.mapping_rules.x' "$dir/config.json")" \
    "hand-added mapping_rules survive the merge"
  rm -rf "$dir"
}

# Issue #154 core: a malformed pre-existing config.json aborts BEFORE the merge
# — non-zero exit, ❌ (never the ✅ success line), the file byte-for-byte
# untouched, and no stale .tmp left behind.
test_malformed_existing_aborts_and_preserves() {
  local dir out rc=0
  dir="$(mktemp -d)"
  printf '{definitely not json\n' > "$dir/config.json"
  cp "$dir/config.json" "$dir/before"
  out="$(run_step4 "$dir" '{"budget":{"name":"New"}}')" || rc=$?
  [ "$rc" -ne 0 ] || fail "malformed existing config must exit non-zero, got: $out"
  assert_contains "$out" "❌" "abort prints an error"
  case "$out" in *"✅ Wrote"*) fail "abort must not print the success line" ;; esac
  cmp -s "$dir/config.json" "$dir/before" \
    || fail "the malformed config.json was modified — it must be left untouched"
  [ ! -e "$dir/config.json.tmp" ] || fail "a stale config.json.tmp was left behind"
  rm -rf "$dir"
}

# Issue #154 core: when the merge jq itself fails (unparseable $NEW_JSON), the
# write aborts the same way — the valid pre-existing config is preserved and
# the truncated .tmp is removed, never published.
test_failed_merge_aborts_and_preserves() {
  local dir out rc=0
  dir="$(mktemp -d)"
  printf '{"budget":{"name":"Old"}}\n' > "$dir/config.json"
  cp "$dir/config.json" "$dir/before"
  out="$(run_step4 "$dir" '{not json')" || rc=$?
  [ "$rc" -ne 0 ] || fail "a failed merge must exit non-zero, got: $out"
  assert_contains "$out" "❌" "abort prints an error"
  case "$out" in *"✅ Wrote"*) fail "abort must not print the success line" ;; esac
  cmp -s "$dir/config.json" "$dir/before" \
    || fail "config.json was modified by a failed merge — it must be left untouched"
  [ ! -e "$dir/config.json.tmp" ] || fail "a stale config.json.tmp was left behind"
  rm -rf "$dir"
}

# The pre-publish token gate still refuses a token-shaped value (PR #127
# behavior, re-pinned here behaviorally). The synthetic token is constructed at
# runtime so no token-shaped literal is committed (bin/secret-scan.sh).
test_token_shaped_value_still_refused() {
  local dir out rc=0 fake_token
  dir="$(mktemp -d)"
  fake_token="$(printf 'ab%.0s' $(seq 1 32))"   # 64 chars of [0-9a-f]
  out="$(run_step4 "$dir" "{\"budget\":{\"name\":\"$fake_token\"}}")" || rc=$?
  [ "$rc" -ne 0 ] || fail "a token-shaped value must be refused, got: $out"
  assert_contains "$out" "Keychain only" "the token-refusal message is printed"
  [ ! -e "$dir/config.json" ] || fail "a token-bearing config was published"
  [ ! -e "$dir/config.json.tmp" ] || fail "a stale config.json.tmp was left behind"
  rm -rf "$dir"
}

# The token gate fails CLOSED. Its unparseable-tmp branch is unreachable through
# the full block (the staged-file validation aborts first — defense in depth),
# so pin the structure: only scan exit code 1 ("ran clean, nothing found") may
# pass; every other outcome aborts. A bare `if jq -e …` regression (exit ≥2
# falling into the "safe" path) removes the -ne 1 branch and fails this test.
test_token_gate_fails_closed() {
  local block; block="$(extract_step4_block)"
  assert_contains "$block" 'TOKEN_SCAN" -ne 1' \
    "the token gate treats any scan outcome other than exit 1 as unsafe"
  assert_contains "$block" "Could not verify the staged config is token-free" \
    "the cannot-verify abort path exists"
}

# AC1: the plugin data dir is owner-only (0700) — and a PRE-EXISTING loose (0755)
# dir is TIGHTENED, because Step 4's `chmod 700 "$CONFIG_DIR"` is now a fail-closed
# gate, not a swallowed afterthought. The dir pre-exists at 0755, so the block's
# `mkdir -p` is a no-op on its mode — only the explicit chmod tightens it, so
# dropping that chmod reddens this. Runs under umask 022 so a regression to a bare
# `mkdir -p` (no umask/chmod) would also leave a FRESH dir 0755 and fail here.
test_data_dir_tightened_to_0700_when_preexisting_loose() {
  local dir out
  dir="$(mktemp -d)"
  chmod 755 "$dir"
  assert_eq "755" "$(mode_of "$dir")" "the data dir pre-exists loose (0755)"
  out="$( umask 022; run_step4 "$dir" '{"schema_version":1,"budget":{"name":"Test"}}' )" \
    || fail "write over a pre-existing 0755 data dir exited non-zero: $out"
  assert_contains "$out" "✅ Wrote" "the write still succeeds over a pre-existing loose dir"
  assert_eq "700" "$(mode_of "$dir")" "the data dir is tightened to owner-only 0700"
  rm -rf "$dir"
}

run_tests
