---
name: ynab-protocol
description: Swap-ready protocol for calling the vendored YNAB MCP. Use whenever a workbench-ynab skill, the orchestrator, or pre-approval config needs a YNAB MCP tool name — never hard-code a tool name; resolve it from this protocol's single source of truth so an MCP swap stays a one-file edit.
---

# YNAB MCP protocol

This skill is the swap-ready indirection layer between workbench-ynab's skills
and whatever concrete YNAB MCP backs them. It exists so the rituals reference
*logical operations*, and the concrete `mcp__plugin_workbench-ynab_ynab__*`
tool names live in exactly one place.

## How to use it

- **Need a tool name?** Read
  [`ynab-tools.md`](ynab-tools.md) — the single source of truth for the
  complete tool-name list, the pre-approval glob, and the orchestrator tools
  list. Reference it; do not copy a name into your own skill or config.
- **Need the contract, the namespace derivation rule, the swap procedure, or
  the runtime gotchas?** Read
  [`docs/mcp-capability-map.md`](../../docs/mcp-capability-map.md).

## The one rule

Never hard-code a raw `mcp__plugin_workbench-ynab_ynab__ynab_*` tool name in a
skill, command, hook, asset, or config. Centralize every reference in
`ynab-tools.md` so swapping the MCP stays a one-file edit.
`bin/check-tool-name-sources.sh` enforces this across the whole tree, with a
narrow allowlist for the two docs and the orchestrator agent's `tools:`
frontmatter (which Claude Code requires to hold literal names). See
[`docs/mcp-capability-map.md`](../../docs/mcp-capability-map.md) for the full
allowlist and rationale.
