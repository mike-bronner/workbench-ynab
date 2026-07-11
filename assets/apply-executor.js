'use strict';

/**
 * Apply executor for workbench-ynab write-back (M4-4).
 *
 * The shared machinery every write path (categorize / allocate / dedupe /
 * reconcile — M4-6..M4-9) runs through: validate a change-set, run it through
 * the write-safety guardrail, then either SIMULATE (dry-run) or actually invoke
 * the namespaced YNAB MCP tools, recording every result to the audit log. Built
 * once here so each downstream write path only supplies its op-type → tool
 * mapping, not its own bespoke apply loop.
 *
 * Design rules:
 *  - DRY-RUN BY DEFAULT. `dryRun` is true unless the caller passes an explicit
 *    `false`. A dry-run resolves entities and produces a simulated diff but calls
 *    NO mutating tool. Real apply is opt-in (the M4-5 approval command flips it
 *    only after explicit human approval).
 *  - FAIL-CLOSED at the guardrail. The whole change-set runs through
 *    `evaluateChangeset` first; a single blocked operation aborts the ENTIRE
 *    batch — nothing is applied past (or around) a block.
 *  - PURE ORCHESTRATOR, INJECTED I/O. This module owns the control flow but holds
 *    no MCP or filesystem coupling: the side-effecting operations are injected as
 *    ports — `readLiveState(op)` (read-only entity resolution + drift detection),
 *    `applyOp(toolName, op)` (the mutating dispatch), and `audit(record)` (the
 *    append-only evidence trail, M4-3). That keeps it unit-testable and, with the
 *    op→tool `toolMap` supplied by the caller, keeps every concrete tool name out
 *    of this file (the swap-ready single-source-of-truth invariant, issue #87).
 *  - NAMESPACED TOOLS ONLY, never hard-coded here. The caller resolves the
 *    op-type → `mcp__plugin_workbench-ynab_ynab__*` mapping from
 *    `skills/protocol/ynab-tools.md` and passes it as `toolMap`; before every real
 *    dispatch the executor runs the supplied tool name through the guardrail's
 *    `evaluateTool`, so a bare `mcp__ynab__*` name or any non-allow-listed tool is
 *    blocked fail-closed.
 *  - MILLIUNITS THROUGHOUT. Monetary values (`before`/`after`/diff) are passed
 *    through verbatim as integer milliunits; the executor never does arithmetic on
 *    an amount, so no float conversion can occur on the apply or dry-run path.
 *
 * Library-only by design: there is no CLI. The executor cannot run without its
 * MCP-backed ports, which exist only in the agent runtime that wires them (see
 * skills/apply-executor.md). The change-set validator (assets/validate-changeset.js)
 * and the guardrail (assets/write-safety-guardrail.js) keep their CLIs; this does
 * not.
 *
 *  - OPT-IN BULK DISPATCH. By default the executor applies one op per tool call
 *    (`applyOp`). A write path that can collapse many same-type ops into a single
 *    call (e.g. categorize → `ynab_update_transactions`) opts in by supplying a
 *    `bulkToolMap` (op-type → bulk tool), a `bulkApplyOp(toolName, ops)` port, and
 *    a `bulkFits(ops)` predicate. The executor still drift-checks, guardrails, and
 *    audits EACH op individually — only the mutating dispatch of the survivors is
 *    batched. If `bulkApplyOp` throws (the bulk shape was rejected at runtime), the
 *    executor falls back to a per-op `applyOp` call for each op in that group, so a
 *    bulk-capable path is never less safe than a per-op one. A bulk call that
 *    RESOLVES is not assumed to have applied every op: the executor inspects the
 *    result's per-entry `results` (and top-level `success`) and audits any failed
 *    entry as `error`, so the M4-3 trail never records `applied` for a transaction
 *    the tool reported as failed.
 *
 * Usage (M4-5 approval command, M4-6..M4-9 write paths):
 *   const { applyChangeset } = require('./assets/apply-executor');
 *   const outcome = await applyChangeset(changeset, {
 *     activeBudgetId,                  // mandatory non-empty string; throws if missing
 *     dryRun: false,                   // omit/true = simulate; explicit false = real apply
 *     toolMap: { categorize: '<namespaced tool>', ... },  // the registration point
 *     readLiveState: async (op) => ({ ...fields shaped like op.before }),
 *     applyOp: async (toolName, op) => ({ ...mcp result }),  // real apply only
 *     audit: async ({ operation, result, dryRun }) => { ... },
 *     // Optional bulk capability (categorize / any batchable write path):
 *     bulkToolMap: { categorize: '<namespaced bulk tool>', ... },
 *     bulkApplyOp: async (toolName, ops) => ({ ...mcp result }),  // one call for the group
 *     bulkFits: (ops) => ops.length >= 2 && ops.every(canFormOneBulkEntry),
 *   });
 *   // outcome.results: [{ op_id, status, dry_run, detail }, ...]
 */

const { validateChangeset } = require('./validate-changeset');
const {
  evaluateChangeset,
  evaluateOperation,
  evaluateTool,
} = require('./write-safety-guardrail');

/**
 * The per-operation result statuses. This is the contract M4-5 renders for the
 * human; the four values are exhaustive.
 * @type {Readonly<Record<string, string>>}
 */
const STATUS = Object.freeze({
  APPLIED: 'applied',
  SKIPPED_STALE: 'skipped-stale',
  BLOCKED: 'blocked',
  ERROR: 'error',
});

/**
 * Top-level outcome reasons. `ok` is true only for the two *_COMPLETE reasons.
 * @type {Readonly<Record<string, string>>}
 */
const OUTCOME = Object.freeze({
  SCHEMA_INVALID: 'schema_invalid',
  GUARDRAIL_BLOCK: 'guardrail_block',
  TOOL_BLOCK: 'tool_block',
  DRY_RUN_COMPLETE: 'dry_run_complete',
  APPLY_COMPLETE: 'apply_complete',
});

/**
 * Dependency-free deep structural equality. Used for drift detection, so it must
 * compare integer milliunits exactly (via ===) and never coerce a number to a
 * float. Handles primitives, arrays, and plain objects; key order independent.
 * @param {unknown} a
 * @param {unknown} b
 * @returns {boolean}
 */
function deepEqual(a, b) {
  if (a === b) return true;
  if (a === null || b === null || typeof a !== 'object' || typeof b !== 'object') return false;
  const aArr = Array.isArray(a);
  if (aArr !== Array.isArray(b)) return false;
  if (aArr) {
    if (a.length !== b.length) return false;
    return a.every((entry, i) => deepEqual(entry, b[i]));
  }
  const aKeys = Object.keys(a);
  if (aKeys.length !== Object.keys(b).length) return false;
  return aKeys.every(
    (k) => Object.prototype.hasOwnProperty.call(b, k) && deepEqual(a[k], b[k]),
  );
}

/**
 * Drift detection. An operation is STALE when live state no longer matches the
 * `before` snapshot it was generated against — only the fields the op actually
 * snapshotted in `before` are compared (it proposes a change from a known prior
 * value of exactly those fields; unrelated live fields are irrelevant).
 *
 * Fail-closed: a `before` or `live` that is not a comparable object is treated as
 * drift, so a real apply skips it rather than clobber a value the human never saw.
 * @param {unknown} before the op's read-only `before` snapshot.
 * @param {unknown} live   the freshly re-read live state (from readLiveState).
 * @returns {boolean} true when the op is stale.
 */
function isStale(before, live) {
  if (before === null || typeof before !== 'object' || Array.isArray(before)) return true;
  if (live === null || typeof live !== 'object' || Array.isArray(live)) return true;
  return Object.keys(before).some((key) => !deepEqual(before[key], live[key]));
}

/** Extract a human-readable message from a thrown value. */
function errMessage(err) {
  if (err && typeof err.message === 'string') return err.message;
  return String(err);
}

/**
 * PREPARE one operation (both modes): re-read live state and drift-check, plus —
 * on the real-apply path — the defense-in-depth per-op guardrail. Returns
 * `{ ready: true }` when the op has survived and should be dispatched, or
 * `{ result }` carrying a terminal per-op result (`error` / `skipped-stale` /
 * `blocked`). Never throws — a read failure becomes an `error` result so the rest
 * of the batch still proceeds. Dispatch (simulate / apply / bulk) is decided by
 * the caller AFTER every op is prepared, so the survivors can be batched.
 * @returns {Promise<{ready:true}|{result:{op_id:string|null, status:string, dry_run:boolean, detail:object}}>}
 */
async function prepareOp(op, { activeBudgetId, dryRun, toolMap, readLiveState }) {
  const opId = op.id == null ? null : op.id;

  // Re-read live state before processing (both modes). A read failure is a per-op error.
  let live;
  try {
    live = await readLiveState(op);
  } catch (err) {
    return { result: { op_id: opId, status: STATUS.ERROR, dry_run: dryRun, detail: { phase: 'read', message: errMessage(err) } } };
  }

  // Drift detection — compare live to the op's `before` snapshot.
  if (isStale(op.before, live)) {
    return { result: { op_id: opId, status: STATUS.SKIPPED_STALE, dry_run: dryRun, detail: { reason: 'stale', before: op.before, live } } };
  }

  // Dry-run never dispatches — the survivor is simulated in the dispatch phase.
  if (dryRun) return { ready: true };

  // Real apply: re-run the guardrail adjacent to the call site (consumer contract —
  // evaluateOperation AND evaluateTool before each individual tool call). The
  // upfront evaluateChangeset + tool pre-flight already guarantee a pass here, so
  // this is defense-in-depth that must never fire; if it does, refuse the op.
  const opVerdict = evaluateOperation(op, { activeBudgetId });
  const toolVerdict = evaluateTool(toolMap[op.type]);
  if (opVerdict.verdict === 'block' || toolVerdict.verdict === 'block') {
    return {
      result: {
        op_id: opId,
        status: STATUS.BLOCKED,
        dry_run: false,
        detail: { reason: 'guardrail_block', verdict: opVerdict.verdict === 'block' ? opVerdict : toolVerdict },
      },
    };
  }
  return { ready: true };
}

/** A dry-run simulated diff for one prepared (survivor) op — no mutating tool invoked. */
function simulateResult(op, dryRun) {
  return {
    op_id: op.id == null ? null : op.id,
    status: STATUS.APPLIED,
    dry_run: dryRun,
    detail: { simulated: true, diff: { before: op.before, after: op.after } },
  };
}

/** Dispatch one survivor via the per-op mutating tool. Never throws. */
async function applyOneOp(op, { toolMap, applyOp }) {
  const opId = op.id == null ? null : op.id;
  const toolName = toolMap[op.type];
  try {
    const result = await applyOp(toolName, op);
    return { op_id: opId, status: STATUS.APPLIED, dry_run: false, detail: { tool: toolName, result: result == null ? null : result } };
  } catch (err) {
    return { op_id: opId, status: STATUS.ERROR, dry_run: false, detail: { phase: 'apply', tool: toolName, message: errMessage(err) } };
  }
}

/**
 * Read a resolved bulk result and decide each op's real per-entry outcome. A bulk
 * tool that RESOLVES is NOT proof every op was mutated: the vendored
 * `ynab_update_transactions` does not throw on a partial failure — it returns
 * `{ success, summary: { failed }, results: [{ request_index, status,
 * transaction_id, error, error_code, ... }] }`, where a per-entry
 * `status: "failed"` marks a transaction that was NEVER mutated. Each op is
 * correlated to its entry by `request_index` (the index into the request array,
 * which is `ops` order), falling back to `transaction_id`, then position. When the
 * payload carries no per-entry `results`, a top-level `success === false` fails the
 * whole group closed.
 * @param {unknown} result the resolved bulk-call payload.
 * @returns {(op: object, i: number) => {failed: boolean, entry: object|null}}
 */
function bulkOutcomeReader(result) {
  const entries = result && Array.isArray(result.results) ? result.results : null;
  const overallFailed = result != null && result.success === false;
  return (op, i) => {
    if (!entries) return { failed: overallFailed, entry: null };
    const entry = entries.find((e) => e && e.request_index === i)
      || entries.find((e) => e && e.transaction_id != null && e.transaction_id === op.transaction_id)
      || entries[i]
      || null;
    if (!entry) return { failed: overallFailed, entry: null };
    return { failed: entry.status === 'failed', entry };
  };
}

/**
 * Dispatch a group of same-type survivors as a SINGLE bulk call. Two failure modes,
 * both handled so the mandatory M4-3 audit trail never records `applied` for a
 * mutation that did not happen:
 *  - the bulk SHAPE is rejected (a thrown Error) → fall back to per-op `applyOp`
 *    calls (safe only because a bulk-capable write path opts in for idempotent ops —
 *    a re-applied categorize is a no-op-equivalent);
 *  - the bulk call RESOLVES but reports per-entry failures → each failed entry maps
 *    to an `error` result, not a blanket `applied`.
 * Each op still got its own drift check, guardrail, and audit in the surrounding
 * loop — only the mutating dispatch is batched here. Never throws.
 * @returns {Promise<Array<object>>} one result per op, in the group's order.
 */
async function applyBulkGroup(ops, { bulkToolMap, bulkApplyOp, toolMap, applyOp }) {
  const bulkTool = bulkToolMap[ops[0].type];
  let result;
  try {
    result = await bulkApplyOp(bulkTool, ops);
  } catch (err) {
    const out = [];
    for (const op of ops) out.push(await applyOneOp(op, { toolMap, applyOp }));
    return out;
  }
  // Resolved — but inspect the payload: a resolved bulk result can still report
  // per-entry FAILURES without throwing.
  const read = bulkOutcomeReader(result);
  return ops.map((op, i) => {
    const opId = op.id == null ? null : op.id;
    const { failed, entry } = read(op, i);
    if (failed) {
      const message = (entry && (entry.error || entry.error_code)) || 'bulk update reported failure without a per-entry error';
      return { op_id: opId, status: STATUS.ERROR, dry_run: false, detail: { phase: 'apply', tool: bulkTool, bulk: true, message, result: entry == null ? (result == null ? null : result) : entry } };
    }
    return { op_id: opId, status: STATUS.APPLIED, dry_run: false, detail: { tool: bulkTool, bulk: true, result: result == null ? null : result } };
  });
}

/**
 * Append one audit record for an operation the executor acted on. Mirrors the
 * `_audit_append <operation_json> <result_json> <dry_run>` writer in
 * bin/audit-log.sh (M4-3): the caller wires `audit` to that bash helper. Called
 * once per op processed in the loop — dry-run and real, applied and skipped —
 * so every attempt leaves a paper trail with `dry_run` stamped.
 */
async function recordAudit(audit, op, result, changeset, toolMap, dryRun) {
  // Record the tool that ACTUALLY ran when the result names one (a bulk dispatch
  // records the bulk tool, not the per-op tool); otherwise fall back to the op's
  // registered per-op tool (dry-run / skipped / blocked ops name no tool).
  const tool = result && result.detail && typeof result.detail.tool === 'string'
    ? result.detail.tool
    : (toolMap[op.type] == null ? null : toolMap[op.type]);
  await audit({
    operation: op,
    result: {
      tool,
      status: result.status,
      schema_version: changeset.schema_version == null ? null : changeset.schema_version,
      run_id: changeset.source == null ? null : changeset.source,
    },
    dryRun,
  });
}

/**
 * Apply a change-set. Dry-run by default; real apply requires `dryRun: false`.
 *
 * Pipeline: schema-validate → whole-batch guardrail (fail-closed, aborts on any
 * block) → real-apply tool pre-flight (all-or-aborted) → per-op loop (re-read,
 * drift-check, simulate or dispatch, audit). Returns a structured outcome with one
 * result entry per operation.
 *
 * @param {object} changeset the change-set envelope (assets/changeset-schema.json).
 * @param {object} options
 * @param {string} options.activeBudgetId MANDATORY non-empty string — throws if missing;
 *   the guardrail asserts the change-set targets this budget (cross-budget safety).
 * @param {boolean} [options.dryRun=true] real apply requires an explicit `false`.
 * @param {Record<string,string>} [options.toolMap={}] op-type → namespaced mutating tool
 *   (the registration point; supplied by M4-6..M4-9, never hard-coded here).
 * @param {(op:object)=>(object|Promise<object>)} options.readLiveState REQUIRED — resolves
 *   live entity state for drift detection (read-only namespaced MCP reads).
 * @param {(toolName:string, op:object)=>(unknown|Promise<unknown>)} [options.applyOp] REQUIRED
 *   when dryRun is false — dispatches the mutating tool for one op.
 * @param {Record<string,string>} [options.bulkToolMap={}] op-type → namespaced BULK tool.
 *   Supplying it (with bulkApplyOp + bulkFits) opts an op type into single-call batch
 *   dispatch of its survivors; every op is still drift-checked, guardrailed, and audited.
 * @param {(toolName:string, ops:object[])=>(unknown|Promise<unknown>)} [options.bulkApplyOp]
 *   dispatches one bulk tool call for a group of same-type survivors; a throw falls back
 *   to per-op applyOp for that group (safe for idempotent writes).
 * @param {(ops:object[])=>boolean} [options.bulkFits] predicate: may this group of same-type
 *   survivors go through one bulk call? False → the group applies per-op.
 * @param {(record:{operation:object, result:object, dryRun:boolean})=>(void|Promise<void>)}
 *   options.audit REQUIRED — the append-only audit sink (M4-3).
 * @returns {Promise<{ok:boolean, dry_run:boolean, aborted:boolean, reason:string,
 *   validation?:object, guardrail?:object, toolBlocks?:Array<object>,
 *   results:Array<{op_id:string|null, status:string, dry_run:boolean, detail:object}>}>}
 */
async function applyChangeset(changeset, options = {}) {
  const {
    activeBudgetId, dryRun = true, toolMap = {}, readLiveState, applyOp, audit,
    bulkToolMap = {}, bulkApplyOp, bulkFits,
  } = options;

  // Contract — fail fast on a misconfigured caller before touching the change-set.
  // activeBudgetId is MANDATORY: the caller resolves the active budget (the one the
  // human approved against) and the guardrail asserts the change-set targets it.
  // Falling back to the envelope's own budget_id would defeat that cross-budget
  // check (a change-set always matches itself), so a missing one is a hard error,
  // not a silent default — the guardrail's documented fail-closed M4-4 contract.
  if (typeof activeBudgetId !== 'string' || activeBudgetId.length === 0) {
    throw new TypeError('applyChangeset requires a non-empty activeBudgetId — the guardrail fails closed without it');
  }
  if (typeof readLiveState !== 'function') {
    throw new TypeError('applyChangeset requires a readLiveState(op) function');
  }
  if (typeof audit !== 'function') {
    throw new TypeError('applyChangeset requires an audit(record) function — the audit trail is mandatory');
  }
  if (!dryRun && typeof applyOp !== 'function') {
    throw new TypeError('real apply (dryRun: false) requires an applyOp(toolName, op) function');
  }

  // 1. Schema validation — reject malformed input and call NO ports.
  const validation = validateChangeset(changeset);
  if (!validation.valid) {
    return { ok: false, dry_run: dryRun, aborted: true, reason: OUTCOME.SCHEMA_INVALID, validation, results: [] };
  }

  // 2. Whole-batch guardrail (fail-closed). A single block aborts the ENTIRE batch.
  const guardrail = evaluateChangeset(changeset, { activeBudgetId });
  if (guardrail.verdict === 'block') {
    const blocked = new Map(guardrail.blocks.filter((b) => b.op_id != null).map((b) => [b.op_id, b]));
    const results = changeset.operations.map((op) => {
      const verdict = op.id != null ? blocked.get(op.id) : undefined;
      return {
        op_id: op.id == null ? null : op.id,
        status: STATUS.BLOCKED,
        dry_run: dryRun,
        detail: verdict ? { reason: 'guardrail_block', verdict } : { reason: 'batch_aborted' },
      };
    });
    return { ok: false, dry_run: dryRun, aborted: true, reason: OUTCOME.GUARDRAIL_BLOCK, guardrail, results };
  }

  // 3. Real-apply tool pre-flight — resolve and guardrail-check every mutating tool
  //    BEFORE applying anything, so a misconfigured/denied toolMap aborts the whole
  //    batch all-or-nothing (never a partial apply around a tool block). Dry-run
  //    never dispatches a mutating tool, so it skips this. A bulk-capable op type is
  //    checked on BOTH its per-op tool and its bulk tool — the bulk path falls back to
  //    the per-op tool, so both must be allow-listed for the group to be safe.
  if (!dryRun) {
    const toolBlocks = [];
    for (const op of changeset.operations) {
      const opId = op.id == null ? null : op.id;
      const singleVerdict = evaluateTool(toolMap[op.type]);
      if (singleVerdict.verdict === 'block') {
        toolBlocks.push({ op_id: opId, op_type: op.type, verdict: singleVerdict });
        continue;
      }
      const bulkTool = bulkToolMap[op.type];
      if (bulkTool !== undefined) {
        const bulkVerdict = evaluateTool(bulkTool);
        if (bulkVerdict.verdict === 'block') toolBlocks.push({ op_id: opId, op_type: op.type, verdict: bulkVerdict });
      }
    }
    if (toolBlocks.length > 0) {
      const blocked = new Map(toolBlocks.map((t) => [t.op_id, t.verdict]));
      const results = changeset.operations.map((op) => {
        const opId = op.id == null ? null : op.id;
        return {
          op_id: opId,
          status: STATUS.BLOCKED,
          dry_run: false,
          detail: blocked.has(opId) ? { reason: 'tool_block', verdict: blocked.get(opId) } : { reason: 'batch_aborted' },
        };
      });
      return { ok: false, dry_run: false, aborted: true, reason: OUTCOME.TOOL_BLOCK, toolBlocks, results };
    }
  }

  // 4. Prepare every op (read → drift-check → per-op guardrail), preserving array
  //    order, so the survivors are known before any dispatch and can be batched.
  const prepared = [];
  for (const op of changeset.operations) {
    prepared.push({ op, prep: await prepareOp(op, { activeBudgetId, dryRun, toolMap, readLiveState }) });
  }

  // 5. Dispatch the survivors. Terminal (error/skipped-stale/blocked) results are
  //    already set; each survivor is filled in by index so array order is preserved.
  const resultByIndex = new Array(prepared.length);
  const readyIndices = [];
  prepared.forEach(({ prep }, i) => {
    if (prep.result) resultByIndex[i] = prep.result;
    else readyIndices.push(i);
  });

  if (dryRun) {
    // No mutating dispatch — every survivor is simulated (diff only).
    for (const i of readyIndices) resultByIndex[i] = simulateResult(prepared[i].op, true);
  } else {
    // Group survivors by op-type; a type with a bulk port whose group `bulkFits`
    // goes through ONE bulk call, else each op applies per-op. Grouping preserves
    // each op's original index for order-stable result placement.
    const groups = new Map();
    for (const i of readyIndices) {
      const type = prepared[i].op.type;
      if (!groups.has(type)) groups.set(type, []);
      groups.get(type).push(i);
    }
    for (const [type, indices] of groups) {
      const ops = indices.map((i) => prepared[i].op);
      const canBulk = typeof bulkApplyOp === 'function' && bulkToolMap[type] !== undefined
        && typeof bulkFits === 'function' && bulkFits(ops);
      if (canBulk) {
        const groupResults = await applyBulkGroup(ops, { bulkToolMap, bulkApplyOp, toolMap, applyOp });
        indices.forEach((i, k) => { resultByIndex[i] = groupResults[k]; });
      } else {
        for (const i of indices) resultByIndex[i] = await applyOneOp(prepared[i].op, { toolMap, applyOp });
      }
    }
  }

  // 6. Audit every op once, in array order — dry-run and real, applied and skipped.
  const results = [];
  for (let i = 0; i < prepared.length; i += 1) {
    await recordAudit(audit, prepared[i].op, resultByIndex[i], changeset, toolMap, dryRun);
    results.push(resultByIndex[i]);
  }

  return {
    ok: true,
    dry_run: dryRun,
    aborted: false,
    reason: dryRun ? OUTCOME.DRY_RUN_COMPLETE : OUTCOME.APPLY_COMPLETE,
    results,
  };
}

module.exports = {
  STATUS,
  OUTCOME,
  deepEqual,
  isStale,
  applyChangeset,
};
