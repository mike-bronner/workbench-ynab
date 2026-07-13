'use strict';

/**
 * Reconciliation-assist write path for workbench-ynab write-back (M4-9).
 *
 * The `reconcile` op handler. It plugs into the M4-4 apply executor's dispatch as
 * the `reconcile` entry (the approval command, M4-5, maps op-type → handler and
 * routes reconcile ops here) and returns the executor's standard per-op result
 * shape (`applied` / `skipped-stale` / `blocked` / `error`), so M4-5 renders it
 * without special-casing this path.
 *
 * It is NOT a thin `applyChangeset` delegation: a reconcile op needs guards the
 * generic executor's ports cannot express — a dry-run that BLOCKS on a balance
 * mismatch, a per-transaction `cleared` diff, and an adjustment guard on the
 * reconcile response. So the reconcile-specific control flow lives here while it
 * reuses the executor's `STATUS` / `isStale` and the M4-2 guardrail's
 * `evaluateOperation` / `evaluateTool` for everything shared.
 *
 * Two sub-actions, declared by the op's shape (the M4-1 schema's reconcileOp pins
 * `additionalProperties: false`, so there is no literal `sub_action` field to read;
 * the shape is the discriminator):
 *
 *   - RECONCILE_ACCOUNT — `after.reconciled_balance` present. Reconcile the account
 *     to that asserted balance (milliunits) via the namespaced
 *     `ynab_reconcile_account`. The asserted balance IS `after.reconciled_balance`.
 *   - MARK_CLEARED — no `after.reconciled_balance`, but `after.cleared` present with
 *     a non-empty `transaction_ids`. Set ONLY the `cleared` field on those
 *     transactions via `ynab_update_transaction` (single) / `ynab_update_transactions`
 *     (batch).
 *   - Anything else → a structured `error` result, without touching YNAB.
 *
 * Safety framing (defense in depth alongside the M4-2 guardrail): marking
 * cleared/reconciled and reconciling-to-a-matching-balance are ledger-only state
 * assertions. Auto-creating a reconciliation adjustment is money-like and must
 * never happen without explicit approval — the balance guard refuses a mismatch
 * up front (a mismatch is exactly what makes YNAB create an adjustment), and the
 * adjustment guard refuses any reconcile response that still indicates one.
 *
 * NAMESPACED TOOLS ONLY, never hard-coded here. Like the executor, this module
 * holds no concrete `mcp__plugin_workbench-ynab_ynab__*` string (issue #87 guard):
 * the caller resolves the tool names from `skills/protocol/ynab-tools.md` and
 * passes them as `toolMap`, and the side-effecting MCP calls are injected ports.
 *
 * MILLIUNITS THROUGHOUT. Monetary values pass through verbatim as integer
 * milliunits; the only division by 1000 is for the human-facing `_display` fields
 * on a balance-mismatch block, never on a value that is stored or applied.
 *
 * Library-only by design (no CLI): like the executor it cannot run without its
 * MCP-backed ports, which exist only in the agent runtime that wires them (see
 * skills/reconcile-write-path.md).
 *
 * Usage (M4-5 approval command):
 *   const { applyReconcile } = require('./assets/reconcile-handler');
 *   const { results } = await applyReconcile(reconcileOps, {
 *     activeBudgetId,          // mandatory non-empty string
 *     dryRun: false,           // omit/true = simulate; explicit false = real apply
 *     schemaVersion, source,   // change-set provenance, for the audit record
 *     toolMap: {               // tool-need → namespaced tool (the registration point)
 *       update_transaction, update_transactions, reconcile_account,
 *     },
 *     toolSearch,              // async () => ToolSearch(...) — loads deferred schemas
 *     readLiveState,           // async (op) => live state (see skill doc for the shape)
 *     applyOp,                 // async (toolName, payload, op) => mcp result (real apply only)
 *     audit,                   // async ({ operation, result, dryRun }) => void
 *   });
 */

const { STATUS, isStale, singleOpOutcome } = require('./apply-executor');
const { evaluateOperation, evaluateTool } = require('./write-safety-guardrail');

/**
 * The two reconcile sub-actions. Exhaustive — anything else is an error.
 * @type {Readonly<Record<string, string>>}
 */
const SUB_ACTIONS = Object.freeze({
  MARK_CLEARED: 'mark_cleared',
  RECONCILE_ACCOUNT: 'reconcile_account',
});

/**
 * The keys the caller's `toolMap` must resolve to namespaced tool names. Kept as
 * abstract "needs" so no concrete tool name lives in this file (issue #87).
 * @type {Readonly<Record<string, string>>}
 */
const TOOL_NEEDS = Object.freeze({
  UPDATE_TRANSACTION: 'update_transaction',
  UPDATE_TRANSACTIONS: 'update_transactions',
  RECONCILE_ACCOUNT: 'reconcile_account',
});

/**
 * Stable `detail.reason` constants so consumers branch on an identifier, not prose.
 * @type {Readonly<Record<string, string>>}
 */
const REASON = Object.freeze({
  UNRECOGNIZED_SUB_ACTION: 'unrecognized_sub_action',
  STALE: 'stale',
  BALANCE_MISMATCH: 'balance_mismatch',
  ADJUSTMENT_BLOCKED: 'adjustment_would_create',
  GUARDRAIL_BLOCK: 'guardrail_block',
});

/** Default boot-patience for the deferred-schema load (overridable in tests). */
const DEFAULT_BOOT_PATIENCE = Object.freeze({ retries: 5, delayMs: 1000 });

/** Build a standard executor-shaped per-op result. */
function result(opId, status, dryRun, detail) {
  return { op_id: opId == null ? null : opId, status, dry_run: dryRun, detail };
}

/** Extract a human-readable message from a thrown value. */
function errMessage(err) {
  if (err && typeof err.message === 'string') return err.message;
  return String(err);
}

/** Milliunits → currency units for human display ONLY (never a stored/applied value). */
function toCurrency(milliunits) {
  return typeof milliunits === 'number' ? milliunits / 1000 : null;
}

/**
 * Classify a reconcile op into its sub-action by shape. `reconciled_balance`
 * presence wins (an account reconcile also carries the resulting `cleared`
 * status), so it is tested first.
 * @returns {string|null} a SUB_ACTIONS value, or null when unrecognized.
 */
function classifySubAction(op) {
  if (op === null || typeof op !== 'object') return null;
  const after = op.after;
  if (after === null || typeof after !== 'object') return null;
  if (after.reconciled_balance !== undefined && after.reconciled_balance !== null) {
    return SUB_ACTIONS.RECONCILE_ACCOUNT;
  }
  if (
    after.cleared !== undefined && after.cleared !== null
    && Array.isArray(op.transaction_ids) && op.transaction_ids.length > 0
  ) {
    return SUB_ACTIONS.MARK_CLEARED;
  }
  return null;
}

/** Index a live-state `transactions` array by id (fail-soft on a malformed list). */
function liveTxnMap(live) {
  const txns = live && typeof live === 'object' && Array.isArray(live.transactions) ? live.transactions : [];
  return new Map(txns.filter((t) => t && t.id != null).map((t) => [t.id, t]));
}

/**
 * Whether a reconcile response indicates YNAB created (or would create) a
 * balance-adjustment transaction. Fail-closed: any of these signals trips it.
 * The reconcile response shape is wired in the runtime; this defends against the
 * known adjustment markers so no silent auto-adjustment slips through.
 */
function isAdjustmentResponse(apiResult) {
  if (apiResult === null || typeof apiResult !== 'object') return false;
  return (
    apiResult.adjustment === true
    || apiResult.adjustment_transaction != null
    || apiResult.adjustment_transaction_id != null
  );
}

/** Whether a thrown value is the deferred-schema InputValidationError (boot lag). */
function isInputValidationError(err) {
  if (err == null) return false;
  if (err.name === 'InputValidationError') return true;
  return /InputValidationError/.test(err.message || String(err));
}

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Invoke ToolSearch to load the deferred YNAB schemas before the first MCP call.
 * An `InputValidationError` means the schemas are not loaded YET (the MCP can take
 * ~10s to boot), NOT that the server is down — retry with brief sleeps (boot
 * patience) rather than aborting. Any other error is a real failure and propagates.
 * A no-op when no `toolSearch` port is supplied (the runtime opted to load elsewhere).
 * @param {undefined|(()=>Promise<unknown>)} toolSearch
 * @param {{retries?:number, delayMs?:number, sleep?:(ms:number)=>Promise<void>}} [options]
 */
async function loadDeferredSchemas(toolSearch, options = {}) {
  if (typeof toolSearch !== 'function') return;
  const {
    retries = DEFAULT_BOOT_PATIENCE.retries,
    delayMs = DEFAULT_BOOT_PATIENCE.delayMs,
    sleep = wait,
  } = options;
  let lastErr;
  for (let attempt = 0; attempt <= retries; attempt += 1) {
    try {
      await toolSearch();
      return;
    } catch (err) {
      if (!isInputValidationError(err)) throw err;
      lastErr = err;
      if (attempt < retries) await sleep(delayMs);
    }
  }
  throw lastErr;
}

/**
 * Drift detection for a reconcile op (both sub-actions). Stale = live state no
 * longer matches the op's `before` snapshot the human approved against.
 *  - reconcile_account: account-level `before` ({cleared_balance, …}) vs live —
 *    reuse the executor's subset `isStale`.
 *  - mark_cleared: stale if any target transaction's live `cleared` differs from
 *    the `before.cleared` baseline. Fail-closed on a missing baseline (no
 *    `before.cleared`) or a missing/malformed live txn.
 */
function isReconcileStale(op, live, subAction) {
  if (subAction === SUB_ACTIONS.RECONCILE_ACCOUNT) {
    return isStale(op.before, live);
  }
  const baseline = op.before && typeof op.before === 'object' ? op.before.cleared : undefined;
  // No `before.cleared` baseline → we cannot prove the live state still matches what
  // the human approved against, so we must not real-apply. The schema makes
  // `before.cleared` optional (changeset-schema.json reconcileOp.before has no
  // `required`), so a schema-valid op can reach here with `before: {}`; fail CLOSED
  // (treat as stale) to stay consistent with the unresolved-target path below — never
  // overwrite a transaction's cleared status with no baseline to drift against.
  if (baseline === undefined) return true;
  const byId = liveTxnMap(live);
  return op.transaction_ids.some((id) => {
    const t = byId.get(id);
    return t == null || t.cleared !== baseline; // unresolved target → fail-closed stale
  });
}

/**
 * Real-apply guardrail (defense in depth, mirroring the executor's processOp):
 * run the op and the chosen tool through the M4-2 guardrail before dispatch.
 * @returns {object|null} a blocked result, or null when both pass.
 */
function realApplyGuard(op, activeBudgetId, toolName, opId) {
  const opVerdict = evaluateOperation(op, { activeBudgetId });
  const toolVerdict = evaluateTool(toolName);
  if (opVerdict.verdict === 'block' || toolVerdict.verdict === 'block') {
    const verdict = opVerdict.verdict === 'block' ? opVerdict : toolVerdict;
    return result(opId, STATUS.BLOCKED, false, { reason: REASON.GUARDRAIL_BLOCK, verdict });
  }
  return null;
}

/**
 * mark_cleared: dry-run returns a per-transaction before→after `cleared` diff;
 * real apply sets ONLY the `cleared` field on the target transactions.
 */
async function processMarkCleared(op, ctx, live, opId) {
  const { dryRun, toolMap = {}, applyOp, activeBudgetId } = ctx;
  const target = op.after.cleared;
  const byId = liveTxnMap(live);

  // Per-transaction before→after diff of the `cleared` field (live → target).
  const diff = op.transaction_ids.map((id) => {
    const t = byId.get(id);
    return { transaction_id: id, before: t ? t.cleared : null, after: target };
  });

  if (dryRun) {
    return result(opId, STATUS.APPLIED, true, {
      simulated: true, sub_action: SUB_ACTIONS.MARK_CLEARED, diff,
    });
  }

  const batch = op.transaction_ids.length > 1;
  const toolName = batch ? toolMap[TOOL_NEEDS.UPDATE_TRANSACTIONS] : toolMap[TOOL_NEEDS.UPDATE_TRANSACTION];

  const blocked = realApplyGuard(op, activeBudgetId, toolName, opId);
  if (blocked) return blocked;

  // Minimal patch — ONLY `cleared` per transaction; every other field is omitted,
  // so the update can never touch anything but the cleared status (field isolation).
  const payload = batch
    ? { transactions: op.transaction_ids.map((id) => ({ id, cleared: target })) }
    : { transaction_id: op.transaction_ids[0], cleared: target };

  try {
    const apiResult = await applyOp(toolName, payload, op);
    // Single-transaction update: the vendored singular `ynab_update_transaction` does
    // NOT throw on an API failure — it resolves an `{ isError: true }` MCP error
    // envelope (see apply-executor's singleOpOutcome). Inspect the resolved result
    // FAIL-CLOSED through that ONE shared executor reader (no per-path duplication) so
    // a resolved-but-unconfirmed/failed single update is recorded `error`, never
    // `applied` (issue #153). The batch branch uses the bulk tool — a separate concern
    // outside this issue's single-op scope — so it is left unchanged.
    if (!batch) {
      const { failed, message } = singleOpOutcome(apiResult);
      if (failed) {
        return result(opId, STATUS.ERROR, false, {
          phase: 'apply', tool: toolName, sub_action: SUB_ACTIONS.MARK_CLEARED, message, result: apiResult == null ? null : apiResult,
        });
      }
    }
    return result(opId, STATUS.APPLIED, false, {
      tool: toolName, sub_action: SUB_ACTIONS.MARK_CLEARED, diff, result: apiResult == null ? null : apiResult,
    });
  } catch (err) {
    return result(opId, STATUS.ERROR, false, { phase: 'apply', tool: toolName, message: errMessage(err) });
  }
}

/**
 * reconcile_account: balance guard → (dry-run plan | real reconcile) → adjustment
 * guard. The balance guard runs in BOTH modes before any reconcile call.
 */
async function processReconcileAccount(op, ctx, live, opId) {
  const { dryRun, toolMap = {}, applyOp, activeBudgetId } = ctx;
  const asserted = op.after.reconciled_balance;
  const liveCleared = live && typeof live === 'object' ? live.cleared_balance : undefined;

  // Balance guard: the live cleared balance MUST equal the asserted reconcile
  // balance. A mismatch is exactly what makes YNAB create a balance adjustment —
  // refuse it and surface the gap (in currency units) instead of reconciling.
  if (liveCleared !== asserted) {
    const gap = typeof liveCleared === 'number' ? liveCleared - asserted : null;
    return result(opId, STATUS.BLOCKED, dryRun, {
      reason: REASON.BALANCE_MISMATCH,
      sub_action: SUB_ACTIONS.RECONCILE_ACCOUNT,
      account_id: op.account_id,
      asserted_balance: asserted,
      live_cleared_balance: liveCleared == null ? null : liveCleared,
      discrepancy_milliunits: gap,
      asserted_balance_display: toCurrency(asserted),
      live_cleared_balance_display: toCurrency(liveCleared),
      discrepancy_display: toCurrency(gap),
    });
  }

  if (dryRun) {
    return result(opId, STATUS.APPLIED, true, {
      simulated: true,
      sub_action: SUB_ACTIONS.RECONCILE_ACCOUNT,
      plan: { account_id: op.account_id, reconcile_to: asserted, reconcile_to_display: toCurrency(asserted) },
      diff: { before: op.before, after: op.after },
    });
  }

  const toolName = toolMap[TOOL_NEEDS.RECONCILE_ACCOUNT];
  const blocked = realApplyGuard(op, activeBudgetId, toolName, opId);
  if (blocked) return blocked;

  let apiResult;
  try {
    apiResult = await applyOp(toolName, { account_id: op.account_id, balance: asserted }, op);
  } catch (err) {
    return result(opId, STATUS.ERROR, false, { phase: 'apply', tool: toolName, message: errMessage(err) });
  }

  // Adjustment guard: even though the balance guard already refused a mismatch,
  // refuse any reconcile response that still indicates a balance-adjustment
  // transaction — no silent auto-adjustment is permitted under any circumstances.
  if (isAdjustmentResponse(apiResult)) {
    return result(opId, STATUS.BLOCKED, false, {
      reason: REASON.ADJUSTMENT_BLOCKED,
      sub_action: SUB_ACTIONS.RECONCILE_ACCOUNT,
      account_id: op.account_id,
      message: 'YNAB reconcile response indicates a balance-adjustment transaction; '
        + 'no silent auto-adjustment is permitted — blocked for explicit human sign-off.',
      result: apiResult,
    });
  }

  return result(opId, STATUS.APPLIED, false, {
    tool: toolName, sub_action: SUB_ACTIONS.RECONCILE_ACCOUNT, result: apiResult == null ? null : apiResult,
  });
}

/**
 * Process a single reconcile op. Never throws — a read/apply failure becomes an
 * `error` result so a batch keeps going. Pipeline: classify sub-action (an
 * unrecognized one errors WITHOUT touching YNAB) → re-read live state → drift
 * check → sub-action handler.
 * @returns {Promise<{op_id:string|null, status:string, dry_run:boolean, detail:object}>}
 */
async function processReconcileOp(op, ctx = {}) {
  const dryRun = ctx.dryRun !== false;
  const opId = op && op.id != null ? op.id : null;

  const subAction = classifySubAction(op);
  if (subAction === null) {
    return result(opId, STATUS.ERROR, dryRun, {
      reason: REASON.UNRECOGNIZED_SUB_ACTION,
      message: 'reconcile op declares neither a reconcile_account (after.reconciled_balance) '
        + 'nor a mark_cleared (after.cleared with a non-empty transaction_ids) sub-action.',
    });
  }

  let live;
  try {
    live = await ctx.readLiveState(op);
  } catch (err) {
    return result(opId, STATUS.ERROR, dryRun, { phase: 'read', message: errMessage(err) });
  }

  if (isReconcileStale(op, live, subAction)) {
    return result(opId, STATUS.SKIPPED_STALE, dryRun, {
      reason: REASON.STALE, sub_action: subAction, before: op.before, live,
    });
  }

  const handlerCtx = { ...ctx, dryRun };
  return subAction === SUB_ACTIONS.MARK_CLEARED
    ? processMarkCleared(op, handlerCtx, live, opId)
    : processReconcileAccount(op, handlerCtx, live, opId);
}

/** Append one audit record per op (mirrors the executor's recordAudit / M4-3 writer). */
async function recordAudit(audit, op, res, ctx, dryRun) {
  await audit({
    operation: op,
    result: {
      tool: res.detail && res.detail.tool != null ? res.detail.tool : null,
      status: res.status,
      schema_version: ctx.schemaVersion == null ? null : ctx.schemaVersion,
      run_id: ctx.source == null ? null : ctx.source,
    },
    dryRun,
  });
}

/**
 * Apply a batch of reconcile ops. Loads the deferred YNAB schemas once (boot
 * patience) before the first MCP call, then processes each op in array order and
 * audits every attempt (dry-run and real). Dry-run by default; real apply requires
 * an explicit `dryRun: false`.
 *
 * @param {Array<object>} operations reconcile ops (already schema/guardrail-checked
 *   upstream by the M4-5 approval command; this handler adds the reconcile-specific
 *   per-op processing and the real-apply defense-in-depth guardrail).
 * @param {object} ctx see the module usage block for the full port/field contract.
 * @returns {Promise<{results:Array<object>}>}
 */
async function applyReconcile(operations, ctx = {}) {
  if (!Array.isArray(operations)) {
    throw new TypeError('applyReconcile requires an operations array');
  }
  if (typeof ctx.activeBudgetId !== 'string' || ctx.activeBudgetId.length === 0) {
    throw new TypeError('applyReconcile requires a non-empty activeBudgetId');
  }
  if (typeof ctx.readLiveState !== 'function') {
    throw new TypeError('applyReconcile requires a readLiveState(op) function');
  }
  if (typeof ctx.audit !== 'function') {
    throw new TypeError('applyReconcile requires an audit(record) function — the audit trail is mandatory');
  }
  const dryRun = ctx.dryRun !== false;
  if (!dryRun && typeof ctx.applyOp !== 'function') {
    throw new TypeError('real apply (dryRun: false) requires an applyOp(toolName, payload, op) function');
  }

  // Load deferred YNAB schemas before the first MCP call (ToolSearch + boot patience).
  await loadDeferredSchemas(ctx.toolSearch, ctx.bootPatience);

  const runCtx = { ...ctx, dryRun };
  const results = [];
  for (const op of operations) {
    const res = await processReconcileOp(op, runCtx);
    await recordAudit(ctx.audit, op, res, ctx, dryRun);
    results.push(res);
  }
  return { results };
}

/**
 * The registration descriptor M4-5 wires into its op-type → handler dispatch.
 * `process` handles one op; `apply` runs a batch with schema-load + audit.
 */
const reconcileHandler = Object.freeze({
  op_type: 'reconcile',
  sub_actions: Object.freeze([SUB_ACTIONS.MARK_CLEARED, SUB_ACTIONS.RECONCILE_ACCOUNT]),
  process: processReconcileOp,
  apply: applyReconcile,
});

module.exports = {
  SUB_ACTIONS,
  TOOL_NEEDS,
  REASON,
  classifySubAction,
  isAdjustmentResponse,
  isInputValidationError,
  loadDeferredSchemas,
  isReconcileStale,
  processReconcileOp,
  applyReconcile,
  reconcileHandler,
};
