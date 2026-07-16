---
name: delete-duplicate
description: The M4-8 duplicate-fix (delete) write path — the destructive write-back path that removes a duplicate transaction via the namespaced delete tool. Wraps the M4-4 apply executor with the strongest safety in M4: mandatory surviving-twin (pairing) evidence, a mandatory dry-run preview that shows the pair side by side plus the cleared-balance impact, a separate strong-confirmation gate beyond batch approval, drift-abort per op, and a full before-snapshot audited before the irreversible delete. Imported as a library (assets/delete-duplicate.js) by the M4-5 approval command, which supplies the MCP-backed ports.
---

# Duplicate-Fix (Delete) Write Path — workbench-ynab write-back (M4-8)

Deleting a transaction is the **only irreversible operation in M4** and the one
with the highest blast radius if wrong. This path applies `delete_duplicate` ops
through the shared apply executor ([`skills/apply-executor.md`](apply-executor.md),
M4-4) but wraps them in the strongest safety the contract allows. It is the
delete half of M4 write-back; the executor is the generic machine, this path is
the destructive-op policy layered on top.

## Importable module

The path is an importable Node module —
[`assets/delete-duplicate.js`](../assets/delete-duplicate.js) — consumed as a
library by the M4-5 approval command, **not re-implemented inline**. It `require`s
the guardrail ([`assets/write-safety-guardrail.js`](../assets/write-safety-guardrail.js))
for the tool allow-list and **lazy**-`require`s the executor
([`assets/apply-executor.js`](../assets/apply-executor.js)) only inside
`applyDeleteDuplicates`, so importing its pure safety helpers (twin validation,
preview, dollar formatting, the strong-confirmation gate) pulls in **no**
dependency — that is what lets the destructive-path logic gate in CI offline
([`tests/unit/delete-duplicate.test.mjs`](../tests/unit/delete-duplicate.test.mjs),
run with no `node_modules`).

```js
const { applyDeleteDuplicates } = require('./assets/delete-duplicate');

const outcome = await applyDeleteDuplicates(changeset, {
  activeBudgetId,        // mandatory — the guardrail fails closed without it
  dryRun: false,         // omit / true = simulate; explicit false = real delete
  readLiveState,         // async (op) => live state of the transaction op.transaction_id names
                         // (wire to the get-transaction read; the handler re-invokes it with the
                         // twin's id swapped in for the twin-side live hard block)
  applyOp,               // async (toolName, op) => mcp result   (real delete only)
  audit,                 // async ({ operation, result, dryRun }) => void  (M4-3 sink)
});
```

## The five safety requirements

### 1. Twin (pairing) evidence — refused before any read or delete

Every `delete_duplicate` op must carry a **`twin`** object referencing its
surviving twin — the transaction it is a duplicate OF: `id`, `payee_name`,
`amount`, `date`. This is what lets the human and the preview see the **pair**,
not just the victim. `validateTwinEvidence(op)` checks it and
`applyDeleteDuplicates` runs that check over **every** delete op **first**; if any
op lacks complete twin evidence the call returns
`{ ok: false, reason: 'twin_evidence_missing', twinErrors }` **before the executor
runs** — no read, no delete, no port touched. The schema
([`assets/changeset-schema.json`](../assets/changeset-schema.json)) also makes
`twin` a required field, so a twin-less op is doubly impossible: unrepresentable
in the contract and refused by the handler.

### 2. Mandatory dry-run preview — the pair, side by side

`renderDeletePreview(op, { clearedBalanceBefore })` renders **victim and survivor
side by side** — `payee_name`, amount in **dollars** (milliunits ÷ 1000), `date`,
plus the victim's `account_id` and `cleared` status — and projects the account's
**cleared balance before vs after** the deletion. A deletion only moves the
cleared balance when the victim counts toward it (`cleared` or `reconciled`);
removing it subtracts the victim's signed amount (so an outflow is added back).
The executor is **dry-run by default** and calls no mutating tool in dry-run, so
the preview is produced without any delete. **No real delete may run unless a
dry-run preview was produced and displayed in the same apply session** — the M4-5
command runs dry-run → shows the preview → takes the confirmation below → only
then applies with `dryRun: false`.

### 3. Strong-confirmation gate — beyond batch approval

`delete_duplicate` ops are always `risk: destructive` (pinned by the schema and
asserted by the M4-2 guardrail). Beyond the normal per-batch approval, **every
destructive op requires a separate, explicit affirmation**:
`requiresStrongConfirmation(op)` / `destructiveOps(changeset)` mark them so the
**M4-5 `ynab-apply` command MUST** route each one through its own
`AskUserQuestion` where the human affirms that deletion as their own decision —
distinct from the batch "approve" click. The M4-5 command documents and enforces
this routing for **all** `risk: destructive` ops; a destructive op that has not
cleared its own confirmation must never reach `dryRun: false`.

### 4. Drift = abort for that op

Before any apply (dry-run **and** real), the executor re-reads the victim via the
injected `readLiveState` port (wire it to the **get-transaction** read tool,
resolved from [`skills/protocol/ynab-tools.md`](protocol/ynab-tools.md)) and
compares it to the op's `before` snapshot. If `payee_name`, `amount`, `date`,
`cleared` — or any other snapshotted field — has changed since the change-set was
generated, the op is marked `skipped-stale` and **never forced through**. Drift
fails closed: an unresolvable live read is treated as drift and skipped. Use
`shapeVictimSnapshot(liveTxn)` — the **full** victim field set, transfer fields
included — to project the live read onto the snapshot shape. The drift check
compares only the keys `op.before` actually snapshotted (extra live keys are
ignored), so the full projection is drift-equivalent to projecting by
`Object.keys(op.before)` — but it is **mandatory** for the transfer-leg hard
block: the handler re-derives `is_transfer_leg` from this **live** read
(GAP-19 / #49), so a projection that strips `transfer_account_id` /
`transfer_transaction_id` would blind the one gate a snapshot that omits its
shape evidence cannot talk around. The live re-derivation covers **both**
candidates, matching the "never target — or pair with — a transfer leg"
guarantee: the **victim** via the executor's own live read, and the **twin**
via a second read through the same port with the twin's `id` swapped into
`op.transaction_id` (the port simply resolves whatever id that field names —
no separate twin port). A live transfer leg on either side surfaces as a
terminal per-op `error` naming `transfer_leg_hard_block`; the delete tool is
never invoked for it, and a twin read that fails is a per-op read error, never
a skipped check.

The same live twin read also feeds the **surviving-twin liveness + drift gate**
(issue #151): when the victim itself has **not** drifted (a stale victim is
already skipped), the twin must be proven **alive** — a comparable live read —
and **unchanged** on the evidence fields the human approved (`payee_name`,
`amount`, `date`). A twin that no longer exists aborts the op with a terminal
per-op `error` naming `twin_missing`; a twin that materially changed aborts with
`twin_drifted`. Without this gate, a twin deleted or edited by another process
during the generate → approve → apply window would leave the victim's own
`before` snapshot unchanged — the op is not stale — and the delete would remove
the **only remaining copy**: the exact outcome the `twin_is_victim` guard
prevents, reached via twin-side staleness instead of a malformed op.

The live gate is decisive for **external-process** staleness only. Every op's
liveness reads run during the executor's **prepare phase** — `applyChangeset`
prepares every op before dispatching **any** mutation — so a **batch-mate's**
pending delete of the twin is invisible to it: in a reciprocal pair (op1:
victim=A/twin=B, op2: victim=B/twin=A) each op reads the other side as still
alive, both pass, and both copies are deleted. That vector is closed
**statically** in the pre-flight instead: `findBatchTwinCollisions` rejects any
change-set where one delete op's victim (`transaction_id`) is another delete
op's surviving twin (`twin.id`) — reciprocal pairs and overlapping chains alike
— returning `{ ok: false, reason: 'twin_batch_collision', batchCollisions }`
**before the executor runs** (dry-run included; no read, no delete, no port
touched), so batch-mates can never delete each other's survivors.

### 5. Audit the full before-snapshot, before the delete

YNAB deletes are effectively irreversible from the API surface, so the M4-3 audit
**before-snapshot is the only record** of what was removed. The op's `before`
carries the **full** victim state — `payee_name`, `amount`, `date`,
`category_id`, `account_id`, `cleared`, `memo` — and `makeAuditingDeleteApplyOp`
(wired automatically by `applyDeleteDuplicates` on the real-apply path) appends
that snapshot to the audit log **before** the delete tool runs, not after. The
executor records the post-delete result separately, so a destructive op leaves a
two-phase trail: intent (with the complete victim state) before, outcome after —
a crash mid-delete still leaves the snapshot.

## Tool resolution — namespaced, never hard-coded

The single delete tool is resolved from the guardrail's exported `ALLOWED_TOOLS`
by suffix (`DELETE_TOOL`, via `resolveDeleteTool` — which asserts **exactly one**
match and throws fail-closed on zero or several, issue #151, so a future
allow-list entry sharing the suffix can never silently receive irreversible
deletes), and `buildToolMap()` supplies `{ delete_duplicate:
DELETE_TOOL }` as the executor's registration point — **no literal
`mcp__plugin_workbench-ynab_ynab__*` name lives in the module** (the issue #87
guard stays green). The read tools the runtime wires into the ports — the
**get-transaction** read for drift detection and, optionally, the
**compare-transactions** read to corroborate the duplicate pairing in the preview
— are resolved from [`ynab-tools.md`](protocol/ynab-tools.md), never inlined here.
If the compare-transactions tool is unavailable in the deferred inventory, the
preview proceeds on the twin evidence alone — corroboration is a nicety, the twin
evidence is the requirement.

### Deferred-tool boot-patience

The YNAB MCP tools are delivered as **deferred schemas**. Before the first
`readLiveState` / `applyOp` call the agent **must** load them with `ToolSearch`
(the family glob `mcp__plugin_workbench-ynab_ynab__ynab_*` covers them). An
`InputValidationError` means the schema **isn't loaded yet**, not that the server
is down — retry with brief sleeps (boot patience) before concluding it is offline.

## Money is always milliunits

Every internal op field and audit record carries **raw integer milliunits**
verbatim. Only preview output is rendered as dollars via `formatDollars`
(milliunits ÷ 1000, integer math, no float round-trip). `before` / `twin` /
`after` carry the exact integers proposed.

## Consumer contract — M4-5 (approval command) MUST

- Run the change-set through `applyDeleteDuplicates` in **dry-run first** and
  display `renderDeletePreview` output (the pair + cleared-balance impact) for
  every delete op.
- Route **every** `risk: destructive` op (`destructiveOps(changeset)`) through a
  **separate `AskUserQuestion`** strong-confirmation, distinct from batch
  approval, before any real apply.
- Only then call `applyDeleteDuplicates` with `dryRun: false`, wiring
  `readLiveState` to the get-transaction read, `applyOp` to the delete dispatch,
  and `audit` to the M4-3 append helper.
- Surface any `twin_evidence_missing` abort to the human — a delete op that cannot
  prove which record survives is never applied.

## Tests

Pure-helper coverage (twin validation, preview, dollars, strong-confirmation,
snapshot shaping) runs in CI offline at
[`tests/unit/delete-duplicate.test.mjs`](../tests/unit/delete-duplicate.test.mjs).
Full executor-integration coverage — twin evidence rejected before any MCP call,
a drifted victim skipped not forced, the registered delete tool dispatched, and
the before-snapshot audited before the delete — lives beside the executor's own
suite at [`assets/test/delete-duplicate.test.js`](../assets/test/delete-duplicate.test.js)
and runs with the Ajv-backed validator installed:

```sh
npm --prefix assets install
npm --prefix assets test    # node --test
```
