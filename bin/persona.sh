#!/usr/bin/env bash
#
# persona.sh — resolve the configured financial-assistant persona name.
#
# Single source of truth for the persona-name substitution described in
# docs/persona.md. Skills, wrappers, and the report writer call this instead of
# re-implementing the config read, so the "Hobbes" default lives in exactly one
# place and the name is substituted consistently everywhere it appears.
#
# The resolved name is consumed by the SKILL only. It is NEVER forwarded to the
# vendored YNAB MCP — that server receives only the token + package-native env
# (see docs/persona.md, "Boundary").
#
# Usage:
#   bash bin/persona.sh name     # print the resolved persona name (default arg)
#   bash bin/persona.sh          # same as `name`
#
# Config path resolution (override for tests via YNAB_CONFIG_FILE):
#   ~/.claude/plugins/data/workbench-ynab-claude-workbench/config.json
#
# Fallback is total: an absent config file, missing jq, malformed JSON, or an
# absent/null .persona.name all resolve to "Hobbes" with no error and exit 0.

set -u

DEFAULT_PERSONA_NAME="Hobbes"
CONFIG_FILE="${YNAB_CONFIG_FILE:-$HOME/.claude/plugins/data/workbench-ynab-claude-workbench/config.json}"

# Read a jq path from the config, echoing empty on any failure. Mirrors the
# workbench-core hooks/mcp-memory.sh `_cfg` convention: guard the file, guard
# jq, swallow parse errors, let `// empty` collapse a missing field to empty so
# the shell `${VAR:-default}` fallback below takes over.
_cfg() {
  [ -f "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1 \
    && jq -r "$1 // empty" "$CONFIG_FILE" 2>/dev/null
}

persona_name() {
  local name
  name="$(_cfg '.persona.name')"
  printf '%s\n' "${name:-$DEFAULT_PERSONA_NAME}"
}

case "${1:-name}" in
  name) persona_name ;;
  *)
    printf 'persona.sh: unknown subcommand %q (expected: name)\n' "$1" >&2
    exit 2
    ;;
esac
