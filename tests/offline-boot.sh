#!/usr/bin/env bash
#
# offline-boot.sh — the offline-bundle-boot proof for the vendored YNAB MCP
# (issue #78). This is the linchpin gate from the vendoring decision: it CONFIRMS
# the committed bundle boots offline, with no node_modules present, exposing the
# expected tool set — an automated test, not a manual hope.
#
# Run it with a single command, given only `node` (and `jq`) on PATH and the
# committed dist bundle:
#
#     bash tests/offline-boot.sh
#
# Exit 0 = every assertion passed; exit 1 = something failed. The same checks are
# invoked by the release workflow (M5-5) via tests/lib/bundle-integrity.sh —
# this script is the thin, human-runnable front door to that shared library.
#
# What it asserts (all from tests/lib/bundle-integrity.sh):
#   * the committed bundle's SHA-256 still matches vendored.json (M5-3);
#   * the bundle boots from a clean, node_modules-free sandbox — index.cjs is the
#     only code path exercised;
#   * a fake YNAB_ACCESS_TOKEN drives the boot; the real token's absence never
#     fails the test;
#   * the process exits 0 and stdout is pure JSON-RPC (no launcher chatter);
#   * initialize returns a valid JSON-RPC result;
#   * tools/list lists at minimum the full required tool set.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=tests/lib/bundle-integrity.sh
. "${SCRIPT_DIR}/lib/bundle-integrity.sh"

echo "Offline-bundle-boot proof for the vendored YNAB MCP (#78)"
echo "  repo: ${REPO_ROOT}"
echo

bi_assert_integrity "${REPO_ROOT}"
status=$?

echo
printf '%d passed, %d failed\n' "${BI_PASS}" "${BI_FAIL}"
exit "${status}"
