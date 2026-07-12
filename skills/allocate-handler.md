---
name: allocate-handler
description: The M4-7 allocate / set-budgeted-amount write path — the op-type-specific layer the apply executor (M4-4) runs an `allocate` operation through. Registers `allocate` → `update_category` with the executor's toolMap, shapes the update_category call (sets `budgeted` to `after.budgeted` in raw milliunits, nothing else), renders the human-readable dry-run before→after currency diff, and runs the advisory Ready-to-Assign over-allocation check by reading `get_month`. Ledger-only: allocate reassigns budgeted dollars inside the budget and NEVER moves real money. Imported as a library by the approval command (M4-5).
---

# Allocate Write Path — workbench-ynab write-back (M4-7)

`allocate` sets a category's **budgeted** amount for a month — a ledger-internal
reassignment of budgeted dollars (between categories / out of Ready-to-Assign)
**inside** the YNAB budget. It lets a human accept the review's funding
suggestions (Budget Health Check, review §6) under approval.

> **This is NOT a transfer.** Allocation moves *budgeted dollars* in the ledger;
> it does **not** move real money between accounts. The M4-2 guardrail classifies
> it as `allocate` (allowed, non-money-movement). The handler's only mutating
> tool is `update_category`, which it uses to set `budgeted` and nothing else — it
> **must never** call any account-to-account, transfer, or transaction-creating
> tool.

## Importable module

[`assets/allocate-handler.js`](../assets/allocate-handler.js) — a pure library
consumed by the M4-5 approval command and wired to the M4-4 apply executor. It is
the **op-type-specific** half of write-back: the executor owns the generic apply
loop (validate → guardrail → drift-check → simulate-or-dispatch → audit); this
module supplies only what is unique to `allocate`. It depends solely on the
dependency-free guardrail (for the tool allow-list), so it needs **no install
step** and has **no CLI** (the dry-run path needs the runtime's injected read
port).

```js
const allocate = require('./assets/allocate-handler');
```

## What it provides

| Export | Role |
|---|---|
| `toolMapEntry()` | `{ allocate: <namespaced update_category> }` — spread into the executor's `toolMap` (the registration point). |
| `buildApplyArgs(op)` | The flat `update_category` args `{ budget_id, category_id, month, budgeted }`, with `budgeted = after.budgeted` in **raw milliunits**. Throws on a malformed op. |
| `validateAllocateOp(op)` | `{ valid, errors }` — required-field check independent of the Ajv schema, so a bad op is rejected with a descriptive error before any tool runs. |
| `renderDiff(op, categoryName?)` | Human-readable before→after currency diff, e.g. `Groceries — 2026-06-01: $0.00 → $250.00 (+$250.00)`. |
| `formatMilliunits(mu)` | Display-only ÷1000 currency formatting (`250000` → `$250.00`). |
| `assessOverAllocation(ops, readyToAssign)` | Pure RTA arithmetic + advisory warning. |
| `dryRunAllocate(ops, { getMonth })` | The full dry-run preview: per-op diffs + per-month over-allocation warnings. Issues **no write**. |

## Registration + wiring (M4-5 / the executor ports)

```js
// 1. Register with the executor so allocate ops dispatch to update_category:
const toolMap = { ...allocate.toolMapEntry() /*, ...other handlers */ };

// 2. The runtime's applyOp shapes the mutating call from buildApplyArgs:
const applyOp = async (toolName, op) =>
  mcp(toolName, op.type === 'allocate' ? allocate.buildApplyArgs(op) : /* … */);

// 3. Before approval, render the dry-run preview + advisory RTA warning:
const preview = await allocate.dryRunAllocate(changeset.operations, {
  getMonth: async ({ budget_id, month }) => mcp('<get_month>', { budget_id, month }),
});
```

The concrete tool names live **only** in
[`skills/protocol/ynab-tools.md`](protocol/ynab-tools.md) (the #87 single source
of truth). The handler resolves `update_category` from the guardrail's allow-list
by suffix and takes `get_month` as the injected `getMonth` read port — so **no
literal `mcp__plugin_workbench-ynab_ynab__*` name appears in the handler**.

## Milliunits and negative budgeted

Every monetary value is a **raw integer milliunit**, passed to the YNAB API
verbatim; the ÷1000 conversion happens **only** in human-facing output. A
**negative** `after.budgeted` (de-funding a category below zero) is valid and
flows through both dry-run and live apply unchanged.

## Over-allocation is advisory

In dry-run, the handler reads `get_month` to obtain each month's Ready-to-Assign
(`to_be_budgeted`) and warns when the batch's net budgeted delta would push it
negative (projected RTA `= to_be_budgeted − Σ(after − before)`, checked
**per month**). The warning is **advisory only** — it never blocks; the human
decides at the approval step (M4-5). If `get_month` returns no usable
`to_be_budgeted`, no warning is invented and nothing is blocked.

## Tests

[`assets/test/allocate-handler.test.js`](../assets/test/allocate-handler.test.js),
on Node's built-in runner (no Ajv needed):

```sh
npm --prefix assets test    # node --test (the whole assets suite)
```

They cover: the registration mapping; a valid op → correct `update_category` args
with raw milliunits; the dry-run diff string; the RTA over-allocation warning
(single- and multi-month); negative (de-funding) budgeted pass-through; and
malformed ops rejected with a descriptive error before any tool is touched. Tool
names are taken from the guardrail's exported `ALLOWED_TOOLS`, so the test holds
no hard-coded tool name.
