#!/usr/bin/env bash
#
# bin/launcher.sh — boot the vendored YNAB MCP server for the workbench-ynab plugin.
#
# Invoked by .claude-plugin/plugin.json's mcpServers.ynab entry as
#   bash ${CLAUDE_PLUGIN_ROOT}/bin/launcher.sh
# (no extra args — unlike the bujo scribe launcher, this MCP takes no subcommand).
# Modeled on workbench-core/hooks/mcp-memory.sh: resolve env at server-start time
# so plugin updates never clobber MCP configuration, and keep stdout pristine.
#
# ── Config split (read this before adding anything here) ──────────────────────
# This launcher injects ONLY the access token — read from the macOS Keychain and
# exported as YNAB_ACCESS_TOKEN, the package-native env the third-party MCP
# understands. ALL budget / tax / profile / persona configuration is read by the
# SKILLS from config.json (see bin/config.sh); the vendored YNAB MCP never sees
# our config.json and cannot read it. Do NOT source bin/config.sh here, and do
# NOT pass any plugin config to the MCP — keeping the launch path config-free is
# intentional. See docs/config-loader.md and the header of bin/config.sh.
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# stdout is the MCP stdio channel (JSON-RPC). Every byte of diagnostic output
# MUST go to stderr — a single stray stdout line corrupts the MCP handshake.
# Route every diagnostic through _log; never `echo` to stdout in this script.
_log() { echo "ynab-mcp: $*" 1>&2; }

# Resolve paths relative to this script's directory so they hold regardless of
# the caller's working directory and contain no hardcoded absolute paths.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Entry point: the bin/ynab-mcp shim (M1-3) — a stable wrapper that requires the
# frozen vendored bundle (vendor/ynab-mcp/index.cjs). Exec'ing the shim, rather
# than the bundle's internal main, is the shim's documented contract, so the
# launcher never has to know the bundle's internal layout.
BUNDLE="${SCRIPT_DIR}/ynab-mcp"

# Read the access token from the Keychain. The trailing `|| true` keeps `set -e`
# from aborting on `security`'s not-found exit status BEFORE the friendly message
# below can run; stderr from `security` is suppressed so a miss is reported by us,
# not by the tool. The token value is never echoed or logged anywhere — not even
# to stderr.
TOKEN="$(security find-generic-password -s "ynab-mcp" -a "access-token" -w 2>/dev/null || true)"

# Treat a whitespace-only Keychain entry as missing, mirroring bin/persona.sh's
# _trim convention (a "   " value is not a token, the contract is "non-empty"):
# strip every whitespace char from a throwaway copy and test THAT for emptiness.
# $TOKEN itself is left untouched, so a legitimate token is exported exactly as
# the Keychain stored it — only the all-whitespace case is reclassified as absent.
if [ -z "${TOKEN//[[:space:]]/}" ]; then
  _log "No YNAB token in Keychain. Run /workbench-ynab:setup to store it."
  exit 1
fi

# system node must be on PATH to run the bundle.
if ! command -v node >/dev/null 2>&1; then
  _log "node not found on PATH. Install Node.js (e.g. 'brew install node'), then restart Claude Code."
  exit 1
fi

# Enforce the pinned minimum Node major (issue #3): scheduled runs bypass
# interactive setup, so the launcher must fail fast — STDERR only, non-zero
# exit, not a byte on the JSON-RPC stdout channel — instead of letting the
# bundle die cryptically under an unsupported Node. bin/node-floor.sh owns the
# floor read + comparison (canonical value: vendor/ynab-mcp/NODE_VERSION) and
# writes its one actionable line to stderr itself.
bash "${SCRIPT_DIR}/node-floor.sh" || exit 1

# Inject only the package-native token env, then hand off. exec replaces this
# shell with node so Claude Code's MCP stop signal reaches the server directly
# and signals propagate cleanly.
export YNAB_ACCESS_TOKEN="$TOKEN"
exec node "$BUNDLE"
