# YNAB MCP Capability Map

> **Swap-ready indirection layer.** This document is the contract between the
> plugin's skills and the concrete YNAB MCP that backs them. It names the
> *logical* operations the rituals need and maps each to the *concrete*
> namespaced tool the vendored MCP exposes today. When the MCP is swapped
> (the M6-8 bundled-own-MCP spike), the wiring changes **here and in one
> companion file** — not across every skill.

## Why this exists

The locked decision is to keep the rituals **swap-ready** so a future
bundled-own YNAB MCP can replace the third-party
[`@dizzlkheinz/ynab-mcpb`](https://www.npmjs.com/package/@dizzlkheinz/ynab-mcpb)
with minimal churn. Without an indirection layer, skills reference the vendored
MCP's namespaced tools directly. If those names or shapes change on a swap,
every skill, the orchestrator's tools list, and the pre-approval globs must be
hand-edited.

This layer concentrates that wiring in two places:

1. **This map** — the human-readable capability contract and swap procedure.
2. **[`skills/protocol/ynab-tools.md`](../skills/protocol/ynab-tools.md)** — the
   machine-referenced single source of truth for the complete tool-name list.

This is **organizational, not a runtime proxy.** Claude still calls the real
namespaced tools directly. The layer is about *where the names and the
capability contract live* so they are swappable, not about wrapping calls at
runtime.

## Namespace derivation rule

Claude Code namespaces a plugin-provided MCP server's tools as:

```
mcp__plugin_<plugin-name>_<mcpServers-key>__<tool-name>
```

For this plugin the parts are:

| Part | Value | Source |
|---|---|---|
| `<plugin-name>` | `workbench-ynab` | `name` in [`.claude-plugin/plugin.json`](../.claude-plugin/plugin.json) |
| `<mcpServers-key>` | `ynab` | the key under `mcpServers` in `plugin.json` |
| `<tool-name>` | `ynab_<op>` | the tool name the vendored MCP exposes |

Composed, the current prefix is:

```
mcp__plugin_workbench-ynab_ynab__
```

**The `mcpServers` key is the only lever on the prefix.** Renaming the key from
`ynab` to, say, `ledger` shifts every tool name to
`mcp__plugin_workbench-ynab_ledger__…`. Conversely, **keeping the key `ynab`
across a bundle swap preserves the prefix** — so a like-for-like tool set
(same operation suffixes) needs **zero** skill edits. This is the cheapest swap
path and the one the swap procedure below assumes by default.

## Capability map

The 16 logical operations the rituals need, each mapped to its current concrete
namespaced tool. `R` = read (safe, pre-approved in the read-only phase);
`W` = write (ledger-only mutation, gated behind the write-safety guardrail and
approved in Sprint 4). Operations 15–16 were added for the Sprint 4 delete-duplicate
write path (M4-8).

| # | Logical operation | Concrete tool | Kind | What it does |
|---|---|---|---|---|
| 1 | `list_budgets` | `mcp__plugin_workbench-ynab_ynab__ynab_list_budgets` | R | List the YNAB budgets on the account |
| 2 | `list_accounts` | `mcp__plugin_workbench-ynab_ynab__ynab_list_accounts` | R | List accounts within a budget |
| 3 | `list_categories` | `mcp__plugin_workbench-ynab_ynab__ynab_list_categories` | R | List category groups and categories |
| 4 | `list_transactions` | `mcp__plugin_workbench-ynab_ynab__ynab_list_transactions` | R | List transactions (with date / account filters) |
| 5 | `list_payees` | `mcp__plugin_workbench-ynab_ynab__ynab_list_payees` | R | List payees |
| 6 | `get_month` | `mcp__plugin_workbench-ynab_ynab__ynab_get_month` | R | Get a budget month (Ready-to-Assign, age of money, category balances) |
| 7 | `export_transactions` | `mcp__plugin_workbench-ynab_ynab__ynab_export_transactions` | R | Export transactions for reporting |
| 8 | `update_transaction` | `mcp__plugin_workbench-ynab_ynab__ynab_update_transaction` | W | Update a single transaction (e.g. recategorize) |
| 9 | `update_transactions` | `mcp__plugin_workbench-ynab_ynab__ynab_update_transactions` | W | Bulk-update transactions |
| 10 | `update_category` | `mcp__plugin_workbench-ynab_ynab__ynab_update_category` | W | Update a category (e.g. allocate Ready-to-Assign) |
| 11 | `create_transaction` | `mcp__plugin_workbench-ynab_ynab__ynab_create_transaction` | W | Create a single transaction |
| 12 | `create_transactions` | `mcp__plugin_workbench-ynab_ynab__ynab_create_transactions` | W | Bulk-create transactions |
| 13 | `delete_transaction` | `mcp__plugin_workbench-ynab_ynab__ynab_delete_transaction` | W | Delete a transaction (duplicate fix) |
| 14 | `reconcile_account` | `mcp__plugin_workbench-ynab_ynab__ynab_reconcile_account` | W | Reconcile an account to a statement balance |
| 15 | `get_transaction` | `mcp__plugin_workbench-ynab_ynab__ynab_get_transaction` | R | Get one transaction — the M4-8 delete path re-reads the victim for drift detection |
| 16 | `compare_transactions` | `mcp__plugin_workbench-ynab_ynab__ynab_compare_transactions` | R | Compare two transactions — corroborates the duplicate pairing in the M4-8 dry-run preview |

> **None of these move real money.** Write-back is strictly ledger-only
> (categorize / allocate / dedup / reconcile). The plugin never initiates
> transfers or payments — see the write-safety guardrail (Sprint 4).

> **Suffixes confirmed against the vendored bundle.** The vendored MCP
> (`@dizzlkheinz/ynab-mcpb` v0.26.10, in `vendor/ynab-mcp/`) exposes ~30 tools;
> the rituals need the 16 above. All 16 concrete suffixes were verified to be
> registered tool ids in that bundle. On a future re-vendor or MCP swap,
> re-confirm each suffix against the new bundle and correct any drift **here, in
> [`ynab-tools.md`](../skills/protocol/ynab-tools.md), and (for a changed suffix
> the orchestrator actually wires) in the orchestrator's `tools:` list** — the
> three allowlisted files. The guard script (below) proves nothing else has
> copied a name.

## Single source of truth

[`skills/protocol/ynab-tools.md`](../skills/protocol/ynab-tools.md) holds the
**complete, canonical tool-name list** plus the derived pre-approval glob and
orchestrator tools list. When a skill must reference a tool by name, it points
to that file (or copies from it at generation time) rather than embedding the
name inline.

The invariant is enforced by
[`bin/check-tool-name-sources.sh`](../bin/check-tool-name-sources.sh), which
scans the **entire tree** — every skill, agent, command, hook, `bin/` script,
asset, doc, README, and JSON config (the vendored `vendor/` bundle and VCS /
dependency dirs excepted) — and fails the build if a concrete
`mcp__plugin_workbench-ynab_ynab__ynab_*` tool name appears outside an explicit
allowlist. The allowlist is exactly these files:

| Permitted file | Role |
|---|---|
| [`skills/protocol/ynab-tools.md`](../skills/protocol/ynab-tools.md) | the machine-referenced SSoT — the names themselves |
| `docs/mcp-capability-map.md` (this file) | the human-readable contract — the *why* |
| [`agents/ynab-orchestrator.md`](../agents/ynab-orchestrator.md) | the read-only orchestrator's `tools:` frontmatter — Claude Code requires literal names there (no file reference, no glob, and a read-only agent must not use the write-inclusive family glob), so it wires the subset of the SSoT read tools the planner stub needs (Sprint 3 widens it to the full read set) and is allowlisted as a deliberate, documented swap consumer |

Everywhere else, a hard-coded name fails the guard. The bare prefix
(`mcp__plugin_workbench-ynab_ynab__`) and the family glob
(`mcp__plugin_workbench-ynab_ynab__ynab_*`) are the documented derivation rule
and are safe to mention anywhere — the guard never flags them. The guard ships
with a self-test,
[`tests/check-tool-name-sources.test.sh`](../tests/check-tool-name-sources.test.sh),
which proves it catches a planted name on every scanned surface, honours the
allowlist, and passes on a clean tree.

## Consumers — everything points back here

These are the files that would otherwise scatter raw tool names. Each
references the source of truth so a namespace change is a **one-file edit**:

| Consumer | Lands in | Source of truth |
|---|---|---|
| Pre-approval glob (read tools, then write tools) | Sprint 1 setup / Sprint 4 write paths | the glob defined in [`ynab-tools.md`](../skills/protocol/ynab-tools.md) |
| Orchestrator agent tools list | Sprint 1 orchestrator stub → fleshed in Sprint 3 | the tools list in [`ynab-tools.md`](../skills/protocol/ynab-tools.md) |
| Review / write-back skills (prose) | Sprints 3–4 | this map's logical operation names |

Because a single glob — `mcp__plugin_workbench-ynab_ynab__ynab_*` — matches the
entire tool family, the pre-approval config and the orchestrator tools list can
both be regenerated from `ynab-tools.md` mechanically. A namespace change edits
the derivation rule in this map and the list in `ynab-tools.md`; the consumers
inherit it.

## Swap procedure

To replace the vendored MCP (e.g. with the bundled-own MCP from M6-8):

1. **Change the launcher target.** Repoint `mcpServers.ynab` in
   [`.claude-plugin/plugin.json`](../.claude-plugin/plugin.json) — and the
   launcher it invokes, `bin/launcher.sh` (a Sprint 1 deliverable not yet
   landed; `plugin.json` already points `mcpServers.ynab` at it) — at the new
   MCP. **Keep the `mcpServers` key `ynab`** to preserve the
   `mcp__plugin_workbench-ynab_ynab__` prefix.
2. **Regenerate the tool-name list** in
   [`ynab-tools.md`](../skills/protocol/ynab-tools.md) from this map — update any
   suffix that the new MCP names differently, mirror any changed suffix **the
   orchestrator wires** into its `tools:` frontmatter (the one other allowlisted
   consumer that holds literal names), then run
   [`bin/check-tool-name-sources.sh`](../bin/check-tool-name-sources.sh) to
   confirm nothing else has copied a stale name.
3. **Run the offline-boot verification** (Sprint 1 linchpin) to confirm the new
   MCP launches and handshakes over stdio.
4. **Run the test suite** — the golden-snapshot review test, the guard script,
   and the guard's self-test
   ([`tests/check-tool-name-sources.test.sh`](../tests/check-tool-name-sources.test.sh))
   must pass.

**If the new MCP keeps the same `ynab` key *and* the same operation suffixes,
steps 2's edits are empty and no skill changes at all are required** — the swap
is a launcher-target change plus verification.

## Runtime gotchas — these survive a swap

These two facts are easy to lose across a swap. Keep them here so they don't:

- **(a) The prefix is always `mcp__plugin_workbench-ynab_ynab__*` — never
  `mcp__ynab__*`.** Plugin-provided MCP servers are namespaced with the
  `mcp__plugin_<plugin>_<key>__` form, not the bare `mcp__<key>__` form. Tools
  written or referenced as `mcp__ynab__…` will not resolve.
- **(b) The launcher must log exclusively to stderr.** `stdout` is the
  JSON-RPC channel between Claude Code and the MCP — any stray `echo` to stdout
  corrupts the protocol and breaks the handshake. Mirror the discipline in
  `workbench-core`'s `hooks/mcp-memory.sh`: every diagnostic goes to `stderr`
  (`>&2`), `stdout` carries only protocol frames.

## Config split — token vs. config

Two channels, kept separate (mirrors `mcp-memory.sh` discipline):

- **Skills read budget / tax / profile configuration from `config.json`**
  (the umbrella config + loader, Sprint 1). Logical settings live here.
- **The MCP receives only the Keychain token and native env.** The launcher
  pulls the YNAB Personal Access Token from the macOS Keychain into
  `YNAB_ACCESS_TOKEN` and `exec`s `node`; it passes **no** plugin config to the
  MCP. The token never lands in `config.json`, never on disk, never in a log.

Keeping these split means a swap touches the launcher's token/env handoff and
the tool names — never the skills' configuration surface.
