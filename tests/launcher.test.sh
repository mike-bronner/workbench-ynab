#!/usr/bin/env bash
#
# launcher.test.sh — verifies bin/launcher.sh (issue #12).
#
# Self-contained: no test framework required. Run directly:
#   bash tests/launcher.test.sh
# Exits 0 if all assertions pass, 1 otherwise. Style mirrors the sibling
# tests/persona-loader.test.sh: raw bash, `set -u`,
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

# ── Case 2b: node below the pinned floor — actionable error, exit 1 (issue #3) ─
# The launcher runs bin/node-floor.sh before exec'ing node, so a runtime older
# than vendor/ynab-mcp/NODE_VERSION must fail fast with the upgrade message on
# STDERR only — scheduled runs bypass interactive setup, and a stray stdout
# byte would corrupt the MCP JSON-RPC handshake. The stub node answers ONLY
# --version (one major below the canonical floor, read from the repo file so a
# future floor bump never stales this case) and records any other invocation:
# reaching the exec with an under-floor node would be the exact cryptic-boot
# failure the gate exists to prevent.
echo "node below the pinned floor — upgrade guidance on stderr, exit 1, clean stdout:"
NODE_FLOOR_PIN="$(tr -d '[:space:]' < "$REPO_ROOT/vendor/ynab-mcp/NODE_VERSION")"
BELOW_FLOOR_V="v$((NODE_FLOOR_PIN - 1)).0.0"
STUB2B="$SANDBOX/case2b-bin"
CAPTURE2B="$SANDBOX/case2b-node-capture.txt"
seed_coreutils "$STUB2B"
make_stub "$STUB2B" security 'echo "secret-token-DO-NOT-LEAK"'
# Stub bodies are literal by design: they expand when the stub RUNS.
# shellcheck disable=SC2016
make_stub "$STUB2B" node \
  'if [ "${1:-}" = "--version" ]; then echo "'"$BELOW_FLOOR_V"'"; exit 0; fi' \
  'echo "ARGV: $*" > "$NODE_CAPTURE"' \
  'exit 0'
out="$(NODE_CAPTURE="$CAPTURE2B" PATH="$STUB2B" "$BASH_BIN" "$LAUNCHER" 2>"$SANDBOX/case2b.err")"; rc=$?
err="$(cat "$SANDBOX/case2b.err")"
assert_eq           "exit code is 1"                    "1" "$rc"
assert_empty        "stdout is empty"                   "$out"
assert_contains     "stderr states the required floor"  "$err" "workbench-ynab requires Node >= $NODE_FLOOR_PIN"
assert_contains     "stderr names the installed version" "$err" "you have $BELOW_FLOOR_V"
assert_empty        "node is never exec'd on the bundle under an unsupported major" "$(cat "$CAPTURE2B" 2>/dev/null)"
assert_not_contains "token never appears on stderr"     "$err" "secret-token-DO-NOT-LEAK"
assert_not_contains "token never appears on stdout"     "$out" "secret-token-DO-NOT-LEAK"

# ── Case 3: happy path — exports token, execs node on the shim, clean stdout ──
echo "happy path — exports YNAB_ACCESS_TOKEN and execs node on the bin/ynab-mcp shim:"
STUB3="$SANDBOX/case3-bin"
CAPTURE="$SANDBOX/node-capture.txt"
seed_coreutils "$STUB3"
make_stub "$STUB3" security 'echo "happy-token-12345"'
# fake node: answer the floor gate's --version probe with a far-future major
# (so the issue #3 version gate passes regardless of the pinned floor), then
# record argv + the exported token env to a capture file, emit NOTHING to
# stdout (a stray stdout byte would corrupt the real MCP handshake), exit 0.
# Stub bodies below are literal by design: they expand when the stub RUNS.
# shellcheck disable=SC2016
make_stub "$STUB3" node \
  'if [ "${1:-}" = "--version" ]; then echo "v999.0.0"; exit 0; fi' \
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
x_rc=0; [ -x "$LAUNCHER" ] || x_rc=1
assert_eq "launcher.sh has its executable bit set" "0" "$x_rc"
src="$(cat "$LAUNCHER")"
assert_contains "first non-comment line is 'set -euo pipefail'" \
  "$(grep -vE '^[[:space:]]*#' "$LAUNCHER" | grep -vE '^[[:space:]]*$' | head -1)" \
  "set -euo pipefail"
# The single-quoted needles are literal launcher source text — never expanded here.
# shellcheck disable=SC2016
assert_contains "final statement is 'exec node \"\$BUNDLE\"'" "$src" 'exec node "$BUNDLE"'
# shellcheck disable=SC2016
assert_contains "exports YNAB_ACCESS_TOKEN"                   "$src" 'export YNAB_ACCESS_TOKEN="$TOKEN"'
# Lock the portable SCRIPT_DIR derivation — an AC item, and a refactor to $0 or a
# hardcoded path would otherwise leave the whole suite green.
assert_contains "SCRIPT_DIR resolved via BASH_SOURCE"        "$src" 'BASH_SOURCE[0]'

# ── MCP-boundary invariant: the launch path is persona/plugin-config-free ─────
# Issue #28 AC 9 (docs/persona.md, "Boundary: SKILL-only, never the MCP"): the
# vendored YNAB MCP never receives persona config. The launcher is the ONLY
# code between Claude Code and that server, so the invariant holds iff its
# EXECUTABLE code never touches the plugin config — no bin/config.sh source, no
# YNAB_CONFIG_FILE / config.json read, no persona reference — and the only env
# it exports to the MCP is the package-native access token. Mirrors the static
# half of tests/unit/persona-write-gate-isolation.test.sh. Comments are
# stripped first because the launcher's header deliberately DOCUMENTS the
# config split (naming config.sh and persona) — the guarantee is about code,
# not prose.
echo "MCP-boundary invariant — launch path sources no persona/plugin config:"
code="$(grep -vE '^[[:space:]]*#' "$LAUNCHER")"
for banned in 'persona' 'config\.sh' 'config\.json' 'YNAB_CONFIG_FILE'; do
  if printf '%s' "$code" | grep -qiE "$banned"; then
    FAIL=$((FAIL + 1)); echo "  ❌ launcher code references '$banned' — the launch path must stay config-free"
  else
    PASS=$((PASS + 1)); echo "  ✅ launcher code has no '$banned' reference"
  fi
done
exports="$(printf '%s' "$code" | grep -E '^[[:space:]]*export ' || true)"
# The single-quoted needle is literal launcher source text — never expanded here.
# shellcheck disable=SC2016
assert_eq "the ONLY export is the package-native token env" \
  'export YNAB_ACCESS_TOKEN="$TOKEN"' "$exports"

echo ""
echo "launcher: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
