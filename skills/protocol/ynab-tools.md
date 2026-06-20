# YNAB tool names — single source of truth

> **This file is the single source of truth for concrete YNAB tool names.**
> Concrete names may appear in only three allowlisted files: this one, the
> human-readable contract
> [`docs/mcp-capability-map.md`](../../docs/mcp-capability-map.md), and the
> orchestrator agent's `tools:` frontmatter
> ([`agents/ynab-orchestrator.md`](../../agents/ynab-orchestrator.md)) — which
> Claude Code requires to hold literal names and which mirrors the read tools
> below. Every other skill, command, hook, and the pre-approval globs reference
> or are generated from this file. A namespace change is an edit here (plus the
> derivation rule in the capability map, and any changed read-tool suffix
> mirrored into the orchestrator). The guard
> [`bin/check-tool-name-sources.sh`](../../bin/check-tool-name-sources.sh)
> enforces that nothing outside the allowlist copies a name.

Read [`docs/mcp-capability-map.md`](../../docs/mcp-capability-map.md) for the
*why*, the namespace derivation rule, the swap procedure, and the runtime
gotchas. This file is the *what*: the names themselves.

## Prefix

```
mcp__plugin_workbench-ynab_ynab__
```

Derived from plugin name `workbench-ynab` + `mcpServers` key `ynab`. Keep the
key `ynab` across a swap to preserve this prefix. See the capability map's
derivation rule.

## Read tools (safe — pre-approved in the read-only phase)

```
mcp__plugin_workbench-ynab_ynab__ynab_list_budgets
mcp__plugin_workbench-ynab_ynab__ynab_list_accounts
mcp__plugin_workbench-ynab_ynab__ynab_list_categories
mcp__plugin_workbench-ynab_ynab__ynab_list_transactions
mcp__plugin_workbench-ynab_ynab__ynab_list_payees
mcp__plugin_workbench-ynab_ynab__ynab_get_month
mcp__plugin_workbench-ynab_ynab__ynab_export_transactions
```

## Write tools (ledger-only — gated, approved in Sprint 4)

```
mcp__plugin_workbench-ynab_ynab__ynab_update_transaction
mcp__plugin_workbench-ynab_ynab__ynab_update_transactions
mcp__plugin_workbench-ynab_ynab__ynab_update_category
mcp__plugin_workbench-ynab_ynab__ynab_create_transaction
mcp__plugin_workbench-ynab_ynab__ynab_create_transactions
mcp__plugin_workbench-ynab_ynab__ynab_delete_transaction
mcp__plugin_workbench-ynab_ynab__ynab_reconcile_account
```

## Pre-approval glob

One glob matches the entire tool family — use it as the source of truth for the
pre-approval config (Sprint 1 read tools, Sprint 4 write tools):

```
mcp__plugin_workbench-ynab_ynab__ynab_*
```

When the read-only and write phases must be split (per the read-only permission
boundary), pre-approve the **read tools** listed above during Sprints 1–3 and
add the **write tools** behind the write-safety guardrail in Sprint 4. The
single glob above is the like-for-like default once write-back is approved.

## Orchestrator tools list

The read-only orchestrator agent's `tools:` allow-list is exactly the **read
tools** above. The orchestrator never holds write tools — write paths run from
the approval-gated `/ynab-apply` command (Sprint 4), not the orchestrator.

## Maintenance

- Change a tool name (or swap the MCP): edit the lists above **and** the
  derivation rule in the capability map, mirror any changed **read-tool** suffix
  into the orchestrator agent's `tools:` frontmatter, then run
  `bin/check-tool-name-sources.sh`.
- Add a logical operation: add it to the capability map table first, then add
  its concrete name here.
- Never paste a `mcp__plugin_workbench-ynab_ynab__ynab_*` name into another
  skill or config file — reference this file instead. The guard script will
  fail the build otherwise.
