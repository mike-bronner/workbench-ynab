# YNAB tool names — single source of truth

> **This file is the single source of truth for concrete YNAB tool names.**
> Every other skill, command, hook, and the pre-approval globs reference or are
> generated from this file, so a namespace or suffix change starts as an edit
> here (see *Maintenance* below for the rest of the sequence).

This file is the **what** — the names themselves. The **why** lives once, in
[`docs/mcp-capability-map.md`](../../docs/mcp-capability-map.md): the namespace
derivation rule, the allowlist of files permitted to hold a concrete name (and
the reason each one is on it, including the orchestrator's `tools:` frontmatter
and this file), the guard
[`bin/check-tool-name-sources.sh`](../../bin/check-tool-name-sources.sh) that
enforces it, the consumer map, the swap procedure, and the runtime gotchas.
Don't restate any of that here.

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
mcp__plugin_workbench-ynab_ynab__ynab_list_scheduled_transactions
mcp__plugin_workbench-ynab_ynab__ynab_get_month
mcp__plugin_workbench-ynab_ynab__ynab_export_transactions
mcp__plugin_workbench-ynab_ynab__ynab_get_transaction
mcp__plugin_workbench-ynab_ynab__ynab_compare_transactions
mcp__plugin_workbench-ynab_ynab__ynab_get_account
mcp__plugin_workbench-ynab_ynab__ynab_get_category
```

`ynab_list_scheduled_transactions` is the read the fetch-once cache uses for the
`scheduled_transactions` resource (**#157**). The 0.26.10 bundle registered no
such tool; the 0.27.1 re-vendor added it, which is what made scheduled
transactions a real cached resource — see
[`docs/ynab-read-path.md`](../../docs/ynab-read-path.md) §1. It is read-only and
matched by the `ynab_list_*` pre-approval glob below.

`ynab_get_transaction` and `ynab_compare_transactions` are reads added for the
Sprint 4 delete-duplicate write path (M4-8): the apply executor re-reads the
victim transaction with `ynab_get_transaction` for drift detection before any
delete, and the dry-run preview may corroborate the duplicate pairing with
`ynab_compare_transactions`. Both are read-only and were verified as registered
tool ids in the vendored bundle. They are **not** wired into the read-only
orchestrator's `tools:` list (the agent carries only the planner's five reads);
they are invoked from the approval-gated apply path, not the orchestrator.

`ynab_get_account` and `ynab_get_category` are the two single-record reads the
apply executor's `readLiveState` seam resolves for drift detection: `get_account`
for the `reconcile` op type's `reconcile_account` sub-action (account
`reconciled_balance` / `cleared_balance` — see
[`skills/reconcile-write-path.md`](../reconcile-write-path.md)) and
`get_category` for `allocate` (that category's `budgeted` for the given month).
Both were verified as registered tool ids in the vendored bundle, and both were
absent from this file until **#247** (that gap, and the mechanical guard now
closing it, are explained in the capability map's *Registered but not adopted*
section). Like
`get_transaction` / `compare_transactions`, both are read-only, both are **not**
wired into the read-only orchestrator's `tools:` list (it stays the planner's
five reads — no planner feature needs a single-account or single-category read),
and both run from the approval-gated apply path.

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
- The three **scheduled-transaction mutations** the 0.27.1 re-vendor added
  (`create` / `update` / `delete`). No write path uses them, and they are money-
  adjacent (a scheduled transaction becomes a real one on its due date), so they
  sit in the guardrail's `DENIED_TOOLS` rather than any allow-list. The read-phase
  globs cannot reach them: `ynab_list_*` and `ynab_get_*` match only the two new
  *reads*, `ynab_list_scheduled_transactions` and `ynab_get_scheduled_transaction`.

Pre-approval is **not** the human-approval gate and never replaces it. Why that
is so, why the delete verb is withheld, why the namespaced prefix is mandatory,
and the exact `~/.claude/settings.json` snippet all live once in the capability
map's *Permission notes*:
[`docs/mcp-capability-map.md`](../../docs/mcp-capability-map.md).

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
`get_month`). The other seven read tools — `list_payees`,
`export_transactions`, `list_scheduled_transactions`, `get_transaction`,
`compare_transactions`, `get_account` and `get_category` — are in the canonical
read set above but are not wired into the agent. `list_payees` and
`export_transactions` widen into the orchestrator only if a future planner
feature needs them. The other five have no place in a read-only planner at all:
`list_scheduled_transactions` feeds the read path's fetch-once forecast cache
(the review skills consume it, not the planner), and `get_transaction`,
`compare_transactions`, `get_account` and `get_category` are drift reads on the
approval-gated apply path.
The orchestrator never holds write tools — write paths run from the
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

- Change a tool name (or swap the MCP): edit the lists above first, then work
  the capability map's *Swap procedure* for everything else it entails (the
  derivation rule, the orchestrator's `tools:` frontmatter, the guard run, the
  verification steps).
- Add a logical operation: add it to the capability map table first, then add
  its concrete name here. The two lists must stay identical as sets —
  `tests/unit/tool-name-ssot-coverage.test.sh` fails when they diverge.
- Re-vendor the MCP: every tool the new bundle registers must end up either in
  the capability map table (and therefore here) or in that map's *Registered but
  not adopted* inventory. The same test asserts that partition.
- Never paste a `mcp__plugin_workbench-ynab_ynab__ynab_*` name into another
  skill or config file — reference this file instead. The guard script will
  fail the build otherwise.
