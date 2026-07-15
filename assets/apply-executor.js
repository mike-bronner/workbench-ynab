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
 *  - AUTH FAIL-CLOSED, both ends (real apply only, GAP-8 / #50). A preflight
 *    read-only call (`authPreflight`, e.g. ynab_list_budgets) runs BEFORE the first
 *    mutation; any failure aborts with zero mutations and no per-op audit records.
 *    And if a 401/403 surfaces mid-batch, the loop STOPS immediately (the token is
 *    bad — continuing would just fail every remaining op). An auth failure aborts the
 *    whole batch; a single-op data error (422), a rate limit (429), or an
 *    indeterminate 5xx / network fault is recorded per-op and the batch CONTINUES —
 *    two mutually-exclusive policies. Every errored op's audit record carries an
 *    `error_class` and `applied_state` (the substrate the resume design, #48, reads).
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
 *    RESOLVES is not assumed to have applied every op, and it is read FAIL-CLOSED:
 *    the executor confirms `applied` ONLY for an op whose own per-entry `results`
 *    record reports a written status (created / duplicate / updated). A failed
 *    entry, an op with no matching entry, a `results` array that does not line up
 *    one-to-one with the request, or a payload with no `results` array at all are
 *    ALL audited as `error` — so the M4-3 trail never records `applied` for a
 *    transaction the tool did not positively confirm.
 *
 * Usage (M4-5 approval command, M4-6..M4-9 write paths):
 *   const { applyChangeset } = require('./assets/apply-executor');
 *   const outcome = await applyChangeset(changeset, {
 *     activeBudgetId,                  // mandatory non-empty string; throws if missing
 *     dryRun: false,                   // omit/true = simulate; explicit false = real apply
 *     toolMap: { categorize: '<namespaced tool>', ... },  // the registration point
 *     readLiveState: async (op) => ({ ...fields shaped like op.before }),
 *     applyOp: async (toolName, op) => ({ ...mcp result }),  // real apply only
 *     authPreflight: async () => ({ ...ynab_list_budgets result }),  // real apply only
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
const {
  APPLIED_STATE,
  classifyError,
  isAuthFailure,
  remediation,
  throwOnErrorResult,
} = require('./write-error');

/**
 * The per-operation result statuses. This is the contract M4-5 renders for the
 * human; the five values are exhaustive. The executor itself emits the first
 * four; HUMAN_REVIEW_REQUIRED is emitted by a handler's pre-flight (the M4-6
 * categorize handler refusing a split parent or a transfer leg, GAP-19 / #49)
 * for an op that must be routed to the human instead of applied — never
 * auto-modified, never a hard error.
 * @type {Readonly<Record<string, string>>}
 */
const STATUS = Object.freeze({
  APPLIED: 'applied',
  SKIPPED_STALE: 'skipped-stale',
  BLOCKED: 'blocked',
  ERROR: 'error',
  HUMAN_REVIEW_REQUIRED: 'human_review_required',
});

/**
 * Top-level outcome reasons. `ok` is true only for the two *_COMPLETE reasons.
 * @type {Readonly<Record<string, string>>}
 */
const OUTCOME = Object.freeze({
  SCHEMA_INVALID: 'schema_invalid',
  GUARDRAIL_BLOCK: 'guardrail_block',
  TOOL_BLOCK: 'tool_block',
  AUTH_PREFLIGHT_FAIL: 'auth_preflight_fail',
  AUTH_ABORT: 'auth_abort',
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

  // Re-read live state before processing (both modes). A read failure is a per-op
  // error, classified so an auth failure (a dead token surfaces on the read too)
  // aborts the batch and the audit record carries error_class / applied_state.
  let live;
  try {
    live = await readLiveState(op);
  } catch (err) {
    const { error_class, applied_state } = classifyError(err);
    return { result: { op_id: opId, status: STATUS.ERROR, dry_run: dryRun, detail: { phase: 'read', message: errMessage(err), error_class, applied_state } } };
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
    // Classify the mutation failure: error_class drives the abort-vs-continue
    // decision in the loop (auth → abort; data error / rate limit / 5xx → per-op
    // error, continue) and applied_state (not_applied vs unknown) lets a later
    // resume reason about whether the mutation may have landed.
    const { error_class, applied_state } = classifyError(err);
    return { op_id: opId, status: STATUS.ERROR, dry_run: false, detail: { phase: 'apply', tool: toolName, message: errMessage(err), error_class, applied_state } };
  }
}

/**
 * The bulk per-entry statuses that CONFIRM a mutation. The vendored
 * `ynab_update_transactions` reports one of created / duplicate / updated / failed
 * per entry; only these three positively confirm the transaction was written.
 * Anything else (a `failed` entry, an unknown status, or no entry at all) is
 * unconfirmed and must fail closed — never recorded `applied`.
 * @type {ReadonlySet<string>}
 */
const BULK_APPLIED_STATUSES = new Set(['created', 'duplicate', 'updated']);

/**
 * Read a resolved bulk result and decide each op's real per-entry outcome, FAILING
 * CLOSED. A bulk tool that RESOLVES is NOT proof every op was mutated: the vendored
 * `ynab_update_transactions` does not throw on a partial failure — it returns
 * `{ success, summary: { failed }, results: [{ request_index, status,
 * transaction_id, error, error_code, ... }] }`, where a per-entry status of
 * created/duplicate/updated confirms a mutation, `failed` marks one that never
 * happened, and top-level `success === (summary.failed === 0)`.
 *
 * An op is `applied` ONLY when the payload is well-shaped — a `results` array
 * carrying exactly one entry per requested op — AND that op's own entry reports a
 * confirmed status. Every other case fails CLOSED (`failed: true`, `unconfirmed`):
 *  - no `results` array at all (an off-contract / `{}` payload);
 *  - a `results` array whose length ≠ the request length (entries can't line up);
 *  - an op with no matching entry, or an entry whose status isn't a confirmed apply.
 * The audit trail must never record `applied` for a mutation the tool did not
 * positively confirm — an unshaped-but-resolved payload is the worst failure
 * direction, so it is treated as an unconfirmed error, never a blanket success.
 * Each op is correlated to its entry by `request_index` (the index into the request
 * array, which is `ops` order), falling back to `transaction_id`, then position.
 * @param {unknown} result the resolved bulk-call payload.
 * @param {number} opsCount how many ops went into the request (the shape cross-check).
 * @returns {(op: object, i: number) => {failed: boolean, entry: object|null, unconfirmed: boolean}}
 */
function bulkOutcomeReader(result, opsCount) {
  const entries = result && Array.isArray(result.results) ? result.results : null;
  // Fail closed unless the payload lines up one-to-one with the request.
  const shapeOk = entries != null && entries.length === opsCount;
  return (op, i) => {
    if (!shapeOk) return { failed: true, entry: null, unconfirmed: true };
    const entry = entries.find((e) => e && e.request_index === i)
      || entries.find((e) => e && e.transaction_id != null && e.transaction_id === op.transaction_id)
      || entries[i]
      || null;
    if (!entry || !BULK_APPLIED_STATUSES.has(entry.status)) {
      return { failed: true, entry: entry || null, unconfirmed: entry == null };
    }
    return { failed: false, entry, unconfirmed: false };
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
    // The bulk dispatch threw. Fall back to per-op applyOp so the survivors still apply
    // individually (safe — a bulk-capable path opts in for idempotent ops) — BUT stop the
    // moment a per-op call itself auth-fails, mirroring the outer dispatch abort. Before
    // the isError→throw port wiring (#50), a whole-bulk 401/403 came back as a RESOLVED
    // `{ isError: true }` envelope and never entered this catch; now it throws, so it
    // lands here too. Re-dispatching the WHOLE group against a dead token would (a)
    // violate AC #3 (attempt every remaining op on a revoked credential) and (b) risk an
    // un-audited apply if a later op flakily succeeded after an earlier one auth-failed
    // and the outer loop had already broken past its index. Breaking on the first
    // auth-classified result records that op and leaves the rest un-dispatched.
    const out = [];
    for (const op of ops) {
      const res = await applyOneOp(op, { toolMap, applyOp });
      out.push(res);
      if (res.status === STATUS.ERROR && isAuthFailure(res.detail.error_class)) break;
    }
    return out;
  }
  // Resolved — but inspect the payload FAIL-CLOSED: a resolved bulk result can
  // still report per-entry failures, omit an op's entry, or be off-contract
  // entirely, none of which throw. Only a positively-confirmed entry is `applied`.
  const read = bulkOutcomeReader(result, ops.length);
  return ops.map((op, i) => {
    const opId = op.id == null ? null : op.id;
    const { failed, entry, unconfirmed } = read(op, i);
    if (failed) {
      const message = (entry && (entry.error || entry.error_code))
        || (unconfirmed
          ? 'bulk update resolved without confirming this op — no matching per-entry result; recorded error, not applied (fail-closed)'
          : 'bulk update reported this entry as failed');
      // AC #4: a bulk per-entry failure still needs an audit-grade error_class /
      // applied_state — never null. A RESOLVED bulk call means the HTTP request itself
      // succeeded, so a per-entry failure is a data-level rejection, never an auth /
      // rate class — hence classifyError stamps `unknown` here. applied_state comes from
      // what the payload proves (the classifier can't see it on a non-thrown envelope):
      // an entry YNAB positively marked `failed` did NOT apply → not_applied; an
      // unconfirmed / off-contract / missing entry is indeterminate → unknown (the safe
      // resume direction for #48).
      const { error_class } = classifyError(entry);
      const applied_state = entry && entry.status === 'failed'
        ? APPLIED_STATE.NOT_APPLIED
        : APPLIED_STATE.UNKNOWN;
      return { op_id: opId, status: STATUS.ERROR, dry_run: false, detail: { phase: 'apply', tool: bulkTool, bulk: true, message, error_class, applied_state, result: entry == null ? (result == null ? null : result) : entry } };
    }
    return { op_id: opId, status: STATUS.APPLIED, dry_run: false, detail: { tool: bulkTool, bulk: true, result: entry } };
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
  const detail = result.detail || {};
  // Record the tool that ACTUALLY ran when the result names one (a bulk dispatch
  // records the bulk tool, not the per-op tool); otherwise fall back to the op's
  // registered per-op tool (dry-run / skipped / blocked ops name no tool).
  const tool = typeof detail.tool === 'string'
    ? detail.tool
    : (toolMap[op.type] == null ? null : toolMap[op.type]);
  await audit({
    operation: op,
    result: {
      tool,
      status: result.status,
      schema_version: changeset.schema_version == null ? null : changeset.schema_version,
      run_id: changeset.source == null ? null : changeset.source,
      // Present only on an errored op; null everywhere else. These two fields are
      // the substrate the idempotent-resume design (#48) reads to reason about a
      // failed op without re-querying — so they flow all the way to the audit log.
      error_class: detail.error_class == null ? null : detail.error_class,
      applied_state: detail.applied_state == null ? null : detail.applied_state,
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
 * @param {()=>(unknown|Promise<unknown>)} [options.authPreflight] REQUIRED when dryRun is
 *   false — a read-only YNAB call (e.g. ynab_list_budgets) that confirms the token is
 *   valid and write-capable before the first mutation. It must THROW on a non-2xx /
 *   network failure; any throw aborts the whole batch before any op is dispatched.
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
 *   authFailure?:object, total_ops?:number, stopped_at_index?:number,
 *   results:Array<{op_id:string|null, status:string, dry_run:boolean, detail:object}>}>}
 */
async function applyChangeset(changeset, options = {}) {
  const {
    activeBudgetId, dryRun = true, toolMap = {}, readLiveState, applyOp, authPreflight, audit,
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
  if (!dryRun && typeof authPreflight !== 'function') {
    throw new TypeError('real apply (dryRun: false) requires an authPreflight() function — the preflight auth-check is mandatory before any mutation');
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

  // 3.5. Auth preflight (real apply only) — a cheap read-only YNAB call BEFORE the
  //      first mutation confirms the token is valid and write-capable. Any failure
  //      (401 / 403 / network) aborts the whole batch: zero mutations are attempted
  //      and NO audit record is written for ops that never ran (#50 AC #2). Dry-run
  //      never mutates, so it skips the preflight entirely.
  if (!dryRun) {
    try {
      // Defense in depth (#50): route the preflight result through throwOnErrorResult so a
      // vendored `{ isError: true }` auth envelope that RESOLVED (didn't reject) still
      // aborts fail-closed here — the same guard the categorize port wrappers apply, now
      // code-enforced at the executor's shared preflight gate for every path that routes
      // through it (categorize / delete / allocate).
      throwOnErrorResult(await authPreflight());
    } catch (err) {
      const { error_class, applied_state } = classifyError(err);
      return {
        ok: false,
        dry_run: false,
        aborted: true,
        reason: OUTCOME.AUTH_PREFLIGHT_FAIL,
        authFailure: { phase: 'preflight', op_id: null, error_class, applied_state, message: errMessage(err) },
        total_ops: changeset.operations.length,
        results: [],
      };
    }
  }

  const operations = changeset.operations;

  // 4. PREPARE every op in array order (read → drift-check → per-op guardrail), so the
  //    survivors are known before dispatch and same-type survivors can be batched. A
  //    read-phase AUTH failure (a dead token surfaces on the re-read too) aborts the
  //    whole batch fail-closed: stop preparing immediately — the remaining ops are then
  //    never read, never dispatched, and never audited (#50 AC #2/#3, phase-agnostic).
  const prepared = new Array(operations.length);
  // A read-phase auth failure during PREPARE stops at the FIRST bad read. It is tracked
  // SEPARATELY from a dispatch-phase auth failure (step 5): both are genuine failures
  // that must EACH be audited (#50 AC #4), so neither may clobber the other out of the
  // audit range. A read abort is always at a HIGHER index than any dispatch abort —
  // dispatch only walks the survivors BEFORE the bad read.
  let readAuthFailure = null;
  let readAuthFailIndex = null;
  for (let i = 0; i < operations.length; i += 1) {
    const prep = await prepareOp(operations[i], { activeBudgetId, dryRun, toolMap, readLiveState });
    prepared[i] = prep;
    if (!dryRun && prep.result && prep.result.status === STATUS.ERROR
      && isAuthFailure(prep.result.detail.error_class)) {
      const { op_id, detail } = prep.result;
      readAuthFailure = { phase: detail.phase, op_id, index: i, error_class: detail.error_class, applied_state: detail.applied_state };
      readAuthFailIndex = i;
      break;
    }
  }
  // Everything through `lastPrepared` has a prep; ops past a read-abort were never read.
  const lastPrepared = readAuthFailIndex == null ? operations.length - 1 : readAuthFailIndex;

  // 5. DISPATCH the survivors in array order. Two mutually-exclusive failure policies
  //    (#50 AC #5): a mid-batch AUTH failure (401/403 — the token is bad) aborts the
  //    whole batch — record that op, then stop, leaving later ops un-dispatched and
  //    un-audited; every other per-op error (422 data / 429 rate limit / 5xx / network)
  //    is recorded and the batch CONTINUES. Consecutive same-type survivors go through
  //    ONE bulk call when a bulk port is wired and the group `bulkFits` (terminal ops
  //    between them don't break the run — they simply aren't in it); otherwise per-op.
  const resultByIndex = new Array(operations.length);
  for (let i = 0; i <= lastPrepared; i += 1) {
    if (prepared[i].result) resultByIndex[i] = prepared[i].result; // terminal: no dispatch
  }

  // Record a dispatch-phase (mutation) auth failure at `index`; returns true to signal
  // the abort. Tracked SEPARATELY from the prepare-phase read abort (above) so a later
  // read failure isn't dropped from the audit when an earlier mutation aborts at a
  // lower index (#50 AC #4).
  let dispatchAuthFailure = null;
  let dispatchStopIndex = null;
  const isApplyAuthAbort = (res, index) => {
    if (res.status === STATUS.ERROR && isAuthFailure(res.detail.error_class)) {
      dispatchAuthFailure = { phase: res.detail.phase, op_id: res.op_id, index, error_class: res.detail.error_class, applied_state: res.detail.applied_state };
      dispatchStopIndex = index;
      return true;
    }
    return false;
  };

  if (dryRun) {
    // No mutating dispatch — every survivor is simulated (diff only).
    for (let i = 0; i <= lastPrepared; i += 1) {
      if (!prepared[i].result) resultByIndex[i] = simulateResult(operations[i], true);
    }
  } else {
    // Walk survivors in array order, batching each run of consecutive same-type
    // survivors, and short-circuit the moment a dispatch returns an auth failure.
    let i = 0;
    dispatch: while (i <= lastPrepared) {
      if (prepared[i].result) { i += 1; continue; } // terminal — already placed
      const type = operations[i].type;
      // Collect this run: same-type survivors, skipping any terminal ops between them.
      const runIdx = [];
      let j = i;
      while (j <= lastPrepared) {
        if (prepared[j].result) { j += 1; continue; }
        if (operations[j].type !== type) break;
        runIdx.push(j);
        j += 1;
      }
      const ops = runIdx.map((k) => operations[k]);
      const canBulk = typeof bulkApplyOp === 'function' && bulkToolMap[type] !== undefined
        && typeof bulkFits === 'function' && bulkFits(ops);
      if (canBulk) {
        const runResults = await applyBulkGroup(ops, { bulkToolMap, bulkApplyOp, toolMap, applyOp });
        for (let k = 0; k < runIdx.length; k += 1) {
          resultByIndex[runIdx[k]] = runResults[k];
          if (isApplyAuthAbort(runResults[k], runIdx[k])) break dispatch;
        }
      } else {
        for (let k = 0; k < runIdx.length; k += 1) {
          const res = await applyOneOp(ops[k], { toolMap, applyOp });
          resultByIndex[runIdx[k]] = res;
          if (isApplyAuthAbort(res, runIdx[k])) break dispatch;
        }
      }
      i = j;
    }
  }

  // 6. Audit every PROCESSED op once, in array order — dry-run and real, applied and
  //    skipped. A dispatch abort bounds the contiguous audited range; the tail past it
  //    leaves no paper trail (#50 AC #2) — EXCEPT the op whose READ auth-failed during
  //    prepare, which genuinely failed and must still be recorded (#50 AC #4) even when
  //    an earlier mutation aborted at a lower index. Un-dispatched survivors in the tail
  //    have no result and are naturally skipped.
  const contiguousStop = dispatchStopIndex == null ? lastPrepared : dispatchStopIndex;
  const results = [];
  for (let i = 0; i <= lastPrepared; i += 1) {
    const isTailReadAuthFail = i === readAuthFailIndex;
    if (i > contiguousStop && !isTailReadAuthFail) continue; // aborted tail, un-audited
    if (resultByIndex[i] === undefined) continue; // survivor never dispatched
    await recordAudit(audit, operations[i], resultByIndex[i], changeset, toolMap, dryRun);
    results.push(resultByIndex[i]);
  }

  // The dispatch abort (the lower index — where the mutation halt actually occurred) is
  // the primary stop for the user message; a read-only abort falls back to its own index.
  const authFailure = dispatchAuthFailure || readAuthFailure;
  if (authFailure) {
    return {
      ok: false,
      dry_run: false,
      aborted: true,
      reason: OUTCOME.AUTH_ABORT,
      authFailure,
      stopped_at_index: authFailure.index,
      total_ops: operations.length,
      results,
    };
  }

  return {
    ok: true,
    dry_run: dryRun,
    aborted: false,
    reason: dryRun ? OUTCOME.DRY_RUN_COMPLETE : OUTCOME.APPLY_COMPLETE,
    results,
  };
}

/**
 * Build the human-facing message for an auth-preflight or mid-batch auth abort
 * (#50 AC #6/#7). It (a) lists the ops that applied before the stop, (b) names the
 * failed op and its error_class, and (c) states the exact remediation — and it
 * distinguishes "no changes applied" (preflight, or a first-op failure) from
 * "N of M ops applied, batch stopped at op K" (a genuine mid-batch failure).
 * Returns null for any non-auth-failure outcome — the caller renders those (the
 * dry-run diff, the guardrail block) its own way.
 * @param {object} outcome an applyChangeset outcome.
 * @returns {string|null}
 */
function describeAuthFailure(outcome) {
  if (
    !outcome
    || (outcome.reason !== OUTCOME.AUTH_PREFLIGHT_FAIL && outcome.reason !== OUTCOME.AUTH_ABORT)
  ) {
    return null;
  }

  const failure = outcome.authFailure || {};
  const preflight = outcome.reason === OUTCOME.AUTH_PREFLIGHT_FAIL;
  // Ops that genuinely applied (real apply only) before the stop.
  const applied = (outcome.results || [])
    .filter((r) => r.status === STATUS.APPLIED && r.dry_run === false)
    .map((r) => r.op_id);
  const total = outcome.total_ops;
  const stoppedAt = failure.index == null ? null : failure.index + 1; // 1-based op position K

  const headline = preflight || applied.length === 0
    ? 'No changes applied.'
    : `${applied.length} of ${total} op(s) applied, batch stopped at op ${stoppedAt}.`;

  const lines = [headline];
  if (applied.length > 0) lines.push(`Applied before the failure: ${applied.join(', ')}.`);
  const where = preflight ? 'preflight auth-check' : `op ${failure.op_id}`;
  lines.push(`Failed at ${where}: ${failure.error_class} (applied_state=${failure.applied_state}).`);
  lines.push(`Remediation: ${remediation(failure.error_class)}.`);
  return lines.join('\n');
}

module.exports = {
  STATUS,
  OUTCOME,
  deepEqual,
  isStale,
  applyChangeset,
  describeAuthFailure,
};
