#!/usr/bin/env bash
#
# check-tool-name-sources.sh — enforce the swap-ready single-source-of-truth
# invariant from issue #87 (see docs/mcp-capability-map.md).
#
# Concrete YNAB MCP tool names — mcp__plugin_workbench-ynab_ynab__ynab_<op> —
# may live in ONLY two files:
#   - skills/protocol/ynab-tools.md   (the machine-referenced SSoT)
#   - docs/mcp-capability-map.md      (the human-readable contract; not scanned)
#
# No other skill, agent, command, or JSON config may hard-code one. If it does,
# an MCP swap becomes a scatter-patch instead of a one-file edit — exactly what
# this layer exists to prevent. This script fails the build when that happens.
#
# Note: the bare prefix (mcp__plugin_workbench-ynab_ynab__) and the family glob
# (mcp__plugin_workbench-ynab_ynab__ynab_*) are intentionally NOT matched — they
# are the documented derivation rule, safe to mention anywhere.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# A concrete tool name: prefix + ynab_ + at least one lowercase/underscore char.
# The trailing [a-z_]+ means the glob ("..._ynab_*") and bare prefix never match.
PATTERN='mcp__plugin_workbench-ynab_ynab__ynab_[a-z_]+'
SSOT='skills/protocol/ynab-tools.md'

# Skill / agent / command source (the SSoT is the one permitted home).
src_hits="$(grep -rElE --binary-files=without-match "$PATTERN" \
  skills agents commands 2>/dev/null | grep -vx "$SSOT" || true)"

# JSON config (plugin.json, config.json, …), excluding the vendored bundle.
cfg_hits="$(grep -rElE --include='*.json' "$PATTERN" . 2>/dev/null \
  | grep -v '^\./vendor/' || true)"

violations="$(printf '%s\n%s\n' "$src_hits" "$cfg_hits" | sed '/^[[:space:]]*$/d' | sort -u)"

if [ -n "$violations" ]; then
  {
    echo "✖ Hard-coded YNAB tool name(s) found outside ${SSOT}:"
    echo "$violations" | sed 's/^/    /'
    echo
    echo "  Reference skills/protocol/ynab-tools.md instead of inlining the name."
    echo "  See docs/mcp-capability-map.md for the swap-ready contract."
  } >&2
  exit 1
fi

echo "✓ No YNAB tool names hard-coded outside ${SSOT}."
