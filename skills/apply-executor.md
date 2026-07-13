---
name: apply-executor
description: The M4-4 apply executor — the shared write-back machinery every YNAB write path (categorize / allocate / dedupe / reconcile, M4-6..M4-9) runs through. Validates a change-set against the M4-1 schema, runs it through the M4-2 write-safety guardrail (fail-closed), then either SIMULATES it (dry-run, the default) or invokes the namespaced YNAB MCP tools, recording every attempt to the M4-3 audit log. Dry-run is the default; real apply is opt-in via dry_run=false after explicit human approval (M4-5). Imported as a library by the approval command and the four write paths, which supply only their op-type → tool mapping.
---

# Apply Executor — workbench-ynab write-back (M4-4)

The four write paths — categorize, allocate, delete-duplicate, reconcile — all
share one machine: validate a change-set, guardrail it, then either **simulate**
(dry-run) or **apply** it through the namespaced YNAB MCP tools, recording every
result to the audit log. This executor is that machine, built **once**, so each
downstream write path (M4-6..M4-9, #60–#63) supplies only its op-type → tool
mapping — not its own bespoke apply loop.

It is the **orchestration half** of M4 write-back. The change-set schema
([`assets/changeset-schema.json`](../assets/changeset-schema.json)) defines the
shape; the guardrail ([`skills/write-safety-guardrail.md`](write-safety-guardrail.md))
enforces ledger-only safety; the audit log
([`docs/audit-log.md`](../docs/audit-log.md)) records the evidence. This executor
wires them together in the right order.

## Importable module

The executor is an importable Node module —
[`assets/apply-executor.js`](../assets/apply-executor.js) — consumed as a
library, **not re-implemented inline** by any write path. It `require`s the
change-set validator ([`assets/validate-changeset.js`](../assets/validate-changeset.js))
and the guardrail ([`assets/write-safety-guardrail.js`](../assets/write-safety-guardrail.js))
directly, and takes every side-effecting operation as an **injected port** so the
control flow is unit-tested in isolation while the real MCP / audit wiring lives
in the agent runtime that calls it.

```js
const { applyChangeset } = require('./assets/apply-executor');

const outcome = await applyChangeset(changeset, {
  activeBudgetId,        // mandatory non-empty string — throws if missing
  dryRun: false,         // omit / true = simulate; explicit false = real apply
  toolMap,               // op-type → namespaced mutating tool (the registration point)
  readLiveState,         // async (op) => live-state shaped like op.before
  applyOp,               // async (toolName, op) => mcp result   (real apply only)
  authPreflight,         // async () => ynab_list_budgets result; THROWS on 401/403/network (real apply only)
  audit,                 // async ({ operation, result, dryRun }) => void
});
// outcome.results: [{ op_id, status, dry_run, detail }, ...]
```

There is **no CLI** — unlike the validator and guardrail, the executor cannot run
without its MCP-backed ports, which exist only in the agent runtime.

## Opt-in bulk dispatch — batch the write, keep every per-op guarantee

By default the executor applies **one op per tool call** (`applyOp`). A write path
that can collapse many same-type ops into a single call — categorize →
`ynab_update_transactions` (M4-6) — opts in by supplying three more options:

```js
const outcome = await applyChangeset(changeset, {
  /* …the per-op options above… */
  bulkToolMap,   // op-type → namespaced BULK tool
  bulkApplyOp,   // async (toolName, ops) => mcp result   (one call for the group)
  bulkFits,      // (ops) => boolean: may this same-type group go through one bulk call?
});
```

The executor still **drift-checks, guardrails, and audits every op individually** —
only the mutating dispatch of the survivors is batched. Per op-type, it groups the
survivors and, when `bulkApplyOp` is wired, `bulkToolMap[type]` is set, and
`bulkFits(group)` is true, issues **one** `bulkApplyOp` call; otherwise the group
applies per-op. If `bulkApplyOp` **throws** (the bulk shape was rejected at
runtime), the executor **falls back** to a per-op `applyOp` call for each op in the
group — so a bulk-capable path is never less safe, or less complete, than a per-op
one. A bulk call that **resolves** is read **fail-closed**: an op is recorded
`applied` only when the payload is well-shaped (a `results` array with one entry per
requested op) *and* that op's own entry reports a written status
(created/duplicate/updated). A failed entry, a missing entry, a length mismatch, or a
payload with no `results` array at all is audited as `error` — the M4-3 trail never
records `applied` for a transaction the tool did not positively confirm. This is the
mechanism that keeps `skipped-stale` / `blocked` reachable and the
M4-3 audit trail honest even on the bulk path. A bulk-capable op type is pre-flighted
on **both** its per-op tool and its bulk tool (the fallback needs the per-op tool),
so a denied bulk tool aborts the whole batch before any dispatch.

## Dry-run is the default — real apply is opt-in

`dryRun` defaults to **`true`**. A dry-run resolves the target entities via the
read-only port, confirms the `before` snapshot still matches live state (drift
detection below), and produces a per-op **simulated diff** — **without invoking
any mutating tool**. Real apply happens **only** when the caller passes an
explicit `dryRun: false`, which the M4-5 approval command (#59) does **only after
the human approves the batch**. Anything that is not an explicit `false` simulates.

## The pipeline (and its fail-closed ordering)

`applyChangeset` runs a fixed pipeline; **no stage is skipped**:

1. **Schema-validate** the whole change-set (`validateChangeset`). Malformed →
   return `{ ok: false, reason: 'schema_invalid', validation }` and call **no
   ports** (no read, no apply, no audit).
2. **Guardrail the whole batch** (`evaluateChangeset(changeset, { activeBudgetId })`).
   Any block → **abort the entire batch** (fail-closed): return
   `{ ok: false, reason: 'guardrail_block', guardrail }` with every op marked
   `blocked`. Nothing is applied past — or around — a block.
3. **Tool pre-flight (real apply only).** Resolve `toolMap[op.type]` for every op
   and run each through the guardrail's `evaluateTool`. Any denied / un-namespaced
   / unmapped tool → abort the whole batch (`reason: 'tool_block'`) **before any
   dispatch**, so a misconfigured map can never partially apply.
3.5. **Auth preflight (real apply only, GAP-8 / #50).** Call the injected
   `authPreflight` port — a cheap read-only YNAB call (e.g. `ynab_list_budgets`) —
   **before the first mutation**. Any failure (401 / 403 / network) aborts the whole
   batch (`reason: 'auth_preflight_fail'`) with **zero mutations and no audit records
   for ops that never ran**. `authPreflight` is **mandatory** on real apply — the
   executor fails closed (throws) without it. Dry-run never mutates, so it skips this.
4. **Prepare every op**, in array order: re-read live state → drift-check → (real
   apply) per-op guardrail re-check. Terminal outcomes (`error` / `skipped-stale` /
   `blocked`) are recorded now; the rest are **survivors**. A **read-phase auth
   failure** (a dead token surfaces on the re-read too) aborts the whole batch
   fail-closed here — preparation stops immediately, so ops past it are never read,
   dispatched, or audited (phase-agnostic; see Batch semantics).
5. **Dispatch the survivors**, in array order. Dry-run simulates each (diff only).
   Real apply batches each run of **consecutive same-type survivors** into one
   **bulk** call when a bulk port + `bulkFits` allow (see below), else a per-op
   `applyOp` call each — then **audits** every processed op, in array order. A stale
   op is skipped individually; the rest of the batch continues — **except** on a
   mid-batch auth failure (see Batch semantics), which stops the dispatch at that op
   and leaves the untouched tail un-audited.

## Drift detection — never clobber a value the human didn't see

Before processing each op (dry-run **and** real), the executor re-reads live
state via the injected `readLiveState(op)` port and compares it to the op's
read-only `before` snapshot. Only the fields the op snapshotted in `before` are
compared (it proposes a change from a known prior value of exactly those fields).
If live state has drifted, the op is flagged **`skipped-stale`**:

- In **real apply**, a stale op is **skipped** — it is not dispatched, so it can
  never overwrite a value that changed since the change-set was generated.
- In **dry-run**, a stale op is reported as `skipped-stale` too (nothing mutates
  in dry-run regardless), so the human sees exactly which ops have gone stale
  before approving.

Drift detection **fails closed**: if live state cannot be resolved to a
comparable object, the op is treated as stale and skipped.

## Batch semantics — the contract

An explicit, tested choice between all-or-nothing and best-effort:

- **Guardrail / schema / tool-config failures are all-or-nothing.** A blocked op,
  a malformed change-set, or a denied tool aborts the **whole** batch before
  anything is applied. This is the fail-closed safety promise.
- **Stale ops are skipped individually; runtime errors are isolated.** Once the
  batch clears the guardrail, a `stale` op or a single failing `applyOp` is
  recorded per-op (`skipped-stale` / `error`) and the **rest of the batch still
  applies**. One drifted or failing op does not sink its clean siblings.
- **Auth failure is all-or-nothing; every other error is isolated (GAP-8 / #50).**
  Two mutually-exclusive per-op error policies:
  - An **auth failure** (`401` → `auth_revoked`, `403` → `insufficient_scope`) means
    the token itself is bad, so the executor **aborts the whole batch**: it records
    that op, then stops immediately (`reason: 'auth_abort'`), leaving the remaining
    ops untouched and un-audited. Continuing would just fail — and waste a call — on
    every one.
  - A **single-op data error** (`422`), a **rate limit** (`429`), or an
    **indeterminate** `5xx` / network fault is recorded per-op (`error`) and the
    **batch continues** (skip-this-op-and-continue).
  Every errored op's result and audit record carry an `error_class`
  (`auth_revoked` / `insufficient_scope` / `rate_limited` / `unknown`) and an
  `applied_state` (`not_applied` when YNAB rejected the call, `unknown` when a
  timeout leaves it indeterminate) — the substrate idempotent resume (#48) reads.

## The registration point — op-type → tool is supplied, never hard-coded

The executor exposes the op→tool mapping as the `toolMap` argument: a
`{ <op-type>: <namespaced mutating tool>, ... }` object the **write paths supply**
(M4-6..M4-9). The executor never hard-codes a tool name — keeping it both
swap-ready and faithful to the single-source-of-truth invariant (issue #87).

**Resolve every tool name from [`skills/protocol/ynab-tools.md`](protocol/ynab-tools.md)**
(the write-tools section) — never paste a literal `mcp__plugin_workbench-ynab_ynab__*`
name into a write path or here. The mapping a write path builds is exactly the
contract's operation → apply-tool table
([`assets/changeset-contract.md`](../assets/changeset-contract.md) §3): each op
type maps to its allow-listed write tool, resolved from the protocol file. Before
each real dispatch the executor runs the supplied tool through the guardrail's
`evaluateTool`, so a bare `mcp__ynab__*` name or anything off the ledger-only
allow-list is blocked fail-closed.

## Wiring the ports (agent runtime)

The caller (M4-5, or a write-path skill) wires the three ports to the real MCP
and audit log:

- **`readLiveState(op)`** — calls the read-only namespaced YNAB reads
  (`ynab_get_*` / `ynab_list_*`, resolved from
  [`ynab-tools.md`](protocol/ynab-tools.md)) for the op's target entity and
  returns an object shaped like the op's `before` snapshot, so drift detection can
  compare them field-for-field.
- **`applyOp(toolName, op)`** — invokes the single namespaced mutating tool the
  executor resolved from `toolMap`. Only called on the real-apply path.
- **`bulkApplyOp(toolName, ops)`** — invokes the namespaced BULK tool for a whole
  group of same-type survivors in one call (opt-in; see the bulk section above).
  Only called on the real-apply path, and subject to the same isError→throw contract
  as `applyOp` — a resolved `{ isError: true }` bulk envelope must throw so the
  executor aborts / falls back fail-closed instead of reading it as a payload.
- **`authPreflight()`** — a read-only YNAB call (resolve `ynab_list_budgets` from
  [`ynab-tools.md`](protocol/ynab-tools.md)) run once before the first mutation to
  confirm the token is valid and write-capable. It must **throw** on a non-2xx (a
  401/403) or a network failure — the executor classifies the thrown error and
  aborts fail-closed. Mandatory on real apply; unused in dry-run.
- **`audit({ operation, result, dryRun })`** — appends one record via the M4-3
  audit log. The record mirrors the writer's
  `_audit_append <operation_json> <result_json> <dry_run>` signature
  ([`docs/audit-log.md`](../docs/audit-log.md)): `operation` is the change-set op,
  `result` is `{ tool, status, schema_version, run_id, error_class, applied_state }`
  (the last two are `null` on a non-error op and populated only on an errored one —
  see [`docs/audit-log.md`](../docs/audit-log.md) for the field semantics), and
  `dryRun` is stamped on every record — **dry-run attempts are audited too**,
  flagged, so they leave a full paper trail.

> **Every port wrapper must `throw` on failure — check `result.isError` first.**
> The auth-preflight, mid-batch abort, and error-classification machinery all key
> on the ports **throwing**: `classifyError` only runs inside the executor's
> `catch` blocks. But the vendored YNAB MCP (`vendor/ynab-mcp/index.cjs`) surfaces
> auth / rate-limit / 5xx failures as a **resolved** `{ isError: true, … }` result,
> not a rejected promise. So each wrapper for `readLiveState`, `applyOp`,
> `authPreflight`, and `bulkApplyOp` **must inspect `result.isError` and `throw`**
> (rethrowing the structured error, preserving the HTTP status) before returning to
> the executor. The shared `throwOnErrorResult` helper (`assets/write-error.js`) does
> exactly this — wrap every `callTool` result in it.
> A wrapper that returns the MCP result verbatim fails **open** — a 401 preflight
> would silently "pass" and a mid-batch 401 would look like a success. Mirrored in
> [`ynab-tools.md`](protocol/ynab-tools.md).
>
> As defense in depth (#50), the shared gates the ports flow through — the executor's
> `authPreflight` call and per-op bulk fallback, and the reconcile / delete handlers'
> own `applyOp` / `authPreflight` calls — **also** route their result through
> `throwOnErrorResult`, so a wrapper that forgot the check still fails **closed** on
> the money paths. The wrapper obligation above stands; this is a code-enforced net
> under it, not a substitute for it.

### Deferred-tool boot-patience — load schemas before the first MCP call

The YNAB MCP tools are almost always delivered as **deferred schemas**. Before
the first `readLiveState` / `applyOp` call, the agent **must** load them with
`ToolSearch` — a `select:` of the read/write tool names resolved from
[`ynab-tools.md`](protocol/ynab-tools.md) (the family glob
`mcp__plugin_workbench-ynab_ynab__ynab_*` covers them), or a keyword search. An
`InputValidationError` means the schema **isn't loaded yet**, **not** that the
server is down — retry with brief sleeps (boot patience),
mirroring `~/Developer/workbench-bujo/agents/bujo-orchestrator.md` lines 13–38.
The MCP may take ~10s to boot; never conclude it is offline without the
boot-patience retry first.

## Money is always milliunits

Every monetary value — `budgeted`, `amount`, `cleared_balance`,
`reconciled_balance` — flows through the executor as a **raw integer milliunit**,
verbatim. The executor does no arithmetic on an amount and never divides for
display (only the audit **read** path divides by 1000), so **no float conversion
occurs anywhere** on the apply or dry-run path. `before` / `after` / the simulated
diff carry the exact integers that were proposed.

## The result contract — what M4-5 renders

`applyChangeset` returns a structured outcome. The per-op `results` array is the
contract the M4-5 approval command (#59) renders for the human — one entry per
operation:

```json
{ "op_id": "op-categorize-0001", "status": "applied", "dry_run": true, "detail": { "simulated": true, "diff": { "before": {…}, "after": {…} } } }
```

`status` is exactly one of:

| `status` | Meaning |
|---|---|
| `applied` | The op was applied. With `dry_run: true` the apply is **simulated** (diff only, nothing mutated); with `dry_run: false` the mutating tool ran. |
| `skipped-stale` | Live state drifted from the op's `before` snapshot; the op was **not** applied. |
| `blocked` | The guardrail (or the tool pre-flight) refused the op; `detail.verdict` carries the full guardrail verdict (`op_id`, `op_type`, `rule`, `reason`). |
| `error` | The read or apply port threw; `detail.message` carries the failure, and `detail.error_class` / `detail.applied_state` classify it. On a **non-auth** error the rest of the batch still proceeded; an **auth** error stopped the batch (see below). |

The top-level outcome carries `ok`, `dry_run`, `aborted`, and `reason`
(`schema_invalid` / `guardrail_block` / `tool_block` / `auth_preflight_fail` /
`auth_abort` / `dry_run_complete` / `apply_complete`), plus the `validation` or
`guardrail` verdict on an abort.

On an auth abort (`auth_preflight_fail` or `auth_abort`) the outcome also carries
`authFailure` (`{ phase, op_id, error_class, applied_state }`), `total_ops`, and —
for a mid-batch stop — `stopped_at_index`. Render the human message with the
exported **`describeAuthFailure(outcome)`** helper: it lists the ops that applied
before the stop, names the failed op and its `error_class`, states the exact
remediation, and distinguishes **"no changes applied"** (preflight or first-op
failure) from **"N of M ops applied, batch stopped at op K"** (a real mid-batch
failure). It returns `null` for any non-auth-failure outcome.

## Tests

Unit tests live at
[`assets/test/apply-executor.test.js`](../assets/test/apply-executor.test.js) and
run on Node's built-in runner. Because the executor `require`s the Ajv-backed
validator, install the assets deps first:

```sh
npm --prefix assets install
npm --prefix assets test    # node --test
```

They cover, at minimum: (a) dry-run with no drift (every op simulated, nothing
mutated), (b) dry-run detecting drift on one op, (c) real apply with one stale op
skipped while a clean op applies, (d) a guardrail block aborting the whole batch,
and (e) schema-validation rejection before any port is touched — plus the
registration point, namespaced-tool enforcement, milliunit exactness, the audit
record shape, the result contract, and the fail-fast port / `activeBudgetId`
contract. The injected ports are mocked and tool names are taken from the
guardrail's exported `ALLOWED_TOOLS`, so the test holds no hard-coded tool name.
