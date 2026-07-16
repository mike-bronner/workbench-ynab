# YNAB tool names — single source of truth

> **This file is the single source of truth for concrete YNAB tool names.**
> Concrete names may appear in only three allowlisted files: this one, the
> human-readable contract
> [`docs/mcp-capability-map.md`](../../docs/mcp-capability-map.md), and the
> orchestrator agent's `tools:` frontmatter
> ([`agents/ynab-orchestrator.md`](../../agents/ynab-orchestrator.md)) — which
> Claude Code requires to hold literal names and which wires the subset of the
> read tools below that the planner currently needs. Every other skill,
> command, hook, and the pre-approval globs reference or are generated from this
> file. A namespace change is an edit here (plus the derivation rule in the
> capability map, and any changed suffix the orchestrator wires mirrored into
> it). The guard
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
mcp__plugin_workbench-ynab_ynab__ynab_get_transaction
mcp__plugin_workbench-ynab_ynab__ynab_compare_transactions
```

`ynab_get_transaction` and `ynab_compare_transactions` are reads added for the
Sprint 4 delete-duplicate write path (M4-8): the apply executor re-reads the
victim transaction with `ynab_get_transaction` for drift detection before any
delete, and the dry-run preview may corroborate the duplicate pairing with
`ynab_compare_transactions`. Both are read-only and were verified as registered
tool ids in the vendored bundle. They are **not** wired into the read-only
orchestrator's `tools:` list (the agent carries only the planner's five reads);
they are invoked from the approval-gated apply path, not the orchestrator.

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

## Pre-approval globs

Pre-approval removes Claude Code's per-call permission dialog for a matched
tool. It is **phase-split and scoped tightly** — never blanket the whole family.
The `ynab_*` family glob (see the next section) would sweep in the
ledger-*deleting* `delete_transaction` verb, which must always keep its own
strong-confirmation path (**M4-8**), so it is never used for pre-approval.

### Read phase (Sprints 1–3)

Setup (Step 5) pre-approves the read tools listed under **## Read tools** above.
Two globs cover the bulk of that read surface:

```
mcp__plugin_workbench-ynab_ynab__ynab_list_*
mcp__plugin_workbench-ynab_ynab__ynab_get_*
```

`ynab_export_transactions` and `ynab_compare_transactions` are the two reads
those globs don't match; setup seeds them by their explicit names from the read
list above.

### Write phase (Sprint 4 — M4)

Pre-approve **exactly these four** ledger-write tools, each by its full name —
never the `ynab_*` family glob:

```
mcp__plugin_workbench-ynab_ynab__ynab_update_transaction
mcp__plugin_workbench-ynab_ynab__ynab_update_transactions
mcp__plugin_workbench-ynab_ynab__ynab_update_category
mcp__plugin_workbench-ynab_ynab__ynab_reconcile_account
```

**Deliberately excluded from every pre-approval list:**

- `mcp__plugin_workbench-ynab_ynab__ynab_delete_transaction` — the destructive
  verb keeps its own strong-confirmation + dry-run preview path (**M4-8**).
  Never add it to a pre-approval list: do so and a duplicate-fix delete would
  run without its confirmation gate.
- `mcp__plugin_workbench-ynab_ynab__ynab_create_transaction` and
  `mcp__plugin_workbench-ynab_ynab__ynab_create_transactions` — no M4 write path
  creates transactions, so they are not pre-approved either.

The human-approval gate for a write **batch** is the `/ynab-apply` command
(**M4-5**) plus the write-safety guardrail — *not* a per-call Claude Code
dialog. Pre-approving these four tools removes the now-*redundant* per-call
prompt; it does not remove the approval gate. See
[`docs/mcp-capability-map.md`](../../docs/mcp-capability-map.md) for the exact
`~/.claude/settings.json` snippet and the permission notes.

## Family glob (schema loading — NOT pre-approval)

One glob matches the entire tool family:

```
mcp__plugin_workbench-ynab_ynab__ynab_*
```

Use it where the whole family must be *named* at once **without** granting
standing permission — e.g. loading deferred tool schemas with `ToolSearch` from
a write path. It is **not** the pre-approval default: pre-approval is the tight,
phase-split set above, so the delete verb is never blanket-approved.

## Orchestrator tools list

The read-only orchestrator agent's `tools:` allow-list is a **subset** of the
**read tools** above: the planner currently wires the five reads it needs
(`list_budgets`, `list_accounts`, `list_categories`, `list_transactions`,
`get_month`). The remaining two read tools — `list_payees` and
`export_transactions` — are in the canonical read set above but are not
wired into the agent; they widen into the orchestrator only if a future planner
feature needs them. The orchestrator never holds write tools — write paths run from the
approval-gated `/ynab-apply` command (Sprint 4), not the orchestrator.

## Port wrappers must throw on failure — check `result.isError`

Every wrapper that hands a YNAB tool call to the apply executor's injected ports
(`readLiveState`, `applyOp`, `authPreflight`, and the bulk-dispatch `bulkApplyOp` —
see [`skills/apply-executor.md`](../apply-executor.md)) **must inspect
`result.isError` and `throw`** before returning. The vendored MCP surfaces auth / rate-limit / 5xx
failures as a **resolved** `{ isError: true, … }` result, not a rejected promise —
and the executor's error-classification and auth-abort machinery only runs inside a
`catch`. A wrapper that returns the MCP result verbatim fails **open**: a 401
preflight would silently "pass" and a mid-batch 401 would look like a success.
Rethrow the structured error (preserving the HTTP status) so the executor can
classify it into `error_class` / `applied_state`.

## Maintenance

- Change a tool name (or swap the MCP): edit the lists above **and** the
  derivation rule in the capability map, mirror any changed suffix that the
  orchestrator wires into its `tools:` frontmatter (it carries the five reads
  above, not `list_payees` / `export_transactions` until Sprint 3), then run
  `bin/check-tool-name-sources.sh`.
- Add a logical operation: add it to the capability map table first, then add
  its concrete name here.
- Never paste a `mcp__plugin_workbench-ynab_ynab__ynab_*` name into another
  skill or config file — reference this file instead. The guard script will
  fail the build otherwise.
