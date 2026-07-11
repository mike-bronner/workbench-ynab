---
name: categorize-write-path
description: The M4-6 categorize / recategorize write path — the first concrete write path that plugs into the M4-4 apply executor. Given `categorize` operations from a validated, guardrail-passed change-set (M4-1 / M4-2), it sets the proposed category_id on each target transaction via the namespaced YNAB update-transaction tools, under approval and dry-run by default. A dumb, safe applier: it changes ONLY the category field — never payee, account, amount, date, or a transfer payee. It routes every op through the executor, so bulk dispatch still gets per-op drift detection, the guardrail, and the audit trail. Recategorization and first-time categorization share one code path.
---

# Categorize / Recategorize Write Path — workbench-ynab write-back (M4-6)

The most common YNAB chore is assigning categories to uncategorized transactions
and fixing miscategorized ones (the review's section 1 *Transaction
Classification* and section 4 *Uncategorized Transactions*). This write path turns
those review findings into applied `categorize` operations — under approval, never
autonomously.

It is the first concrete consumer of the **M4-4 apply executor**
([`skills/apply-executor.md`](apply-executor.md)): it **routes every op through the
executor** rather than running its own apply loop, registering the `categorize`
op-type → tool mapping (per-op *and* bulk), the field-isolated dispatch ports, and
a `bulkFits` predicate, and reusing the executor's `STATUS` result contract. The
importable module is
[`assets/categorize-handler.js`](../assets/categorize-handler.js).

## Routes through the executor — bulk is drift-safe and audited

The locked M4-6 architecture (Option 1) is that this handler owns **no apply
loop**. `applyCategorize` resolves category ids (see below), then hands the batch
to the executor's `applyChangeset`, supplying:

- `categorizeToolMap()` — the per-op `ynab_update_transaction` registration;
- `categorizeBulkToolMap()` — the bulk `ynab_update_transactions` registration;
- `makeCategorizeApplyOp` / `makeCategorizeBulkApplyOp` — the field-isolated
  dispatch ports; and
- `categorizeBulkFits` — the predicate that decides whether a group of survivors
  goes through one bulk call.

Because the executor drives the loop, the **bulk path inherits every safety
guarantee** the per-op path has: each op is re-read and **drift-checked**
(`skipped-stale`), re-run through the **guardrail** (`blocked`), and written to the
**M4-3 audit log** — only the mutating dispatch of the survivors is batched into
one call. This is why all four result statuses (`applied` / `skipped-stale` /
`blocked` / `error`) are reachable through this path, and why an earlier, bespoke
apply loop that bypassed drift/guardrail/audit was rejected in review.

## A dumb, safe applier — field isolation

The handler changes **only** the category. The single-transaction update payload
carries `category_id` plus the `budget_id` / `transaction_id` the flat YNAB tool
needs for addressing — **never** `payee_id`, `account_id`, `amount`, `date`, or a
`transfer_account_id`, even when those appear in an op's `before` / `after`
snapshots. (Setting a transfer payee would turn a transaction into a real money
movement; the M4-2 guardrail blocks that, and this handler never attempts it.) The
bulk per-entry shape is likewise just `{ id, category_id }`.

Recategorization (overwriting an existing category) and first-time categorization
(an uncategorized transaction) flow through the **same** code path — there is no
branch for the two cases; the executor's before→after diff just carries different
`before` content. Category choice and tax-awareness live upstream in the proposal
(M4-10 / M3 review), not here.

## Category id resolution — a read-only prep step, before the executor

When an op's `after.category_id` is present (which the change-set schema
**requires**, so this is the normal case), it is used directly. When it is absent,
`applyCategorize` resolves `after.category_name` to an id via the injected
`listCategories` port and writes it into a **copy** of the op *before* handing the
batch to the executor — so the change-set the executor schema-validates is
well-formed and every op still gets drift / guardrail / audit. This resolution is a
read-only prep step, not a second apply loop; it runs in **both** dry-run and real
apply (a dry-run preview shows the resolved id, and flags an unresolvable name as an
`error` before you approve). The name path is the documented fallback the M4-10
proposal **should** make unnecessary; an unresolvable name returns an `error`
result (never a thrown exception) and its op is withheld from the batch.

## Dry-run is the default

`dryRun` defaults to **`true`** — the executor produces a per-op `before → after`
category diff (old id + name → new id + name) and calls **no** mutating tool. Real
apply happens only when the caller passes an explicit `dryRun: false`, which the
M4-5 approval command does only after the human approves the batch.

## Bulk-preferring dispatch, with a documented fallback

For a real apply, the **executor** collapses a group of ≥2 resolvable survivors
into a single bulk `ynab_update_transactions` call (via `categorizeBulkToolMap()` +
`categorizeBulkFits`) to minimize round-trips, and falls back to per-transaction
`ynab_update_transaction` calls when the bulk shape does not fit: (a) fewer than 2
survivors (`categorizeBulkFits` is false), (b) a survivor can't form a
`{ id, category_id }` entry, or (c) the bulk tool rejects the category-only batch
shape at runtime — the executor then retries each op in the group individually.
Retrying is safe because a categorize write is **idempotent** (re-setting the same
category is a no-op-equivalent, never money movement). A cross-budget op never
reaches bulk dispatch at all — the guardrail `blocked`s it first, since the batch
runs against a single active budget.

## Namespaced tools only — resolved, never hard-coded

The write tool names are resolved from the guardrail's exported `ALLOWED_TOOLS` by
suffix, so no concrete `mcp__plugin_workbench-ynab_ynab__*` name lives in the
handler (the swap-ready single-source-of-truth invariant, issue #87). Names trace
to [`skills/protocol/ynab-tools.md`](protocol/ynab-tools.md); bare `mcp__ynab__*`
names are never produced.

## Injected ports (agent runtime)

Like the executor, the handler holds no MCP coupling — the caller wires:

- **`callTool(toolName, payload)`** — the mutating dispatch (real apply only).
- **`readLiveState(op)`** — the read-only drift-detection read the **executor**
  requires (mandatory): resolves each op's live category state so a value that
  drifted since the change-set was generated is `skipped-stale`, never clobbered.
- **`audit(record)`** — the append-only M4-3 audit sink the **executor** requires
  (mandatory): one record per op, dry-run and real.
- **`listCategories(budgetId)`** — read-only name→id resolution, used only when an
  op's `after.category_id` is absent. The proposal (M4-10) **should** pre-resolve
  ids so this lookup never runs; an unresolvable name returns an `error` result
  (never a thrown exception).
- **`toolSearch(names)`** — a `ToolSearch` select that loads the deferred YNAB tool
  schemas before the first MCP call. An `InputValidationError` means the schema is
  not loaded yet (**not** a server outage): the schemas are **reloaded** (the
  select is re-run) and the call retried with boot patience — not merely slept on.

## The result contract

`applyCategorize` returns the executor's outcome (`{ ok, dry_run, aborted, reason,
results }`). Each entry in `results` reuses the executor's `STATUS` (`applied` /
`skipped-stale` / `blocked` / `error`), extended with `transaction_id`, `before`,
`after`, and the `dry_run` flag the M4-5 command renders.

## Tests

Unit tests live at
[`assets/test/categorize-handler.test.js`](../assets/test/categorize-handler.test.js)
and run on Node's built-in runner. Because the handler `require`s the executor
(which `require`s the Ajv-backed validator), install the assets deps first:

```sh
npm --prefix assets install
npm --prefix assets test    # node --test
```

They exercise the **real** executor (not a mock), which is what proves the bulk
path inherits drift/guardrail/audit. They cover: single-txn first-time
categorization and recategorization, the multi-txn bulk path (one call, each op
drift-checked and audited) and the per-transaction fallback, drift skipping one op
of a bulk batch, a guardrail block aborting the batch, the dry-run diff, category
name→id resolution in both real apply **and** dry-run, field isolation at the
dispatch boundary (payee/amount never sent), an unresolvable name returning
`error`, deferred-schema boot patience with schema **reload** on
`InputValidationError`, and the namespaced-tool enforcement — with tool names taken
from the guardrail's `ALLOWED_TOOLS`, so the
test holds no hard-coded name.
