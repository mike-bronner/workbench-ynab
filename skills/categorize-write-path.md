---
name: categorize-write-path
description: The M4-6 categorize / recategorize write path — the first concrete write path that plugs into the M4-4 apply executor. Given `categorize` operations from a validated, guardrail-passed change-set (M4-1 / M4-2), it sets the proposed category_id on each target transaction via the namespaced YNAB update-transaction tools, under approval and dry-run by default. A dumb, safe applier: it changes ONLY the category field — never payee, account, amount, date, or a transfer payee. Recategorization and first-time categorization share one code path; only the dry-run narrative differs.
---

# Categorize / Recategorize Write Path — workbench-ynab write-back (M4-6)

The most common YNAB chore is assigning categories to uncategorized transactions
and fixing miscategorized ones (the review's section 1 *Transaction
Classification* and section 4 *Uncategorized Transactions*). This write path turns
those review findings into applied `categorize` operations — under approval, never
autonomously.

It is the first concrete consumer of the **M4-4 apply executor**
([`skills/apply-executor.md`](apply-executor.md)): it supplies the `categorize`
op-type → tool registration and the categorize-specific apply logic, and reuses
the executor's `STATUS` result contract. The importable module is
[`assets/categorize-handler.js`](../assets/categorize-handler.js).

## A dumb, safe applier — field isolation

The handler changes **only** the category. The single-transaction update payload
carries `category_id` plus the `budget_id` / `transaction_id` the flat YNAB tool
needs for addressing — **never** `payee_id`, `account_id`, `amount`, `date`, or a
`transfer_account_id`, even when those appear in an op's `before` / `after`
snapshots. (Setting a transfer payee would turn a transaction into a real money
movement; the M4-2 guardrail blocks that, and this handler never attempts it.) The
bulk per-entry shape is likewise just `{ id, category_id }`.

Recategorization (overwriting an existing category) and first-time categorization
(an uncategorized transaction) flow through the **same** code path; only the
dry-run narrative wording differs. Category choice and tax-awareness live upstream
in the proposal (M4-10 / M3 review), not here.

## Dry-run is the default

`dryRun` defaults to **`true`** — it produces a per-op `before → after` category
diff (old id + name → new id + name) and calls **no** mutating tool. Real apply
happens only when the caller passes an explicit `dryRun: false`, which the M4-5
approval command does only after the human approves the batch.

## Bulk-preferring dispatch, with a documented fallback

For a real apply of ≥2 resolvable ops, the handler **prefers a single bulk
`ynab_update_transactions` call** to minimize round-trips. It falls back to
per-transaction `ynab_update_transaction` calls when the bulk call shape does not
fit: (a) fewer than 2 ops, (b) an op can't form a `{ id, category_id }` entry or
the batch spans multiple budgets, or (c) the bulk tool rejects the category-only
batch shape at runtime — each op is then retried individually. Retrying is safe
because a categorize write is **idempotent** (re-setting the same category is a
no-op-equivalent, never money movement).

## Namespaced tools only — resolved, never hard-coded

The write tool names are resolved from the guardrail's exported `ALLOWED_TOOLS` by
suffix, so no concrete `mcp__plugin_workbench-ynab_ynab__*` name lives in the
handler (the swap-ready single-source-of-truth invariant, issue #87). Names trace
to [`skills/protocol/ynab-tools.md`](protocol/ynab-tools.md); bare `mcp__ynab__*`
names are never produced.

## Injected ports (agent runtime)

Like the executor, the handler holds no MCP coupling — the caller wires:

- **`callTool(toolName, payload)`** — the mutating dispatch (real apply only).
- **`listCategories(budgetId)`** — read-only name→id resolution, used only when an
  op's `after.category_id` is absent. The proposal (M4-10) **should** pre-resolve
  ids so this lookup never runs; an unresolvable name returns an `error` result
  (never a thrown exception).
- **`toolSearch(names)`** — a `ToolSearch` select that loads the deferred YNAB tool
  schemas before the first MCP call. An `InputValidationError` means the schema is
  not loaded yet (**not** a server outage) and is retried with boot patience.

## The result contract

Each per-op result reuses the executor's `STATUS` (`applied` / `skipped-stale` /
`blocked` / `error`), extended with `transaction_id`, `before`, `after`, and the
`dry_run` flag the M4-5 command renders.

## Tests

Unit tests live at
[`assets/test/categorize-handler.test.js`](../assets/test/categorize-handler.test.js)
and run on Node's built-in runner. Because the handler `require`s the executor
(which `require`s the Ajv-backed validator), install the assets deps first:

```sh
npm --prefix assets install
npm --prefix assets test    # node --test
```

They cover: single-txn first-time categorization and recategorization, the
multi-txn bulk path and the per-transaction fallback, the dry-run diff, category
name→id resolution, field isolation (payee/amount never sent), an unresolvable
name returning `error`, deferred-schema boot patience, and the namespaced-tool
enforcement — with tool names taken from the guardrail's `ALLOWED_TOOLS`, so the
test holds no hard-coded name.
