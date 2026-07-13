'use strict';

/**
 * Duplicate-fix (delete) write path for workbench-ynab write-back (M4-8).
 *
 * The destructive write path: it removes a duplicate transaction via the
 * namespaced delete tool. Deleting is the only irreversible operation in M4 and
 * the one with the highest blast radius if wrong, so this path wraps the shared
 * apply executor (M4-4) in the strongest safety the contract allows:
 *
 *   1. TWIN (PAIRING) EVIDENCE. Every delete op must reference its surviving twin
 *      — the transaction it is a duplicate OF (id, payee_name, amount, date) — so
 *      the human and the dry-run preview see the pair, not just the victim. An op
 *      missing twin evidence is rejected with a structured error BEFORE any read
 *      or delete is attempted (validateTwinEvidence + the pre-flight in
 *      applyDeleteDuplicates, which returns before touching the executor's ports).
 *   2. MANDATORY DRY-RUN PREVIEW. renderDeletePreview renders victim and survivor
 *      side by side plus the account's cleared balance before vs after. The
 *      executor is dry-run by default; no real delete happens without an explicit
 *      dryRun:false, which the M4-5 approval command sets only after the human has
 *      seen the preview and given the strong confirmation below.
 *   3. STRONG CONFIRMATION GATE. requiresStrongConfirmation / destructiveOps mark
 *      every destructive op so M4-5 can route it through a separate AskUserQuestion
 *      affirmation, distinct from ordinary batch approval (see skills/delete-duplicate.md).
 *   4. DRIFT = ABORT FOR THAT OP. The executor re-reads live state and skips any op
 *      whose victim drifted from its `before` snapshot — it is never forced through.
 *   5. AUDIT BEFORE DELETE. makeAuditingDeleteApplyOp writes the full before-snapshot
 *      to the M4-3 audit log BEFORE the irreversible delete, so a crash mid-delete
 *      still leaves a record of exactly what was removed.
 *
 * NAMESPACED TOOL, NEVER HARD-CODED. The single delete tool is resolved from the
 * guardrail's exported ALLOWED_TOOLS (the swap-ready single source of truth, issue
 * #87) by suffix — no literal `mcp__plugin_workbench-ynab_ynab__*` string lives in
 * this file, so bin/check-tool-name-sources.sh stays green. The read tool used to
 * re-read the victim for drift detection (ynab_get_transaction) is wired by the
 * agent runtime as the injected readLiveState port, resolved from
 * skills/protocol/ynab-tools.md — it is never named here either.
 *
 * MILLIUNITS THROUGHOUT. Every internal op field and audit record carries raw
 * integer milliunits verbatim; only preview output is rendered as dollars
 * (formatDollars, milliunits / 1000).
 */

const { ALLOWED_TOOLS } = require('./write-safety-guardrail');
const { throwOnErrorResult } = require('./write-error');

/** The op type this write path handles — the executor toolMap registration key. */
const OP_TYPE = 'delete_duplicate';

/**
 * The single namespaced delete tool, resolved from the guardrail's ledger-only
 * allow-list by suffix so no literal tool name is hard-coded here (issue #87
 * guard). The guardrail is the single source of truth; an MCP swap that renames
 * the suffix is a one-file edit there and this keeps resolving.
 * @type {string|undefined}
 */
const DELETE_TOOL = ALLOWED_TOOLS.find((t) => t.endsWith('_delete_transaction'));

/** The surviving-twin evidence fields a delete op MUST carry (AC twin-evidence). */
const TWIN_REQUIRED_FIELDS = Object.freeze(['id', 'payee_name', 'amount', 'date']);

/**
 * The victim fields the `before` snapshot carries — the full transaction state the
 * M4-3 audit records before deletion, and the shape readLiveState returns so the
 * executor's drift check compares like-for-like. `import_id` is optional evidence.
 * @type {readonly string[]}
 */
const VICTIM_SNAPSHOT_FIELDS = Object.freeze([
  'amount', 'date', 'payee_name', 'category_id', 'account_id', 'cleared', 'memo', 'import_id',
]);

/**
 * Format raw YNAB milliunits as a display dollar string (integer math, no float
 * round-trip): 1000 milliunits = $1.00, so cents = (|m| mod 1000) / 10.
 * -54990 → "-$54.99"; 250000 → "$250.00"; 1200000 → "$1,200.00".
 * @param {number} milliunits integer milliunits.
 * @returns {string}
 */
function formatDollars(milliunits) {
  if (typeof milliunits !== 'number' || !Number.isInteger(milliunits)) {
    throw new TypeError(`formatDollars expects integer milliunits, got ${JSON.stringify(milliunits)}`);
  }
  const sign = milliunits < 0 ? '-' : '';
  const abs = Math.abs(milliunits);
  const whole = Math.floor(abs / 1000).toLocaleString('en-US');
  const cents = String(Math.floor((abs % 1000) / 10)).padStart(2, '0');
  return `${sign}$${whole}.${cents}`;
}

/**
 * Validate the surviving-twin evidence on a single delete op. Fail-closed: returns
 * a structured error unless the op carries a `twin` object with a non-empty `id`,
 * an integer `amount`, a non-empty `date`, and a present `payee_name` (string or
 * null — a real YNAB transaction may have no payee), AND names a valid victim
 * (`transaction_id`, a non-empty string — `victim_id_missing` otherwise) that is not
 * that surviving twin (`twin.id`) — a victim===survivor collision is rejected
 * (`twin_is_victim`) so a delete can never remove the only copy. Runs before any read
 * or delete, so a delete op that cannot prove which record survives — that names no
 * target — or that would delete the survivor — never reaches an MCP call.
 * @param {object} op a delete_duplicate operation.
 * @returns {{valid:true}|{valid:false, error:{op_id:string|null, rule:string, reason:string, missing:string[]}}}
 */
function validateTwinEvidence(op) {
  const opId = op && typeof op === 'object' && typeof op.id === 'string' ? op.id : null;
  if (op === null || typeof op !== 'object' || Array.isArray(op)) {
    return { valid: false, error: { op_id: null, rule: 'twin_evidence_missing', reason: 'Operation is not an object; cannot read twin evidence.', missing: [...TWIN_REQUIRED_FIELDS] } };
  }
  const twin = op.twin;
  if (twin === null || typeof twin !== 'object' || Array.isArray(twin)) {
    return { valid: false, error: { op_id: opId, rule: 'twin_evidence_missing', reason: 'delete_duplicate op carries no twin object; it cannot prove which transaction survives.', missing: [...TWIN_REQUIRED_FIELDS] } };
  }
  const missing = [];
  if (typeof twin.id !== 'string' || twin.id.length === 0) missing.push('id');
  if (!('payee_name' in twin) || (twin.payee_name !== null && typeof twin.payee_name !== 'string')) missing.push('payee_name');
  if (typeof twin.amount !== 'number' || !Number.isInteger(twin.amount)) missing.push('amount');
  if (typeof twin.date !== 'string' || twin.date.length === 0) missing.push('date');
  if (missing.length > 0) {
    return { valid: false, error: { op_id: opId, rule: 'twin_evidence_missing', reason: `delete_duplicate op is missing or has malformed surviving-twin evidence: ${missing.join(', ')}.`, missing } };
  }
  // Fail-closed presence/type check on the victim being deleted. The collision guard
  // below is `op.transaction_id === twin.id`; an ABSENT victim id (undefined) is NOT
  // equal to the proven non-empty twin.id, so it would slip past that check — yet this
  // function is exported as a standalone safety primitive that runs BEFORE the schema
  // in the pre-flight. Require the victim id to be a non-empty string first, so a
  // delete op that cannot even name its target never reaches an MCP call.
  if (typeof op.transaction_id !== 'string' || op.transaction_id.length === 0) {
    return { valid: false, error: { op_id: opId, rule: 'victim_id_missing', reason: 'delete_duplicate op has no valid transaction_id (the victim to delete); it cannot identify its target or be checked against the surviving twin.', missing: ['transaction_id'] } };
  }
  // Fail-closed cross-field check: the victim being deleted (op.transaction_id) must
  // NOT be the surviving twin (twin.id). A change-set where they're equal passes
  // field-presence validation, the guardrail, and the drift check, then deletes the
  // ONLY copy of the transaction — the precise highest-blast-radius failure this
  // destructive path exists to prevent. Both ids are proven non-empty strings above,
  // so this only fires on a genuine collision. Reject before any read or delete.
  if (op.transaction_id === twin.id) {
    return { valid: false, error: { op_id: opId, rule: 'twin_is_victim', reason: 'delete_duplicate op names its surviving twin as the victim (transaction_id === twin.id); deleting it would remove the only copy of the transaction.', missing: [] } };
  }
  return { valid: true };
}

/**
 * Project a live YNAB transaction onto the victim-snapshot shape so the executor's
 * drift check compares it field-for-field against the op's `before`. Pass the op's
 * `before` keys to compare exactly the snapshotted fields (apples-to-apples);
 * defaults to the full field set. Fail-closed: a non-object live read returns null,
 * which the executor treats as drift (skip), never a forced delete.
 * @param {unknown} transaction the live transaction (from ynab_get_transaction).
 * @param {readonly string[]} [keys] the fields to project (default VICTIM_SNAPSHOT_FIELDS).
 * @returns {object|null}
 */
function shapeVictimSnapshot(transaction, keys = VICTIM_SNAPSHOT_FIELDS) {
  if (transaction === null || typeof transaction !== 'object' || Array.isArray(transaction)) return null;
  const out = {};
  for (const key of keys) {
    out[key] = key in transaction && transaction[key] !== undefined ? transaction[key] : null;
  }
  return out;
}

/**
 * Render the mandatory dry-run preview for a delete op: victim and surviving twin
 * side by side, plus the account's cleared balance before vs after. Deleting only
 * changes the cleared balance when the victim counts toward it (cleared or
 * reconciled); subtracting the victim's (signed) amount adds an outflow back.
 * Monetary fields are rendered as dollars for display AND carried as raw milliunits.
 * @param {object} op a delete_duplicate operation.
 * @param {{clearedBalanceBefore?: number}} [context] the account's current cleared balance (milliunits).
 * @returns {object} a structured preview the M4-5 command displays.
 */
function renderDeletePreview(op, context = {}) {
  // COMPARE-TRANSACTIONS CORROBORATION — deliberately NOT called here (AC #9).
  // The AC lets this path call ynab_compare_transactions during the dry-run to
  // corroborate the duplicate pairing, OR skip it with the decision documented in
  // the handler. We skip: the surviving-twin evidence carried on the op — validated
  // fail-closed by validateTwinEvidence before any read or delete — is the actual
  // *requirement* and is sufficient to render the pair side by side below. A
  // compare_transactions read would only re-confirm what the op already proves, at
  // the cost of an extra deferred-schema MCP round-trip on the preview path.
  // Corroboration is a nicety; the twin evidence is the requirement. If a future
  // change wants the extra confirmation, the compare tool is wired via
  // skills/protocol/ynab-tools.md (never inlined here) and would be invoked right
  // here, before assembling the preview.
  const before = (op && op.before) || {};
  const twin = (op && op.twin) || {};
  const clearedBalanceBefore = context.clearedBalanceBefore;
  const hasBalance = typeof clearedBalanceBefore === 'number' && Number.isInteger(clearedBalanceBefore);
  const countsTowardCleared = before.cleared === 'cleared' || before.cleared === 'reconciled';
  // Mirror the `typeof before.amount === 'number'` guard used on the display field
  // below: a victim with no numeric amount must yield a null projection, never an
  // arithmetic NaN that formatDollars would then throw on (the helper is exported,
  // so a caller can reach it with an incomplete `before`).
  const clearedBalanceAfter = !hasBalance
    ? null
    : countsTowardCleared
      ? (typeof before.amount === 'number' ? clearedBalanceBefore - before.amount : null)
      : clearedBalanceBefore;

  return {
    op_id: op && op.id != null ? op.id : null,
    victim: {
      transaction_id: op && op.transaction_id != null ? op.transaction_id : null,
      payee_name: before.payee_name == null ? null : before.payee_name,
      amount_milliunits: before.amount,
      amount: typeof before.amount === 'number' ? formatDollars(before.amount) : null,
      date: before.date == null ? null : before.date,
      account_id: before.account_id == null ? null : before.account_id,
      cleared: before.cleared == null ? null : before.cleared,
    },
    survivor: {
      transaction_id: twin.id == null ? null : twin.id,
      payee_name: twin.payee_name == null ? null : twin.payee_name,
      amount_milliunits: twin.amount,
      amount: typeof twin.amount === 'number' ? formatDollars(twin.amount) : null,
      date: twin.date == null ? null : twin.date,
    },
    cleared_balance: {
      counts_toward_cleared: countsTowardCleared,
      before_milliunits: hasBalance ? clearedBalanceBefore : null,
      before: hasBalance ? formatDollars(clearedBalanceBefore) : null,
      after_milliunits: clearedBalanceAfter,
      after: clearedBalanceAfter == null ? null : formatDollars(clearedBalanceAfter),
    },
  };
}

/**
 * Whether an op needs the extra strong-confirmation step beyond batch approval.
 * delete_duplicate ops are always `risk: destructive` (pinned by the schema and the
 * M4-2 guardrail), so this is true for every real delete.
 * @param {object} op
 * @returns {boolean}
 */
function requiresStrongConfirmation(op) {
  return Boolean(op) && typeof op === 'object' && op.risk === 'destructive';
}

/**
 * The destructive ops in a change-set that M4-5 must route through a separate
 * AskUserQuestion affirmation before applying.
 * @param {object} changeset
 * @returns {object[]}
 */
function destructiveOps(changeset) {
  const ops = changeset && Array.isArray(changeset.operations) ? changeset.operations : [];
  return ops.filter(requiresStrongConfirmation);
}

/**
 * The op-type → tool registration this write path supplies to the executor. The
 * executor never hard-codes a tool name; this is the only place delete_duplicate is
 * mapped, and the tool is resolved from the guardrail allow-list (above).
 * @returns {Record<string,string|undefined>}
 */
function buildToolMap() {
  return { [OP_TYPE]: DELETE_TOOL };
}

/**
 * Wrap the real-apply `applyOp` port so that, for a delete op, the full
 * before-snapshot is appended to the M4-3 audit log BEFORE the irreversible delete
 * tool runs — not after. The executor records the post-delete result separately, so
 * a destructive op leaves a two-phase trail: intent (with the complete victim state)
 * before, outcome after. Non-delete ops pass straight through untouched.
 * @param {{applyOp:Function, audit:Function, changeset:object, dryRun?:boolean}} deps
 *   `dryRun` is stamped onto the pre-delete audit record so it always reflects the
 *   actual run mode. Today the wrapper is only constructed on the real-apply path
 *   (dryRun:false in applyDeleteDuplicates), but propagating the flag instead of a
 *   literal keeps the record truthful if that construction guard ever loosens —
 *   never a misleading record claiming a real delete during a dry-run.
 * @returns {(toolName:string, op:object)=>Promise<unknown>}
 */
function makeAuditingDeleteApplyOp({ applyOp, audit, changeset, dryRun = false }) {
  return async (toolName, op) => {
    if (op && op.type === OP_TYPE && typeof audit === 'function') {
      await audit({
        operation: op,
        result: {
          tool: toolName,
          status: 'pending_delete',
          schema_version: changeset && changeset.schema_version != null ? changeset.schema_version : null,
          run_id: changeset && changeset.source != null ? changeset.source : null,
        },
        dryRun,
      });
    }
    // Defense in depth (#50): route the delete dispatch through throwOnErrorResult so a
    // vendored `{ isError: true }` auth / rate / 5xx envelope that RESOLVED (didn't reject)
    // throws — the executor's auth-abort machinery then fail-closes on the irreversible
    // write path, code-enforcing the "ports throw on a non-2xx" contract rather than
    // trusting the injected port to have done it.
    return throwOnErrorResult(await applyOp(toolName, op));
  };
}

/**
 * Apply the delete_duplicate ops in a change-set through the shared executor, with
 * this path's twin-evidence pre-flight and audit-before-delete wiring layered on.
 *
 * Pipeline:
 *   1. Pre-validate twin evidence on EVERY delete_duplicate op. If any op lacks it,
 *      abort BEFORE the executor runs — no read, no delete, no port touched — and
 *      return { ok:false, reason:'twin_evidence_missing', twinErrors }. A destructive
 *      op without provable pairing must never reach an MCP call.
 *   2. Delegate to applyChangeset with this path's toolMap. Dry-run by default; real
 *      apply requires dryRun:false and wraps applyOp to audit the before-snapshot
 *      before the delete.
 *
 * The executor still owns schema validation, the write-safety guardrail, drift
 * detection (skip-stale), and per-op audit — this wrapper adds only the
 * delete-specific safety on top.
 *
 * @param {object} changeset the change-set (may carry non-delete ops too; only
 *   delete_duplicate ops get twin pre-flight).
 * @param {object} options
 * @param {string} options.activeBudgetId mandatory active budget (the guardrail fails closed without it).
 * @param {boolean} [options.dryRun=true] real apply requires an explicit false.
 * @param {Function} options.readLiveState async (op) => live victim state (wire to ynab_get_transaction).
 * @param {Function} [options.applyOp] async (toolName, op) => mcp result — required for real apply.
 * @param {Function} [options.authPreflight] async () => read-only YNAB result — required for real apply;
 *   the executor's pre-mutation auth check (#50). Forwarded verbatim to applyChangeset.
 * @param {Function} options.audit async ({operation, result, dryRun}) => void — the M4-3 audit sink.
 * @returns {Promise<object>} the executor outcome, or the twin_evidence_missing abort.
 */
async function applyDeleteDuplicates(changeset, options = {}) {
  const { activeBudgetId, dryRun = true, readLiveState, applyOp, authPreflight, audit } = options;

  const ops = changeset && Array.isArray(changeset.operations) ? changeset.operations : [];
  const twinErrors = [];
  for (const op of ops) {
    if (op && op.type === OP_TYPE) {
      const verdict = validateTwinEvidence(op);
      if (!verdict.valid) twinErrors.push(verdict.error);
    }
  }
  if (twinErrors.length > 0) {
    return { ok: false, dry_run: dryRun, aborted: true, reason: 'twin_evidence_missing', twinErrors, results: [] };
  }

  // Lazy-require the executor so importing this module's pure safety helpers does
  // NOT transitively pull in the Ajv-backed validator — keeping tests/unit/*.test.mjs
  // (CI, run with no node_modules) able to exercise twin validation / preview without
  // an install, faithful to the offline-boot constraint.
  const { applyChangeset } = require('./apply-executor');

  const wrappedApplyOp = (!dryRun && typeof applyOp === 'function')
    ? makeAuditingDeleteApplyOp({ applyOp, audit, changeset, dryRun })
    : applyOp;

  return applyChangeset(changeset, {
    activeBudgetId,
    dryRun,
    toolMap: buildToolMap(),
    readLiveState,
    applyOp: wrappedApplyOp,
    authPreflight,
    audit,
  });
}

module.exports = {
  OP_TYPE,
  DELETE_TOOL,
  TWIN_REQUIRED_FIELDS,
  VICTIM_SNAPSHOT_FIELDS,
  formatDollars,
  validateTwinEvidence,
  shapeVictimSnapshot,
  renderDeletePreview,
  requiresStrongConfirmation,
  destructiveOps,
  buildToolMap,
  makeAuditingDeleteApplyOp,
  applyDeleteDuplicates,
};
