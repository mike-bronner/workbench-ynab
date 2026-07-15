#!/usr/bin/env bash
# Unit tests for hooks/session-warmup.sh — the SessionStart/PostCompact warmup.
# Run directly: tests/unit/session-warmup.test.sh
#
# Style mirrors tests/launcher.test.sh: raw bash, `set -u`, PASS/FAIL
# counters, a mktemp sandbox, and a non-zero exit when anything fails. Slots into
# the repo-wide test entrypoint from issue #4 (tests/unit/ + scripts/test.sh).
#
# Seams (no test-only code in the script under test):
#   - `security` is shadowed by a stub on PATH so the Keychain branch is driven
#     purely by the stub's exit code ($STUB_SECURITY_RC), exactly as config.test.sh
#     shadows `jq` by emptying PATH. The stub also prints a sentinel on stdout so
#     the suite can prove the warmup never surfaces a Keychain value.
#   - config presence is driven by YNAB_CONFIG_FILE, the same override the loader
#     (bin/config.sh) documents — pointed at a real or absent sandbox path.

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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1)); echo "  ✅ $desc"
  else
    FAIL=$((FAIL + 1)); echo "  ❌ $desc — expected: [$expected] got: [$actual]"
  fi
}

assert_empty() {
  local desc="$1" actual="$2"
  if [ -z "$actual" ]; then
    PASS=$((PASS + 1)); echo "  ✅ $desc"
  else
    FAIL=$((FAIL + 1)); echo "  ❌ $desc — expected empty, got: [$actual]"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1)); echo "  ✅ $desc"
  else
    FAIL=$((FAIL + 1)); echo "  ❌ $desc — expected to find: [$needle] in: [$haystack]"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    FAIL=$((FAIL + 1)); echo "  ❌ $desc — unexpectedly found: [$needle]"
  else
    PASS=$((PASS + 1)); echo "  ✅ $desc"
  fi
}

# run <security-rc> <config-path> — run the warmup with the Keychain branch and
# config presence pinned, capturing stdout in OUT and the exit code in RC.
run() {
  local rc="$1" cfg="$2"
  OUT="$(STUB_SECURITY_RC="$rc" YNAB_CONFIG_FILE="$cfg" PATH="$STUB_BIN:$PATH" bash "$WARMUP")"
  RC=$?
}

echo "token absent + config absent — emits, points at setup, exit 0:"
run 1 "$ABSENT_CFG"
assert_eq       "exit code is 0"                     "0" "$RC"
assert_contains "block points at /workbench-ynab:setup" "$OUT" "/workbench-ynab:setup"
assert_contains "block flags the missing token"      "$OUT" "Keychain"
assert_contains "block flags the missing config"     "$OUT" "Config not found"
assert_not_contains "token value never surfaced"     "$OUT" "$SENTINEL"

echo "token absent + config present — emits token note only, exit 0:"
run 1 "$PRESENT_CFG"
assert_eq       "exit code is 0"                     "0" "$RC"
assert_contains "block points at /workbench-ynab:setup" "$OUT" "/workbench-ynab:setup"
assert_contains "block flags the missing token"      "$OUT" "Keychain"
assert_not_contains "no missing-config note when config present" "$OUT" "Config not found"
assert_not_contains "token value never surfaced"     "$OUT" "$SENTINEL"

echo "token present + config absent — emits config note only, exit 0:"
run 0 "$ABSENT_CFG"
assert_eq       "exit code is 0"                     "0" "$RC"
assert_contains "block points at /workbench-ynab:setup" "$OUT" "/workbench-ynab:setup"
assert_contains "block flags the missing config"     "$OUT" "Config not found"
assert_not_contains "no missing-token note when token present" "$OUT" "Keychain"
assert_not_contains "token value never surfaced"     "$OUT" "$SENTINEL"

echo "token present + config present — completely silent, exit 0:"
run 0 "$PRESENT_CFG"
assert_eq    "exit code is 0"                        "0" "$RC"
assert_empty "stdout is empty on a healthy session"  "$OUT"

echo "every exit path returns 0 (failure branch must not abort a session):"
# security stub failing AND a non-writable config dir — script still exits 0.
run 1 "$SANDBOX/nested/missing/config.json"
assert_eq "exit code is 0 even when both checks fail" "0" "$RC"

echo "HOME unset + config path unset — set -u must not abort on the first line, exit 0:"
# Regression for the set -u trap: with neither HOME nor YNAB_CONFIG_FILE set, the
# config-path default expands ${HOME:-} to empty rather than raising
# "HOME: unbound variable". The path then degrades to a guaranteed-absent
# location → config reads as missing → the setup block is emitted, exit 0. A bare
# $HOME here would abort non-zero before any exit 0, breaking the AC #2 contract.
OUT="$(env -u HOME -u YNAB_CONFIG_FILE STUB_SECURITY_RC=1 PATH="$STUB_BIN:$PATH" bash "$WARMUP")"
RC=$?
assert_eq       "exit code is 0 with HOME unset"        "0" "$RC"
assert_contains "still points at /workbench-ynab:setup" "$OUT" "/workbench-ynab:setup"

echo ""
echo "session-warmup: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
