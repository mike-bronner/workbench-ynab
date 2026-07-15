#!/usr/bin/env bash
#
# bin/node-floor.sh — enforce the minimum supported Node major (issue #3).
#
# The vendored bundle (vendor/ynab-mcp/index.cjs) runs on system `node`, and a
# runtime older than the bundle's needs dies cryptically mid-boot. This check
# turns that into ONE actionable error, up front, in both entry paths:
#   * bin/launcher.sh — scheduled runs bypass interactive setup, so the
#     launcher fails fast before exec'ing node on the bundle;
#   * /workbench-ynab:setup Step 1a — the interactive prereq check.
#
# CANONICAL FLOOR VALUE
#   vendor/ynab-mcp/NODE_VERSION — a single bare Node major (e.g. `18`), pinned
#   next to the bundle it describes. It is derived from the bundle's dependency
#   chain (the strongest declared constraint: @modelcontextprotocol/sdk's
#   `engines.node >=18`) and confirmed by booting the vendored index.cjs on
#   candidate majors; bin/revendor.sh re-derives it on every bundle bump from
#   the incoming package's OWN engines.node only (transitive constraints are
#   invisible in a tarball — CI's floor lane, which boots the bundle on exactly
#   this major, is the backstop that catches those; see docs/ci.md).
#   tests/unit/node-floor.test.sh keeps README + ci.yml in sync with it.
#
# CONTRACT (asserted by tests/unit/node-floor.test.sh + tests/launcher.test.sh)
#   * PATH `node` major >= floor  → exit 0, no output at all.
#   * below the floor / unparsable → exit 1 with one actionable line on STDERR.
#   * NEVER a byte on stdout — in the launcher path stdout is the MCP JSON-RPC
#     channel, and a single stray byte corrupts the handshake.
#
# Deliberately bash-builtin-only (no tr/sed/awk): the launcher tests run this
# on a minimal stubbed PATH, and the fewer externals the check needs, the fewer
# ways it can fail for reasons that have nothing to do with the Node version.
set -euo pipefail

_err() { echo "ynab-mcp: $*" 1>&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOOR_FILE="${SCRIPT_DIR}/../vendor/ynab-mcp/NODE_VERSION"

if [ ! -f "$FLOOR_FILE" ]; then
  _err "Node floor marker missing (vendor/ynab-mcp/NODE_VERSION) — the plugin install is incomplete; reinstall workbench-ynab."
  exit 1
fi

# Read the floor with builtins only; strip whitespace (trailing newline, stray
# spaces/tabs/CRs) via parameter expansion so no external tool is needed.
IFS= read -r NODE_FLOOR < "$FLOOR_FILE" || true
NODE_FLOOR="${NODE_FLOOR//[$' \t\r']/}"
case "$NODE_FLOOR" in
  '' | *[!0-9]*)
    _err "Node floor marker (vendor/ynab-mcp/NODE_VERSION) is not a bare Node major — reinstall workbench-ynab."
    exit 1
    ;;
esac

# `node --version` prints e.g. `v18.20.8`; the major is what the floor pins.
# The `|| true` keeps `set -e` from aborting before the friendly message when
# node itself fails; captured via substitution so nothing reaches our stdout.
NODE_VERSION_RAW="$(node --version 2>/dev/null || true)"
NODE_MAJOR="${NODE_VERSION_RAW#v}"
NODE_MAJOR="${NODE_MAJOR%%.*}"
case "$NODE_MAJOR" in
  '' | *[!0-9]*)
    _err "could not parse 'node --version' output ('${NODE_VERSION_RAW}') — ensure a working Node >= ${NODE_FLOOR} is on PATH."
    exit 1
    ;;
esac

if [ "$NODE_MAJOR" -lt "$NODE_FLOOR" ]; then
  _err "workbench-ynab requires Node >= ${NODE_FLOOR}; you have ${NODE_VERSION_RAW} — upgrade via nvm ('nvm install ${NODE_FLOOR}') or Homebrew ('brew upgrade node'), then retry."
  exit 1
fi
