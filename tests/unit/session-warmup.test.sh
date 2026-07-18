#!/usr/bin/env bash
# Unit tests for hooks/session-warmup.sh — the SessionStart/PostCompact warmup.
# Run directly: tests/unit/session-warmup.test.sh
#
# Style mirrors tests/launcher.test.sh: raw bash, `set -u`, PASS/FAIL
# counters, a mktemp sandbox, and a non-zero exit when anything fails. Slots into
# the repo-wide test entrypoint from issue #4 (tests/unit/ + scripts/test.sh).
#
# The warmup emits three STDOUT signals, most-urgent first (issue #37):
#   1. version-drift  — fires only when the running bundle is STRICTLY behind the
#      newest CLI-cache version (driven by CLAUDE_PLUGIN_ROOT + a sandbox HOME).
#   2. setup-incomplete — fires when the Keychain token and/or config.json is
#      missing (driven by the `security` stub's rc + YNAB_CONFIG_FILE).
#   3. routing guidance — the standing reference block, emitted EVERY session.
#
# Seams (no test-only code in the script under test):
#   - `security` is shadowed by a stub on PATH so the Keychain branch is driven
#     purely by the stub's exit code ($STUB_SECURITY_RC), exactly as config.test.sh
#     shadows `jq` by emptying PATH. The stub also prints a sentinel on stdout so
#     the suite can prove the warmup never surfaces a Keychain value.
#   - config presence is driven by YNAB_CONFIG_FILE, the same override the loader
#     (bin/config.sh) documents — pointed at a real or absent sandbox path.
#   - version-drift is driven by a sandbox HOME (holding a fake CLI cache) and
#     CLAUDE_PLUGIN_ROOT (holding a fake bundle plugin.json), so the real cache
#     and real bundle are never read.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WARMUP="$REPO_ROOT/hooks/session-warmup.sh"
PASS=0
FAIL=0

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# Sentinel the stub `security` prints on every call; the warmup must NEVER let it
# reach stdout (it checks existence only, never reads the value with `-w`).
SENTINEL="SENTINEL-TOKEN-VALUE-DO-NOT-LEAK"

STUB_BIN="$SANDBOX/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/security" <<STUB
#!/usr/bin/env bash
# Test stub for security(1). Prints a sentinel (so the suite can assert the
# warmup never surfaces it) and exits with the rc the test pins.
echo "$SENTINEL"
exit "\${STUB_SECURITY_RC:-0}"
STUB
chmod +x "$STUB_BIN/security"

# A config fixture that exists, and a path that is guaranteed absent.
PRESENT_CFG="$SANDBOX/config.json"
echo '{ "schema_version": 1 }' > "$PRESENT_CFG"
ABSENT_CFG="$SANDBOX/does-not-exist.json"

# A clean HOME with no CLI cache, for cases that are not about version-drift.
CLEAN_HOME="$SANDBOX/clean-home"
mkdir -p "$CLEAN_HOME"

# The routing block's tool namespace — the load-bearing "use these tools" fact.
NS="mcp__plugin_workbench-ynab_ynab__"

# mk_bundle <root> <version> — write a plugin.json carrying <version>.
mk_bundle() {
  mkdir -p "$1/.claude-plugin"
  printf '{ "name": "workbench-ynab", "version": "%s" }\n' "$2" > "$1/.claude-plugin/plugin.json"
}

# mk_cache <home> <version...> — create semver dirs under the CLI plugin cache.
mk_cache() {
  local home="$1"; shift
  local cd="$home/.claude/plugins/cache/claude-workbench/workbench-ynab"
  mkdir -p "$cd"
  local v
  for v in "$@"; do mkdir -p "$cd/$v"; done
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1)); echo "  ✅ $desc"
  else
    FAIL=$((FAIL + 1)); echo "  ❌ $desc — expected: [$expected] got: [$actual]"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1)); echo "  ✅ $desc"
  else
    FAIL=$((FAIL + 1)); echo "  ❌ $desc — expected to find: [$needle] in: [$haystack]"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    FAIL=$((FAIL + 1)); echo "  ❌ $desc — unexpectedly found: [$needle]"
  else
    PASS=$((PASS + 1)); echo "  ✅ $desc"
  fi
}

# run <security-rc> <config-path> <home|KEEP> <plugin-root|UNSET> — run the warmup
# with the Keychain branch, config presence, HOME (cache lookup), and bundle root
# (drift lookup) all pinned. Captures stdout in OUT and the exit code in RC. STDOUT
# from the `security` stub is discarded by the warmup itself, so a sentinel in OUT
# would prove a leak.
run() {
  local rc="$1" cfg="$2" home="$3" root="$4"
  local -a e=(env)
  [ "$root" = UNSET ] && e+=(-u CLAUDE_PLUGIN_ROOT)
  e+=(STUB_SECURITY_RC="$rc" YNAB_CONFIG_FILE="$cfg" PATH="$STUB_BIN:$PATH")
  [ "$home" != KEEP ] && e+=(HOME="$home")
  [ "$root" != UNSET ] && e+=(CLAUDE_PLUGIN_ROOT="$root")
  OUT="$("${e[@]}" bash "$WARMUP")"
  RC=$?
}

# assert the standing routing block is present in $OUT (it must be, every session)
assert_routing_present() {
  local ctx="$1"
  assert_contains     "$ctx: routing namespace mcp__plugin_workbench-ynab_ynab__" "$OUT" "$NS"
  assert_contains     "$ctx: warns against bare mcp__ynab__"    "$OUT" "mcp__ynab__*"
  assert_contains     "$ctx: read-only (M2) posture"           "$OUT" "READ-ONLY"
  assert_contains     "$ctx: config/token split (YNAB_ACCESS_TOKEN)" "$OUT" "YNAB_ACCESS_TOKEN"
  assert_contains     "$ctx: pointer to /workbench-ynab:ynab-review" "$OUT" "/workbench-ynab:ynab-review"
  assert_contains     "$ctx: trigger-vocabulary table"         "$OUT" "Trigger vocabulary"
}

echo "healthy session (token + config present) — routing emitted, no setup block, exit 0:"
run 0 "$PRESENT_CFG" "$CLEAN_HOME" UNSET
assert_eq           "exit code is 0"                         "0" "$RC"
assert_routing_present "healthy"
assert_not_contains "no setup-incomplete block when healthy" "$OUT" "setup incomplete"
assert_not_contains "token value never surfaced"             "$OUT" "$SENTINEL"

echo "token absent + config absent — setup block emitted AND routing still emitted, exit 0:"
run 1 "$ABSENT_CFG" "$CLEAN_HOME" UNSET
assert_eq           "exit code is 0"                         "0" "$RC"
assert_contains     "block points at /workbench-ynab:setup"  "$OUT" "/workbench-ynab:setup"
assert_contains     "block flags the missing token"         "$OUT" "access token not found"
assert_contains     "block flags the missing config"        "$OUT" "Config not found"
assert_routing_present "misconfigured"
assert_not_contains "token value never surfaced"             "$OUT" "$SENTINEL"

echo "token absent + config present — token note only, exit 0:"
run 1 "$PRESENT_CFG" "$CLEAN_HOME" UNSET
assert_eq           "exit code is 0"                         "0" "$RC"
assert_contains     "block flags the missing token"         "$OUT" "access token not found"
assert_not_contains "no missing-config note when config present" "$OUT" "Config not found"
assert_not_contains "token value never surfaced"             "$OUT" "$SENTINEL"

echo "token present + config absent — config note only, exit 0:"
run 0 "$ABSENT_CFG" "$CLEAN_HOME" UNSET
assert_eq           "exit code is 0"                         "0" "$RC"
assert_contains     "block flags the missing config"        "$OUT" "Config not found"
assert_not_contains "no missing-token note when token present" "$OUT" "access token not found"
assert_not_contains "token value never surfaced"             "$OUT" "$SENTINEL"

echo "version-drift fires only when the bundle is STRICTLY behind newest cache:"
DRIFT_HOME="$SANDBOX/drift-home"
mk_cache "$DRIFT_HOME" "0.2.0"
ROOT_OLD="$SANDBOX/root-old"; mk_bundle "$ROOT_OLD" "0.1.0"
run 0 "$PRESENT_CFG" "$DRIFT_HOME" "$ROOT_OLD"
assert_eq           "exit code is 0"                         "0" "$RC"
assert_contains     "drift: warning header present"         "$OUT" "version drift"
assert_contains     "drift: names running bundle version"   "$OUT" "v0.1.0"
assert_contains     "drift: names newest cached version"    "$OUT" "v0.2.0"
assert_routing_present "drift"

echo "no drift when bundle equals newest cache — routing still emitted, exit 0:"
ROOT_EQ="$SANDBOX/root-eq"; mk_bundle "$ROOT_EQ" "0.2.0"
run 0 "$PRESENT_CFG" "$DRIFT_HOME" "$ROOT_EQ"
assert_eq           "exit code is 0"                        "0" "$RC"
assert_not_contains "equal versions → no drift warning"     "$OUT" "version drift"
assert_routing_present "equal-version"

echo "no drift when bundle is newer than cache — routing still emitted, exit 0:"
ROOT_NEW="$SANDBOX/root-new"; mk_bundle "$ROOT_NEW" "0.3.0"
run 0 "$PRESENT_CFG" "$DRIFT_HOME" "$ROOT_NEW"
assert_eq           "exit code is 0"                        "0" "$RC"
assert_not_contains "newer bundle → no drift warning"       "$OUT" "version drift"
assert_routing_present "newer-version"

echo "newest cache is chosen numerically, not lexically (0.10.0 > 0.9.0) — routing still emitted, exit 0:"
NUM_HOME="$SANDBOX/num-home"
mk_cache "$NUM_HOME" "0.2.0" "0.9.0" "0.10.0"
ROOT_9="$SANDBOX/root-9"; mk_bundle "$ROOT_9" "0.9.0"
run 0 "$PRESENT_CFG" "$NUM_HOME" "$ROOT_9"
assert_eq           "exit code is 0"                        "0" "$RC"
assert_contains     "numeric sort → drift against v0.10.0"  "$OUT" "v0.10.0"
assert_routing_present "numeric-sort"

echo "no cache dir → drift check is silent — routing still emitted, exit 0:"
run 0 "$PRESENT_CFG" "$CLEAN_HOME" "$ROOT_OLD"
assert_eq           "exit code is 0"                        "0" "$RC"
assert_not_contains "no cache dir → no drift warning"       "$OUT" "version drift"
assert_routing_present "no-cache-dir"

echo "bundle root without plugin.json (broken/partial install) → drift silent, routing still emitted, exit 0:"
# A CLAUDE_PLUGIN_ROOT that exists but has no .claude-plugin/plugin.json drives
# `_ynab_plugin_version` non-zero → the `bundle=$(...) || return 0` gate
# (session-warmup.sh:84). A valid cache is present (DRIFT_HOME, v0.2.0), so the
# ONLY reason no drift fires is the missing bundle file — isolating this gate
# from the no-cache gate. A `return 0`→`exit 0` typo here would skip the routing
# block and trip assert_routing_present.
ROOT_NOPLUGIN="$SANDBOX/root-noplugin"; mkdir -p "$ROOT_NOPLUGIN"
run 0 "$PRESENT_CFG" "$DRIFT_HOME" "$ROOT_NOPLUGIN"
assert_eq           "exit code is 0"                        "0" "$RC"
assert_not_contains "missing plugin.json → no drift warning" "$OUT" "version drift"
assert_routing_present "broken-install"

echo "CLAUDE_PLUGIN_ROOT unset → set -u safe, no drift, routing still emitted, exit 0:"
run 0 "$PRESENT_CFG" "$DRIFT_HOME" UNSET
assert_eq           "exit code is 0 with CLAUDE_PLUGIN_ROOT unset" "0" "$RC"
assert_not_contains "unset root → no drift warning"         "$OUT" "version drift"
assert_routing_present "unset-root"

echo "every exit path returns 0 (failure branch must not abort a session):"
# security stub failing AND a non-writable config dir — script still exits 0.
run 1 "$SANDBOX/nested/missing/config.json" "$CLEAN_HOME" UNSET
assert_eq "exit code is 0 even when both checks fail" "0" "$RC"

echo "HOME unset + config path unset — set -u must not abort on the first line, exit 0:"
# Regression for the set -u trap: with neither HOME nor YNAB_CONFIG_FILE set, the
# config-path default expands ${HOME:-} to empty rather than raising
# "HOME: unbound variable". The path then degrades to a guaranteed-absent
# location → config reads as missing → the setup block is emitted, exit 0. A bare
# $HOME here would abort non-zero before any exit 0, breaking the AC #2 contract.
OUT="$(env -u HOME -u YNAB_CONFIG_FILE -u CLAUDE_PLUGIN_ROOT STUB_SECURITY_RC=1 PATH="$STUB_BIN:$PATH" bash "$WARMUP")"
RC=$?
assert_eq       "exit code is 0 with HOME unset"        "0" "$RC"
assert_contains "still points at /workbench-ynab:setup" "$OUT" "/workbench-ynab:setup"

echo ""
echo "session-warmup: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
