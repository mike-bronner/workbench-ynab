---
name: reconcile-write-path
description: The M4-9 reconciliation-assist write path — the `reconcile` op handler for YNAB write-back. Plugs into the M4-4 apply executor's dispatch as the `reconcile` entry and handles two sub-actions, declared by op shape — mark_cleared (set only the `cleared` field on transactions via ynab_update_transaction(s)) and reconcile_account (reconcile an account to an asserted balance via ynab_reconcile_account). Ledger-only and money-safe: a balance guard refuses reconciling to a mismatched balance (which would make YNAB create an adjustment) and an adjustment guard refuses any reconcile response that still indicates one. Dry-run is the default; real apply is opt-in after explicit human approval (M4-5).
---

# Reconciliation-assist write path — workbench-ynab write-back (M4-9)

The `reconcile` op handler ([`assets/reconcile-handler.js`](../assets/reconcile-handler.js))
closes the loop on the review's **Reconciliation Status** (section 8) and **Stale
Uncleared Transactions** (section 5): it marks the right transactions
cleared/reconciled and reconciles an account to a known balance — all under
approval, all **ledger-only**. Reconciliation does not move money; it asserts that
recorded state matches reality.

It is one of the four write paths that run through the **M4-4 apply executor**
([`apply-executor.md`](apply-executor.md)) and returns the executor's **standard
per-op result shape** (`applied` / `skipped-stale` / `blocked` / `error`), so the
M4-5 approval command renders it without special-casing this path.

## Not a thin executor delegation — why this handler exists

The generic executor's ports can simulate a `{ before, after }` diff and detect
drift, but a reconcile op needs three things they cannot express:

- a **dry-run that BLOCKS** on a balance mismatch (the generic dry-run always
  simulates `applied`);
- a **per-transaction `cleared` diff** for `mark_cleared` (not the generic
  whole-`before`/`after` diff);
- an **adjustment guard** on the reconcile response.

So the reconcile-specific control flow lives in this handler while it **reuses**
the executor's `STATUS` / `isStale` and the **M4-2 guardrail**'s
`evaluateOperation` / `evaluateTool` for everything shared.

## Two sub-actions — declared by the op's shape

The M4-1 change-set schema pins `reconcileOp` with `additionalProperties: false`,
so there is **no literal `sub_action` field** to read — the op's **shape is the
discriminator** (and `asserted_balance` is carried as `after.reconciled_balance`,
the schema's existing field, not a new one):

| Sub-action | Selected when | Applied via | Asserted balance |
|---|---|---|---|
| `reconcile_account` | `after.reconciled_balance` is present | `ynab_reconcile_account` | `after.reconciled_balance` |
| `mark_cleared` | no `after.reconciled_balance`, but `after.cleared` present **and** a non-empty `transaction_ids` | `ynab_update_transaction` (single) / `ynab_update_transactions` (batch) | — |
| _(unrecognized)_ | neither of the above | — | returns a structured `error`, **without touching YNAB** |

`reconciled_balance` is tested first: an account reconcile also carries the
resulting `cleared` status, so its presence is the unambiguous signal.

> **Interpretation note (for review).** The M4-9 acceptance criteria describe the
> op as "declaring" a sub-action and carrying an "asserted balance". Because the
> M4-1 schema is a locked, separately-owned contract (`additionalProperties:
> false`, no `sub_action` / `asserted_balance` fields), this handler honours that
> schema rather than widening it: it derives the sub-action from the op's shape
> and reads the asserted balance from `after.reconciled_balance`. Extending the
> schema (a MINOR version bump touching the M4-1 contract, its fixtures, and the
> validator) was treated as out of scope for this issue.

## Money safety — the balance guard and the adjustment guard

Marking cleared/reconciled and reconciling-to-a-**matching** balance are
ledger-only state assertions (allowed). Auto-creating a reconciliation adjustment
is **money-like** and must never happen without explicit sign-off — two guards
enforce that, defense-in-depth alongside the M4-2 guardrail:

- **Balance guard** (`reconcile_account`, both modes): re-read the account's live
  cleared balance; if it does **not** equal the asserted balance
  (`after.reconciled_balance`), mark the op **`blocked`**, surface the gap in
  currency units (milliunits ÷ 1000), and **never call** `ynab_reconcile_account`.
  A mismatch is exactly what makes YNAB create an adjustment, so refusing the
  mismatch refuses the adjustment at the source.
- **Adjustment guard** (`reconcile_account`, real apply): even after a matching
  balance, if the reconcile response still indicates a balance-adjustment
  transaction (`adjustment` / `adjustment_transaction` / `adjustment_transaction_id`),
  the op is **`blocked`** and surfaced — no silent auto-adjustment, ever.

## Drift detection — never clobber a value the human didn't see

Before simulate or apply (both modes), the handler re-reads live state and
compares it to the op's `before` snapshot:

- `reconcile_account` — account-level `before` (`cleared_balance`, …) vs live,
  via the executor's subset `isStale`.
- `mark_cleared` — stale if **any** target transaction's live `cleared` differs
  from the `before.cleared` baseline (fail-closed on a missing/malformed live txn).

A stale op is `skipped-stale`: real apply skips it; dry-run surfaces the flag
without aborting the batch.

## `mark_cleared` changes ONLY the `cleared` field

Real apply builds a **minimal patch** — `{ transaction_id, cleared }` (single) or
`{ transactions: [{ id, cleared }, …] }` (batch) — so the update can never touch
any field but the cleared status. Single vs batch picks
`ynab_update_transaction` vs `ynab_update_transactions` by target count.

## Wiring the ports (agent runtime)

Like the executor, this handler holds **no concrete tool name** (issue #87): the
caller resolves names from [`protocol/ynab-tools.md`](protocol/ynab-tools.md) and
passes them, and every side-effecting call is an injected port.

```js
const { applyReconcile } = require('./assets/reconcile-handler');
const { results } = await applyReconcile(reconcileOps, {
  activeBudgetId,            // mandatory non-empty string
  dryRun: false,            // omit / true = simulate; explicit false = real apply
  schemaVersion, source,    // change-set provenance, for the audit record
  toolMap: {                // tool-need → namespaced tool (resolved from ynab-tools.md)
    update_transaction, update_transactions, reconcile_account,
  },
  toolSearch,               // async () => ToolSearch(...) — loads deferred schemas
  readLiveState,            // async (op) => live state (shapes below)
  applyOp,                  // async (toolName, payload, op) => mcp result (real apply only)
  audit,                    // async ({ operation, result, dryRun }) => void (M4-3)
});
```

- **`readLiveState(op)`** returns, by sub-action:
  - `reconcile_account` — `{ cleared_balance, reconciled_balance?, cleared? }`
    (account-level, resolved from `ynab_get_account`).
  - `mark_cleared` — `{ transactions: [{ id, cleared }, …] }` for the target ids
    (resolved from `ynab_get_transaction` / `ynab_list_transactions`).
- **`applyOp(toolName, payload, op)`** invokes the one namespaced mutating tool
  with the minimal `payload` the handler built (real apply only).
- **`audit({ operation, result, dryRun })`** appends one M4-3 record per op —
  **dry-run attempts included**, flagged.

### Deferred-tool boot-patience — load schemas before the first MCP call

The YNAB MCP tools are delivered as **deferred schemas**. `applyReconcile` calls
`loadDeferredSchemas(toolSearch)` **once** before the first port call. An
`InputValidationError` means the schema **isn't loaded yet** (the MCP can take
~10s to boot), **not** that the server is down — it retries with brief sleeps
(boot patience), never aborting on the first one. Any other error propagates.

## The result contract

Each op yields `{ op_id, status, dry_run, detail }`. `status` is exactly one of
`applied` / `skipped-stale` / `blocked` / `error` (the executor's `STATUS`). The
`detail.reason` for a block is one of `balance_mismatch`, `adjustment_would_create`,
or `guardrail_block`; for a skip, `stale`; for an unrecognized sub-action,
`unrecognized_sub_action`.

## Tests

Unit tests live at
[`assets/test/reconcile-handler.test.js`](../assets/test/reconcile-handler.test.js)
on Node's built-in runner. Because the handler `require`s the Ajv-backed executor,
install the assets deps first:

```sh
npm --prefix assets install
npm --prefix assets test    # node --test
```

They cover, at minimum: `mark_cleared` dry-run diff, `mark_cleared` real-apply
field-isolation (single + batch), the balance-mismatch block, the
adjustment-creation block, and the drift-stale skip — plus sub-action
classification, the unrecognized-sub-action error, the `reconcile_account` dry-run
plan, namespaced-tool enforcement, ToolSearch boot-patience, the audit record
shape, and the fail-fast port / `activeBudgetId` contract. All MCP ports are
mocked and tool names come from the guardrail's exported `ALLOWED_TOOLS`, so the
test holds no hard-coded tool name and makes no live YNAB call.
