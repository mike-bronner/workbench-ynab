---
name: write-safety-guardrail
description: The M4-2 write-safety guardrail — the runtime enforcement that workbench-ynab writes are LEDGER-ONLY and NEVER move real money. Defines the ledger-only operation/tool allow-lists, the money-movement deny-list, transfer detection, and scope assertions; returns a structured pass/block verdict for a change-set, operation, or tool name. Imported as a protocol reference by the M4-4 apply executor (before every tool call) and the M4-5 approval command (before presenting a batch to the human). Fail-closed: the default verdict is BLOCK.
---

# Write-Safety Guardrail — workbench-ynab write-back (M4-2)

The single most important invariant in this plugin: writes are **ledger-only**
operations inside YNAB and **NEVER move real money** — no transfers, no payments
to the outside world (locked decision). This guardrail is the enforcement layer
that makes that promise **mechanical rather than aspirational**. It sits between
an approved change-set and the apply executor and refuses to let anything
money-moving through, **regardless of what the review proposed or the human
clicked**.

It is the **runtime half** of the M4 safety promise. The change-set schema
([`assets/changeset-schema.json`](../assets/changeset-schema.json)) makes a
money-moving change-set **unrepresentable** (`money_movement` is a `const false`);
this guardrail makes a money-moving apply **impossible**. Both must hold.

## Importable module

The protocol is implemented as a dependency-free, importable Node module —
[`assets/write-safety-guardrail.js`](../assets/write-safety-guardrail.js) — so it
is consumed as a library, **not re-implemented inline** by any consumer. It is the
companion to the change-set validator
([`assets/validate-changeset.js`](../assets/validate-changeset.js)): validate the
shape first, then run the guardrail.

```js
const {
  evaluateChangeset, evaluateOperation, evaluateTool,
  LEDGER_ONLY_OP_TYPES, ALLOWED_TOOLS, DENIED_TOOLS, RULES,
} = require('./assets/write-safety-guardrail');

const result = evaluateChangeset(changeset, { activeBudgetId });
// result.verdict === 'pass' | 'block'
// result.blocks  === [ <block verdict>, ... ]   (empty when pass)
```

As a CLI (verdict JSON on **stdout**, diagnostics on **stderr** only, non-zero
exit on block):

```sh
node assets/write-safety-guardrail.js [--active-budget <id>] <changeset.json>
npm --prefix assets run guardrail -- <changeset.json>
```

## Fail-closed

The default verdict is **BLOCK**. An operation or tool passes **only** when it is
positively matched to the ledger-only allow-list **and** clears every scope
assertion. Anything the guardrail cannot positively classify as ledger-only — an
unknown operation type, an unrecognised tool, a malformed object — is blocked. If
in doubt, it blocks.

## Single source of truth — the allow-lists and deny-list

These three constants in `write-safety-guardrail.js` are the **only** place write
paths are enumerated. **Adding a new write path means editing the relevant
constant here first** — nothing downstream may widen them.

### 1. Ledger-only operation-type allow-list (`LEDGER_ONLY_OP_TYPES`)

Exactly these four operation types may pass; anything else is blocked
(`op_type_not_in_allow_list`):

| Op type | Apply tool(s) |
|---|---|
| `categorize` | `ynab_update_transaction` / `ynab_update_transactions` |
| `allocate` | `ynab_update_category` |
| `delete_duplicate` | `ynab_delete_transaction` |
| `reconcile` | `ynab_reconcile_account` + `ynab_update_transaction(s)` |

### 2. Namespaced tool allow-list (`ALLOWED_TOOLS`)

Exactly these **fully namespaced** tools may be invoked at apply time:

- `mcp__plugin_workbench-ynab_ynab__ynab_update_transaction`
- `mcp__plugin_workbench-ynab_ynab__ynab_update_transactions`
- `mcp__plugin_workbench-ynab_ynab__ynab_update_category`
- `mcp__plugin_workbench-ynab_ynab__ynab_delete_transaction`
- `mcp__plugin_workbench-ynab_ynab__ynab_reconcile_account`

### 3. Money-movement deny-list (`DENIED_TOOLS`)

Explicitly forbidden, as full namespaced strings. These create/move funds to or
beyond an account boundary, or mutate account / default-budget state, and may
**never** run (`denied_tool_money_movement`):

- `mcp__plugin_workbench-ynab_ynab__ynab_create_transaction`
- `mcp__plugin_workbench-ynab_ynab__ynab_create_transactions`
- `mcp__plugin_workbench-ynab_ynab__ynab_create_receipt_split_transaction`
- `mcp__plugin_workbench-ynab_ynab__ynab_create_account`
- `mcp__plugin_workbench-ynab_ynab__ynab_set_default_budget`

> **Namespaced strings only.** The lists hold the fully qualified
> `mcp__plugin_workbench-ynab_ynab__*` names so a typo can't accidentally allow a
> bare `mcp__ynab__ynab_create_transaction`. A bare, un-namespaced create tool is
> not on the allow-list and is therefore blocked fail-closed regardless.

## Money-movement hard block (transfer detection)

The guardrail explicitly **denies** any operation or tool that creates or moves
funds across an account boundary — transfer-creating transactions, payments, and
the transaction-creation tools — even when smuggled inside an otherwise-allowed
operation.

`evaluateOperation` scans the operation's **proposed state and every field except
the read-only `before` snapshot** for a transfer signal:

- a truthy `transfer_account_id` or `transfer_transaction_id`, or
- a `payee_name` / `payee` of the form `Transfer : <account>`.

A `categorize` operation that sets `transfer_account_id` or a transfer payee in
its `after` snapshot is blocked with rule
**`money_movement_detected_in_categorize`** even though `categorize` is an allowed
type. The same signal in any other operation type blocks with
`money_movement_detected`.

The `before` snapshot is **excluded** from the scan: it is a read-only historical
record that may legitimately describe a pre-existing transfer (e.g. a duplicate of
a transfer being removed). Deleting a duplicate transfer record is still
ledger-only and must not false-positive.

## Scope assertions

`evaluateChangeset` evaluates and blocks on failure:

1. **`money_movement` flag** — the envelope's `money_movement` must be **strictly
   `false`**. `true`, missing, or any other value → block
   (`money_movement_flag_not_false`).
2. **Budget targeting** — every operation's `budget_id` must match the active
   budget id (the envelope's `budget_id`, or an explicit `activeBudgetId`
   override). Mismatch → block (`budget_id_mismatch`).
3. **Destructive tag** — every `delete_duplicate` operation must carry
   `risk: "destructive"`. Otherwise → block
   (`delete_duplicate_missing_destructive_risk`).

## Structured verdict

On **block**, the guardrail returns a structured verdict object:

```json
{
  "verdict": "block",
  "op_id": "op-categorize-0001",
  "op_type": "categorize",
  "rule": "money_movement_detected_in_categorize",
  "reason": "Operation carries a transfer / money-movement signal ... ledger-only writes may never move money."
}
```

- `verdict` — `"block"`.
- `op_id` — the blocked operation's id (`null` for envelope- or tool-level blocks).
- `op_type` — the operation type (`null` when unknown / not applicable).
- `rule` — the violated rule name, one of the `RULES.*` string constants.
- `reason` — a human-readable sentence the approval command (M4-5) surfaces to
  the human.

On **pass**, `evaluateOperation` / `evaluateTool` return an explicit
`{ "verdict": "pass" }` object — not merely the absence of an error.
`evaluateChangeset` returns `{ "verdict": "pass", "blocks": [] }`.

The full set of rule constants: `op_type_not_in_allow_list`,
`denied_tool_money_movement`, `tool_not_in_allow_list`,
`money_movement_detected_in_categorize`, `money_movement_detected`,
`money_movement_flag_not_false`, `budget_id_mismatch`,
`delete_duplicate_missing_destructive_risk`, `malformed_operation`,
`malformed_changeset`.

## Consumer contract

### M4-4 (apply executor) MUST

- Invoke the guardrail **before each individual tool call**: run
  `evaluateOperation(op, { activeBudgetId })` for the operation about to be
  applied **and** `evaluateTool(toolName)` for the exact namespaced tool about to
  be invoked.
- **Abort the entire batch** on any `"block"` verdict — do not apply the blocked
  operation, and do not continue to later operations. The change-set is applied
  all-or-aborted, never partially around a block.

### M4-5 (approval command) MUST

- Run the **full** proposed change-set through `evaluateChangeset` **before**
  presenting options to the human.
- **Surface each blocked operation with its full verdict** (`op_id`, `op_type`,
  `rule`, `reason`) so the human sees exactly what was refused and why. A
  change-set with any block verdict must not be offered for approval as-is.

## stderr discipline

These artifacts live alongside JSON-RPC channels. The module's CLI emits **only**
the structured verdict JSON to **stdout**; every diagnostic / human-readable line
goes to **stderr** (`>&2`). Any shell helper added later must follow the same
launcher discipline (see `~/Developer/workbench-core/hooks/mcp-memory.sh`).

## Tests

Unit tests live at
[`assets/test/write-safety-guardrail.test.js`](../assets/test/write-safety-guardrail.test.js)
and run on Node's built-in runner (no extra dependency):

```sh
npm --prefix assets test    # node --test
```

They cover, at minimum: a valid `categorize` passes; `ynab_create_transaction` is
blocked via the deny-list; a `categorize` with `transfer_account_id` in `after` is
blocked; a mismatched `budget_id` is blocked; an unknown operation type is blocked
(fail-closed); a valid `delete_duplicate` (risk `destructive`) passes; and a
`delete_duplicate` missing `risk: "destructive"` is blocked — plus the envelope
`money_movement` flag, tool allow/deny coverage, and malformed-input fail-closed
paths.
