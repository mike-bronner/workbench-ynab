#!/usr/bin/env bash
#
# tests/unit/node-floor.test.sh — covers bin/node-floor.sh (issue #3), the
# single enforcement point for the pinned minimum Node major, plus the sync
# guards that keep every documented copy of the floor honest.
#
# FUNCTIONAL (a stubbed `node` first on PATH, so no real runtime is consulted):
#   * below the floor → exit non-zero, the actionable "workbench-ynab requires
#     Node >= X; you have Y — upgrade via …" line on STDERR, stdout EMPTY (in
#     the launcher path stdout is the MCP JSON-RPC channel — one stray byte
#     corrupts the handshake). This is the setup-prereq contract (AC 5): the
#     /workbench-ynab:setup Step 1a check IS this script (see
#     tests/unit/setup-command.test.sh for the structural half); the launcher
#     path gets the same stub treatment in tests/launcher.test.sh (AC 6).
#   * at / above the floor → exit 0 and completely silent.
#   * unparsable `node --version` output → exit non-zero, stderr only.
#
# SYNC (AC 8 — a drifted copy of the floor is a CI failure):
#   * vendor/ynab-mcp/NODE_VERSION is a single bare integer (the canonical
#     value everything else derives from).
#   * .github/workflows/ci.yml's test-job matrix pins that exact major.
#   * README.md documents that exact floor ("Node >= X").
#
# Harness convention (issue #4): raw bash, sources tests/lib/assert.sh,
# test_* functions, run_tests. scripts/test.sh auto-discovers this file.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/assert.sh"

CHECK="$REPO_ROOT/bin/node-floor.sh"
FLOOR_FILE="$REPO_ROOT/vendor/ynab-mcp/NODE_VERSION"
FLOOR="$(tr -d '[:space:]' < "$FLOOR_FILE")"

# run_with_node_version <version-output> — run the check with a stub `node`
# first on PATH whose --version prints <version-output>. Captures stdout,
# stderr, and rc into RUN_OUT / RUN_ERR / RUN_RC.
run_with_node_version() {
  local stubdir
  stubdir="$(mktemp -d)"
  printf '#!/usr/bin/env bash\necho "%s"\n' "$1" > "$stubdir/node"
  chmod +x "$stubdir/node"
  local errfile="$stubdir/err"
  set +e
  RUN_OUT="$(PATH="$stubdir:$PATH" bash "$CHECK" 2>"$errfile")"
  RUN_RC=$?
  set -e
  RUN_ERR="$(cat "$errfile")"
  rm -rf "$stubdir"
}

# --- functional: the version-gate contract ----------------------------------

test_below_floor_fails_stderr_only() {
  local below="v$((FLOOR - 1)).9.9"
  run_with_node_version "$below"
  assert_eq 1 "$RUN_RC" "a below-floor node must exit 1"
  assert_eq "" "$RUN_OUT" "stdout must stay EMPTY on failure (MCP JSON-RPC channel)"
  assert_contains "$RUN_ERR" "workbench-ynab requires Node >= $FLOOR" \
    "stderr must state the required floor"
  assert_contains "$RUN_ERR" "you have $below" \
    "stderr must name the offending installed version"
  assert_contains "$RUN_ERR" "upgrade via" \
    "stderr must carry actionable upgrade guidance"
}

test_at_floor_passes_silently() {
  run_with_node_version "v${FLOOR}.0.0"
  assert_eq 0 "$RUN_RC" "a node exactly at the floor must pass"
  assert_eq "" "$RUN_OUT" "no stdout on success"
  assert_eq "" "$RUN_ERR" "no stderr on success"
}

test_above_floor_passes_silently() {
  run_with_node_version "v$((FLOOR + 10)).1.2"
  assert_eq 0 "$RUN_RC" "a node above the floor must pass"
  assert_eq "" "$RUN_OUT" "no stdout on success"
  assert_eq "" "$RUN_ERR" "no stderr on success"
}

test_unparsable_version_fails_stderr_only() {
  run_with_node_version "flooble"
  assert_eq 1 "$RUN_RC" "an unparsable node --version must exit 1"
  assert_eq "" "$RUN_OUT" "stdout must stay EMPTY on the parse-failure path"
  assert_contains "$RUN_ERR" "could not parse" \
    "stderr must name the parse failure"
}

# --- sync: every copy of the floor agrees with the canonical file -----------

test_floor_file_is_a_bare_integer() {
  case "$FLOOR" in
    '' | *[!0-9]*) fail "vendor/ynab-mcp/NODE_VERSION must hold a single bare Node major, got: [$FLOOR]" ;;
  esac
}

test_ci_matrix_pins_the_floor() {
  # The test job's matrix must carry the canonical floor as a quoted entry —
  # a re-derived floor that never reaches ci.yml would silently un-gate the
  # oldest supported major.
  grep -E "node-version:.*'$FLOOR'" "$REPO_ROOT/.github/workflows/ci.yml" >/dev/null \
    || fail "ci.yml test-job matrix does not pin the canonical Node floor '$FLOOR'"
}

test_readme_documents_the_floor() {
  assert_contains "$(cat "$REPO_ROOT/README.md")" "Node >= $FLOOR" \
    "README Prerequisites must state the canonical floor explicitly"
}

test_check_is_executable_and_strict() {
  [ -x "$CHECK" ] || fail "bin/node-floor.sh must have its executable bit set"
  assert_contains \
    "$(grep -vE '^[[:space:]]*#' "$CHECK" | grep -vE '^[[:space:]]*$' | head -1)" \
    "set -euo pipefail" "first non-comment line is the strict-mode set"
}

run_tests
