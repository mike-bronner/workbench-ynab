#!/usr/bin/env bash
#
# bin/config.sh — sourceable config loader for workbench-ynab SKILLS and commands.
#
# WHAT THIS IS
#   A shared helper that reads the user's out-of-repo configuration so the config
#   shape is defined once and not re-invented per skill. It mirrors the `_cfg()`
#   jq idiom from workbench-core/hooks/mcp-memory.sh (lines 73-83).
#
# WHO SOURCES THIS
#   Plugin SKILLS and slash-commands that need user configuration (budget name,
#   tax profile, persona, report paths, mapping rules, …).
#
# WHO MUST NOT SOURCE THIS
#   bin/launcher.sh and the vendored YNAB MCP deliberately do NOT read this
#   config — the launcher resolves only the Keychain token before exec'ing node.
#   Keeping the MCP launch path config-free is intentional; do not source this
#   file from the launcher. See docs/config-loader.md.
#
# WHY IT IS SOURCED, NOT EXECUTED
#   This file only DEFINES functions and one path variable. It never runs
#   `set -e`/`set -u` or any command with side effects at load time, so sourcing
#   it cannot alter or abort the caller's shell.
#
# USAGE
#   source "${CLAUDE_PLUGIN_ROOT}/bin/config.sh"
#   _require_config || exit 1                 # fail fast if unconfigured
#   budget="$(_cfg '.budget.name')"
#   persona="$(_cfg '.persona.name')"
#   persona="${persona:-$DEFAULT_PERSONA}"    # caller applies its own default
#
# See docs/config-loader.md for the full contract and a worked example per key.

# Resolve the config path. The plugin-data dir survives plugin updates, so it is
# the single source of truth for configuration. There is NO fallback to a
# user-specific path: if the file is absent the user must run /workbench-ynab:setup.
#
# YNAB_CONFIG_FILE may be pre-set by the caller (used by the test harness to point
# at a sandbox fixture); when unset it resolves to the canonical plugin-data path.
YNAB_CONFIG_FILE="${YNAB_CONFIG_FILE:-$HOME/.claude/plugins/data/workbench-ynab-claude-workbench/config.json}"

# _cfg '<jq-path>'
#   Echo the value at the given jq path, or nothing when the file is missing, jq
#   is unavailable, or the field is absent/null. Same shape as mcp-memory.sh:
#   `jq -r '<path> // empty'`. Callers apply their own defaults at the call site
#   with `"${value:-default}"` — this function never bakes defaults in, so no
#   owner-specific value is ever hardcoded here.
_cfg() {
  [ -f "$YNAB_CONFIG_FILE" ] && command -v jq >/dev/null 2>&1 \
    && jq -r "$1 // empty" "$YNAB_CONFIG_FILE" 2>/dev/null
}

# _require_config
#   Guard for callers that cannot proceed without configuration. Emits a clear,
#   actionable message to stderr and returns non-zero when the config file is
#   missing or jq is unavailable. Call it once before reading any fields.
_require_config() {
  if [ ! -f "$YNAB_CONFIG_FILE" ]; then
    echo "workbench-ynab: config not found at $YNAB_CONFIG_FILE" 1>&2
    echo "workbench-ynab: run /workbench-ynab:setup to create it." 1>&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "workbench-ynab: jq is required to read the config but was not found on PATH." 1>&2
    echo "workbench-ynab: install jq (e.g. 'brew install jq'), then re-run /workbench-ynab:setup." 1>&2
    return 1
  fi
  return 0
}
