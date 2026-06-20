#!/usr/bin/env bash
#
# launcher.test.sh — verifies bin/launcher.sh (issue #12).
#
# Self-contained: no test framework required. Run directly:
#   bash tests/launcher.test.sh
# Exits 0 if all assertions pass, 1 otherwise. Style mirrors the sibling
# tests/persona-loader.test.sh and tests/unit/test-config.sh: raw bash, `set -u`,
# PASS/FAIL counters, a mktemp sandbox, non-zero exit on any failure.
#
# The launcher reads the macOS Keychain and `exec`s node on the vendored bundle,
# so the tests stub `security` and `node` on a controlled PATH. This keeps every
# case hermetic — the real Keychain is never touched and the real MCP server is
# never started — while still exercising the three observable behaviors that
# matter: the Keychain-miss error, the node-missing error, and a clean hand-off
# that exports YNAB_ACCESS_TOKEN and execs node on the bin/ynab-mcp shim with
# nothing written to stdout.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LAUNCHER="${REPO_ROOT}/bin/launcher.sh"

PASS=0
FAIL=0

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# Host paths to the only externals the launcher needs before it execs node:
# `bash` (the interpreter) and `dirname` (SCRIPT_DIR resolution). The isolated
# PATH cases below seed a stub dir with just these, so `node` is guaranteed
# absent regardless of where the host installs it (/bin vs /usr/bin vs brew).
BASH_BIN="$(command -v bash)"
DIRNAME_BIN="$(command -v dirname)"

# seed_coreutils <dir> — symlink the bare-minimum host tools into a stub dir so a
# PATH pointed at only <dir> can still launch the script and resolve SCRIPT_DIR.
seed_coreutils() {
  local dir="$1"
  mkdir -p "$dir"
  ln -sf "$BASH_BIN" "$dir/bash"
  ln -sf "$DIRNAME_BIN" "$dir/dirname"
}

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
    FAIL=$((FAIL + 1)); echo "  ❌ $desc — did NOT expect to find: [$needle]"
  else
    PASS=$((PASS + 1)); echo "  ✅ $desc"
  fi
}

# make_stub <dir> <name> <body...> — write an executable stub script.
make_stub() {
  local dir="$1" name="$2"; shift 2
  mkdir -p "$dir"
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$@"; } > "$dir/$name"
  chmod +x "$dir/$name"
}

# ── Case 1: Keychain miss — friendly error, exit 1, nothing on stdout ─────────
echo "Keychain miss — friendly error naming /workbench-ynab:setup, exit 1, clean stdout:"
STUB1="$SANDBOX/case1-bin"
# Fully isolated PATH (bash + dirname via seed_coreutils, plus the security stub
# below) — matches cases 2/3 so the empty-token guard can never fall through to a
# host `node` if the guard order is ever changed.
seed_coreutils "$STUB1"
# security exits non-zero with no stdout (item not found in Keychain).
make_stub "$STUB1" security 'exit 1'
out="$(PATH="$STUB1" "$BASH_BIN" "$LAUNCHER" 2>"$SANDBOX/case1.err")"; rc=$?
err="$(cat "$SANDBOX/case1.err")"
assert_eq        "exit code is 1"                       "1" "$rc"
assert_empty     "stdout is empty"                      "$out"
assert_contains  "stderr names the setup command"       "$err" "/workbench-ynab:setup"
assert_contains  "stderr is routed through _log prefix" "$err" "ynab-mcp:"

# ── Case 1b: whitespace-only token — reclassified as missing (issue #103) ─────
# A Keychain entry holding only whitespace must surface the SAME friendly setup
# guidance as an absent one, not pass the guard and exec node with a garbage
# token. Mirrors Case 1's assertions: exit 1, the setup message on stderr, and a
# pristine stdout (a stray byte would corrupt the MCP JSON-RPC handshake).
echo "whitespace-only token — treated as missing, friendly error, exit 1, clean stdout:"
STUB1B="$SANDBOX/case1b-bin"
seed_coreutils "$STUB1B"
# security succeeds (exit 0) but emits a whitespace-only value (spaces + a tab).
make_stub "$STUB1B" security 'printf "   \t\n"'
out="$(PATH="$STUB1B" "$BASH_BIN" "$LAUNCHER" 2>"$SANDBOX/case1b.err")"; rc=$?
err="$(cat "$SANDBOX/case1b.err")"
assert_eq        "exit code is 1"                       "1" "$rc"
assert_empty     "stdout is empty"                      "$out"
assert_contains  "stderr names the setup command"       "$err" "/workbench-ynab:setup"
assert_contains  "stderr is routed through _log prefix" "$err" "ynab-mcp:"

# ── Case 2: node missing — install guidance, exit 1, token never leaks ────────
echo "node missing (token present) — install guidance, exit 1, token never leaks:"
STUB2="$SANDBOX/case2-bin"
# Isolated PATH: security (returns a token) + bash + dirname, but deliberately
# NO node, so `command -v node` fails and the node-missing path is exercised.
seed_coreutils "$STUB2"
make_stub "$STUB2" security 'echo "secret-token-DO-NOT-LEAK"'
out="$(PATH="$STUB2" "$BASH_BIN" "$LAUNCHER" 2>"$SANDBOX/case2.err")"; rc=$?
err="$(cat "$SANDBOX/case2.err")"
assert_eq           "exit code is 1"                     "1" "$rc"
assert_empty        "stdout is empty"                    "$out"
assert_contains     "stderr gives node install guidance" "$err" "node not found on PATH"
assert_not_contains "token never appears on stderr"      "$err" "secret-token-DO-NOT-LEAK"
assert_not_contains "token never appears on stdout"      "$out" "secret-token-DO-NOT-LEAK"

# ── Case 3: happy path — exports token, execs node on the shim, clean stdout ──
echo "happy path — exports YNAB_ACCESS_TOKEN and execs node on the bin/ynab-mcp shim:"
STUB3="$SANDBOX/case3-bin"
CAPTURE="$SANDBOX/node-capture.txt"
seed_coreutils "$STUB3"
make_stub "$STUB3" security 'echo "happy-token-12345"'
# fake node: record argv + the exported token env to a capture file, emit NOTHING
# to stdout (a stray stdout byte would corrupt the real MCP handshake), exit 0.
make_stub "$STUB3" node \
  'echo "ARGV: $*" > "$NODE_CAPTURE"' \
  'echo "TOKEN_ENV: ${YNAB_ACCESS_TOKEN:-<unset>}" >> "$NODE_CAPTURE"' \
  'echo "fake-node: started" 1>&2' \
  'exit 0'
out="$(NODE_CAPTURE="$CAPTURE" PATH="$STUB3" "$BASH_BIN" "$LAUNCHER" 2>"$SANDBOX/case3.err")"; rc=$?
cap="$(cat "$CAPTURE" 2>/dev/null)"
err="$(cat "$SANDBOX/case3.err")"
assert_eq       "exit code is 0"                          "0" "$rc"
assert_empty    "stdout is empty before the handshake"    "$out"
assert_contains "node was exec'd on the bin/ynab-mcp shim" "$cap" "/ynab-mcp"
assert_contains "YNAB_ACCESS_TOKEN exported to node"       "$cap" "TOKEN_ENV: happy-token-12345"
# AC #8 — the happy path is where the token is actually exported and handed to
# node, so it's the most leak-relevant path: prove it never reaches stderr.
assert_not_contains "token never appears on stderr (happy path)" "$err" "happy-token-12345"

# ── Static guarantees on the script source ────────────────────────────────────
echo "source guarantees — executable bit, strict mode, exec hand-off:"
[ -x "$LAUNCHER" ]
assert_eq "launcher.sh has its executable bit set" "0" "$?"
src="$(cat "$LAUNCHER")"
assert_contains "first non-comment line is 'set -euo pipefail'" \
  "$(grep -vE '^[[:space:]]*#' "$LAUNCHER" | grep -vE '^[[:space:]]*$' | head -1)" \
  "set -euo pipefail"
assert_contains "final statement is 'exec node \"\$BUNDLE\"'" "$src" 'exec node "$BUNDLE"'
assert_contains "exports YNAB_ACCESS_TOKEN"                   "$src" 'export YNAB_ACCESS_TOKEN="$TOKEN"'
# Lock the portable SCRIPT_DIR derivation — an AC item, and a refactor to $0 or a
# hardcoded path would otherwise leave the whole suite green.
assert_contains "SCRIPT_DIR resolved via BASH_SOURCE"        "$src" 'BASH_SOURCE[0]'

echo ""
echo "launcher: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
