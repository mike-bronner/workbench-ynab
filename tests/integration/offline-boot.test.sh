#!/usr/bin/env bash
#
# offline-boot.test.sh — the M1-7 offline-boot proof (issue #14).
#
# PURPOSE
#   Prove the vendoring decision's load-bearing claim: the frozen bundle at
#   vendor/ynab-mcp/index.cjs is genuinely self-contained — it boots on system
#   `node` with NO `node_modules` anywhere on the resolution path, completes a
#   full MCP stdio handshake (initialize + tools/list), and never fails for a
#   missing module. If this ever stops holding (a bad re-vendor, a dependency
#   that didn't get inlined), the proof must fail LOUDLY so the M1-3 fallback
#   (full tree or npm-ci-at-setup) can be reconsidered.
#
# FAILURE SEMANTICS
#   * A failed assertion fails its test_* function; `run_tests` then exits
#     non-zero, which fails `scripts/test.sh` and CI (#16).
#   * On a module-resolution failure (or any non-zero/hung boot) the captured
#     stdout+stderr are written to tests/integration/offline-boot-failure.txt
#     as evidence, instead of being swallowed — that file is the artifact that
#     justifies falling back to M1-3. It is git-ignored (a generated diagnostic).
#   * This validates MODULE RESOLUTION, not credentials. A dummy sentinel token
#     is correct: the MCP completes the stdio handshake and lists tools BEFORE
#     it ever reaches the YNAB API, so no real token is needed (or wanted).
#
# WIRING
#   Named `*.test.sh` under tests/ so `scripts/test.sh` discovers it, and that
#   is exactly the command CI (#16) invokes — so this runs on every PR with no
#   per-test wiring. `scripts/test.sh` itself runs with no `node_modules`
#   present, which keeps this proof faithful. See docs/testing.md.
#
# Run directly:  bash tests/integration/offline-boot.test.sh
# Via the suite: scripts/test.sh tests/integration/offline-boot.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/tests/lib/assert.sh"

# The native bundle entrypoint and the command under test (relative to ROOT,
# mirroring the AC's `node vendor/ynab-mcp/index.cjs`).
BUNDLE_REL="vendor/ynab-mcp/index.cjs"

# A fixed dummy sentinel — NEVER a real token, NEVER read from the Keychain.
# Module resolution is what's under test; the handshake completes before any
# API call, so this value only has to be present, not valid.
SENTINEL='test-sentinel-not-real'

# Safety net only: the bundle exits on stdin EOF in ~1s. A timeout guards
# against a future bundle that hangs instead of booting. `timeout(1)` is not on
# stock macOS, so we use a portable killer-process watchdog rather than depend
# on it.
BOOT_TIMEOUT_S=30

# JSON-RPC 2.0 messages for a minimal MCP handshake over stdio.
INIT_REQ='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"offline-boot-test","version":"1.0.0"}}}'
INITIALIZED_NOTE='{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
TOOLS_LIST_REQ='{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

# Evidence file written only on failure — a generated diagnostic, not committed.
FAILURE_EVIDENCE="$ROOT/tests/integration/offline-boot-failure.txt"

# --- node_modules check (must hold BEFORE we launch) ------------------------
# Walk the FULL Node module-resolution path from the bundle's directory up to
# the filesystem root, reporting the first `node_modules` found. Node's CommonJS
# resolution consults a `node_modules` in EVERY ancestor directory up to `/`, so
# one above the repo root (a parent dir, $HOME, ...) is just as capable of
# letting a non-self-contained bundle resolve a missing dep and turn a green
# boot into a lie. AC #2 requires NONE anywhere on the resolution path, so the
# walk does NOT stop at the repo root — it terminates only when `dirname` stops
# changing (i.e. at `/`). That fails exactly when the proof could be compromised,
# which is what AC #2 wants. ($NODE_PATH and $HOME/.node_modules are separate,
# non-standard resolution inputs and are out of scope for this check.)
_resolution_node_modules() {
  local d="$ROOT/vendor/ynab-mcp" parent
  while :; do
    if [ -d "$d/node_modules" ]; then
      printf '%s\n' "$d/node_modules"
      return 0
    fi
    parent="$(dirname "$d")"
    [ "$parent" = "$d" ] && break   # reached `/` — dirname no longer changes
    d="$parent"
  done
  return 0
}
NM_VIOLATION="$(_resolution_node_modules)"

# --- boot the bundle once and capture the handshake ------------------------
INPUT_FILE="$(mktemp)"
STDOUT_CAP="$(mktemp)"
STDERR_CAP="$(mktemp)"
# Timeout marker: a path DERIVED from an already-unique mktemp'd file, never
# pre-created. The killer writes it iff the timeout fires, so its mere existence
# is the single source of truth for "timed out" — there is no mktemp-then-delete
# window in which the path could be reused (the TOCTOU the security pass flagged).
TIMEOUT_MARKER="$STDOUT_CAP.timedout"
trap 'rm -f "$INPUT_FILE" "$STDOUT_CAP" "$STDERR_CAP" "$TIMEOUT_MARKER"' EXIT

printf '%s\n' "$INIT_REQ" "$INITIALIZED_NOTE" "$TOOLS_LIST_REQ" >"$INPUT_FILE"

BOOT_RC=0
BOOT_TIMED_OUT=0

# stdin from the request file; stdout/stderr split to separate captures so the
# handshake is read STRICTLY from stdout and stderr is only diagnostic.
(
  cd "$ROOT" || exit 127
  YNAB_ACCESS_TOKEN="$SENTINEL" exec node "$BUNDLE_REL"
) <"$INPUT_FILE" >"$STDOUT_CAP" 2>"$STDERR_CAP" &
BOOT_PID=$!

# Killer watchdog: if the bundle is STILL alive at the deadline, record the
# timeout (write the marker) and only THEN SIGKILL it. The `kill -0` guard means
# we never SIGKILL a PID that already exited — closing the race where an
# unconditional `kill -9` could land on a reaped (and possibly reused) PID. On
# the normal (~1s) path the boot exits first and this subshell is killed before
# the sleep returns, so the marker is never written and no kill is attempted.
(
  sleep "$BOOT_TIMEOUT_S"
  if kill -0 "$BOOT_PID" 2>/dev/null; then
    : >"$TIMEOUT_MARKER"
    kill -9 "$BOOT_PID" 2>/dev/null
  fi
) &
KILLER_PID=$!

if wait "$BOOT_PID"; then BOOT_RC=0; else BOOT_RC=$?; fi
kill "$KILLER_PID" 2>/dev/null || true
wait "$KILLER_PID" 2>/dev/null || true

# The marker is the SOLE timeout signal: it exists iff the killer found the boot
# still alive at the deadline and SIGKILLed it.
[ -f "$TIMEOUT_MARKER" ] && BOOT_TIMED_OUT=1

# --- derive assertions from the captured output ----------------------------
# A module-resolution failure is the signal that forces the M1-3 fallback.
MODULE_ERR=0
if grep -qiE 'Cannot find module|MODULE_NOT_FOUND' "$STDERR_CAP" 2>/dev/null; then
  MODULE_ERR=1
fi

# The initialize response must be valid JSON-RPC with a top-level `result`
# (not `error`), proving the handshake completed before any API call.
INIT_RESULT_OK=0
if jq -se '([.[] | select(.id == 1)] | .[0]) as $i
           | (($i | type) == "object")
             and ($i | has("result"))
             and (($i | has("error")) | not)' \
       "$STDOUT_CAP" >/dev/null 2>&1; then
  INIT_RESULT_OK=1
fi

# Native tool names from the tools/list (id 2) response — newline-separated.
TOOL_NAMES=""
if names="$(jq -rs '[.[] | select(.id == 2) | .result.tools[]?.name] | .[]' "$STDOUT_CAP" 2>/dev/null)"; then
  TOOL_NAMES="$names"
fi

# Write evidence on any boot failure so the fallback decision has real data.
if [ "$MODULE_ERR" -eq 1 ] || [ "$BOOT_RC" -ne 0 ] || [ "$BOOT_TIMED_OUT" -eq 1 ]; then
  {
    echo "# offline-boot FAILURE evidence — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Written by tests/integration/offline-boot.test.sh (issue #14)."
    echo "# The vendored bundle did NOT boot cleanly offline. This is the"
    echo "# evidence that forces the M1-3 fallback to be reconsidered."
    echo "boot_exit_code=$BOOT_RC"
    echo "timed_out=$BOOT_TIMED_OUT"
    echo "module_resolution_error=$MODULE_ERR"
    echo
    echo "===== STDOUT ====="
    cat "$STDOUT_CAP"
    echo
    echo "===== STDERR ====="
    cat "$STDERR_CAP"
  } >"$FAILURE_EVIDENCE"
fi

# Surface captured stdout + stderr (only on failure) for debugging — neither is
# asserted on in the happy path. stdout is included so a non-JSON preamble on it
# (e.g. the cause of a jq parse failure on the initialize response) is visible
# rather than swallowed; the parse itself is silenced (a safe false-negative),
# so this is the only place that detail surfaces.
_surface_captures() {
  echo "  --- captured stdout (offline-boot) ---" >&2
  sed 's/^/  | /' "$STDOUT_CAP" >&2 || true
  echo "  --- captured stderr (offline-boot) ---" >&2
  sed 's/^/  | /' "$STDERR_CAP" >&2 || true
  echo "  evidence: $FAILURE_EVIDENCE" >&2
}

# --- tests -----------------------------------------------------------------

test_no_node_modules_on_resolution_path() {
  if [ -n "$NM_VIOLATION" ]; then
    fail "node_modules present on the resolution path ($NM_VIOLATION) — the offline-boot proof is only meaningful with NONE present"
  fi
}

test_initialize_completes_with_jsonrpc_result() {
  if [ "$INIT_RESULT_OK" -ne 1 ]; then
    _surface_captures
    fail "initialize did not return a JSON-RPC result (boot_rc=$BOOT_RC, timed_out=$BOOT_TIMED_OUT) — the MCP never completed the handshake"
  fi
}

test_tools_list_includes_required_native_tools() {
  # Native bundle names (ynab_*); the mcp__plugin_* namespace is applied by
  # Claude Code and is NOT visible in the raw handshake. Without a completed
  # initialize there is no tools/list to validate, so this is a hard failure,
  # not just a diagnostic dump.
  if [ "$INIT_RESULT_OK" -ne 1 ]; then
    _surface_captures
    fail "initialize did not complete, so tools/list could not be validated (boot_rc=$BOOT_RC, timed_out=$BOOT_TIMED_OUT)"
  fi
  # Exact, newline-bounded membership: a tool merely *containing* the name (e.g.
  # ynab_list_budgets_v2) must NOT satisfy the check.
  assert_exact_line "$TOOL_NAMES" "ynab_list_budgets" "tools/list must expose ynab_list_budgets"
  assert_exact_line "$TOOL_NAMES" "ynab_update_transaction" "tools/list must expose ynab_update_transaction"
}

test_no_module_resolution_failure() {
  if [ "$MODULE_ERR" -eq 1 ]; then
    _surface_captures
    fail "module-resolution failure on stderr (Cannot find module / MODULE_NOT_FOUND) — the bundle is NOT self-contained"
  fi
  if [ "$BOOT_TIMED_OUT" -eq 1 ]; then
    _surface_captures
    fail "bundle did not boot within ${BOOT_TIMEOUT_S}s — it hung instead of completing the handshake"
  fi
  if [ "$BOOT_RC" -ne 0 ]; then
    _surface_captures
    fail "bundle exited non-zero (boot_rc=$BOOT_RC) during the offline handshake"
  fi
}

run_tests
