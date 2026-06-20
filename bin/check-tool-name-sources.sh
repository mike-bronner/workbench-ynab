#!/usr/bin/env bash
#
# check-tool-name-sources.sh — enforce the swap-ready single-source-of-truth
# invariant from issue #87 (see docs/mcp-capability-map.md).
#
# Concrete YNAB MCP tool names — mcp__plugin_workbench-ynab_ynab__ynab_<op> —
# may live in ONLY the files on the allowlist below:
#   - skills/protocol/ynab-tools.md   the machine-referenced SSoT (the names)
#   - docs/mcp-capability-map.md      the human-readable contract (the why)
#   - agents/ynab-orchestrator.md     the agent `tools:` frontmatter — Claude
#                                     Code requires literal tool names there; it
#                                     cannot reference a file or glob, and the
#                                     read-only orchestrator cannot use the
#                                     write-inclusive family glob. It wires the
#                                     subset of the SSoT read-tools list the
#                                     planner stub needs and is a deliberate,
#                                     documented swap consumer, not scatter.
#
# Every OTHER surface — any skill, agent, command, hook, bin script, asset,
# doc, README, or JSON config — is scanned. If a concrete name is hard-coded
# anywhere outside the allowlist, an MCP swap becomes a scatter-patch instead of
# a one-file edit — exactly what this layer exists to prevent. This script fails
# the build when that happens.
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

# Files permitted to enumerate concrete tool names. Keep this list tight: every
# entry is a place a swap must touch, so each one is a deliberate, documented
# exception — not a place to scatter new names. Paths are repo-relative.
ALLOWLIST=(
  "skills/protocol/ynab-tools.md"   # the machine-referenced SSoT
  "docs/mcp-capability-map.md"      # the human-readable contract
  "agents/ynab-orchestrator.md"     # agent `tools:` frontmatter (mechanical)
)

# Scan the whole tree — skills, agents, commands, hooks, bin, assets, docs,
# README, JSON config, everything. Exclude the vendored MCP bundle (it
# legitimately defines the names) plus VCS / dependency dirs.
all_hits="$(grep -rlE --binary-files=without-match "$PATTERN" . \
  --exclude-dir=.git \
  --exclude-dir=vendor \
  --exclude-dir=node_modules \
  2>/dev/null | sed 's#^\./##' | sort -u || true)"

# Drop the allowlisted files; whatever remains is a violation.
violations=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  permitted=0
  for ok in "${ALLOWLIST[@]}"; do
    if [ "$f" = "$ok" ]; then permitted=1; break; fi
  done
  [ "$permitted" -eq 0 ] && violations="${violations}${f}"$'\n'
done <<EOF
$all_hits
EOF
violations="$(printf '%s' "$violations" | sed '/^[[:space:]]*$/d')"

if [ -n "$violations" ]; then
  {
    echo "✖ Hard-coded YNAB tool name(s) found outside the permitted files:"
    echo "$violations" | sed 's/^/    /'
    echo
    echo "  Concrete tool names may live ONLY in:"
    printf '    %s\n' "${ALLOWLIST[@]}"
    echo
    echo "  Reference skills/protocol/ynab-tools.md instead of inlining a name."
    echo "  See docs/mcp-capability-map.md for the swap-ready contract."
  } >&2
  exit 1
fi

echo "✓ No YNAB tool names hard-coded outside the permitted files."
