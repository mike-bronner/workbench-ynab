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
 *   4. DRIFT = ABORT FOR THAT OP, ON BOTH SIDES OF THE PAIR. The executor re-reads
 *      live state and skips any op whose victim drifted from its `before` snapshot —
 *      it is never forced through. And the SURVIVING TWIN is re-read live too (#151):
 *      a twin that no longer exists or has materially changed since generation aborts
 *      the op before dispatch, closing the EXTERNAL-PROCESS staleness window (a twin
 *      deleted or edited outside this batch during generate → approve → apply). The
 *      live gate cannot see a BATCH-MATE's pending delete — every op's liveness read
 *      runs in the executor's prepare phase, before ANY delete dispatches — so that
 *      vector is closed statically instead: the pre-flight rejects a change-set where
 *      one op's victim is another op's surviving twin (findBatchTwinCollisions,
 *      twin_batch_collision). Together the two guards keep twin-side staleness from
 *      turning the delete into removing the only remaining copy.
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
const { isTransferLeg } = require('./transaction-shape');

/** The op type this write path handles — the executor toolMap registration key. */
const OP_TYPE = 'delete_duplicate';

/**
 * Resolve the single namespaced delete tool from an allow-list by suffix,
 * asserting UNIQUENESS (issue #151). A `.find()` would silently take the first
 * match, so a future allow-list entry sharing the `_delete_transaction` suffix
 * could route irreversible deletes to the wrong tool without a whisper — on the
 * one path where that must never happen. Fail-closed: zero or multiple matches
 * throw instead of resolving.
 * @param {readonly string[]} allowedTools the guardrail's exported allow-list.
 * @returns {string} the one matching tool name.
 * @throws {Error} when the suffix matches no tool or more than one.
 */
function resolveDeleteTool(allowedTools) {
  const matches = (Array.isArray(allowedTools) ? allowedTools : [])
    .filter((t) => typeof t === 'string' && t.endsWith('_delete_transaction'));
  if (matches.length !== 1) {
    throw new Error(
      `delete-duplicate: expected exactly ONE *_delete_transaction tool on the guardrail allow-list, found ${matches.length}`
      + `${matches.length > 0 ? ` (${matches.join(', ')})` : ''} — refusing to resolve the destructive delete tool (fail-closed).`,
    );
  }
  return matches[0];
}

/**
 * The single namespaced delete tool, resolved from the guardrail's ledger-only
 * allow-list by suffix so no literal tool name is hard-coded here (issue #87
 * guard). The guardrail is the single source of truth; an MCP swap that renames
 * the suffix is a one-file edit there and this keeps resolving. Uniqueness is
 * asserted at resolution (resolveDeleteTool, issue #151) — an ambiguous or empty
 * match throws at load time rather than silently picking a tool.
 * @type {string}
 */
const DELETE_TOOL = resolveDeleteTool(ALLOWED_TOOLS);

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
  'transfer_account_id', 'transfer_transaction_id',
]);

/**
 * Format raw YNAB milliunits as a display dollar string (integer math, no float
 * round-trip): 1000 milliunits = $1.00, so cents = (|m| mod 1000) / 10.
 * -54990 → "-$54.99"; 250000 → "$250.00"; 1200000 → "$1,200.00".
 *
 * ROUNDING — DELIBERATELY DISTINCT FROM formatMoney (issue #150). This helper
 * TRUNCATES the sub-cent remainder (`Math.floor` of the absolute value); the shared
 * assets/format-money.js `formatMoney` ROUNDS half-toward-+∞ instead. So on a
 * fractional-milliunit value the two disagree — e.g. 2995 → "$2.99" here vs "$3.00"
 * from formatMoney. Left intentionally unreconciled: both formatters only ever receive
 * whole-cent YNAB amounts on real data, where their outputs are byte-identical, and this
 * is the destructive delete-preview path — so its behavior is regression-guarded (see
 * tests/unit/delete-duplicate.test.mjs and tests/unit/format-money.test.mjs, which pin
 * each direction) rather than churned to match a formatter it can never disagree with in
 * practice. A tiny negative that floors to zero renders "-$0.00" (the sign comes from
 * `milliunits < 0`, independent of the rounded magnitude) — also pinned, also inert.
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
 * Hard block (GAP-19 / #49): a delete op must never target — or pair with — a
 * TRANSFER LEG. A transfer inflow/outflow pair is legitimate, never duplicates,
 * and deleting one leg corrupts the linked account's ledger. This is a HARD
 * BLOCK, deliberately NOT `human_review_required`: no confirmation can make a
 * one-leg deletion safe. Checked on BOTH candidates — the victim (`op.before`)
 * and the surviving twin (`op.twin`) — via the shared isTransferLeg helper,
 * before any read or delete is attempted.
 * @param {object} op a delete_duplicate operation.
 * @returns {{valid:true}|{valid:false, error:{op_id:string|null, rule:string, reason:string, transfer_leg:string[]}}}
 */
function validateNotTransferLeg(op) {
  const opId = op && typeof op === 'object' && typeof op.id === 'string' ? op.id : null;
  const legs = [];
  if (op && typeof op === 'object') {
    if (isTransferLeg(op.before)) legs.push('victim');
    if (isTransferLeg(op.twin)) legs.push('twin');
  }
  if (legs.length === 0) return { valid: true };
  return {
    valid: false,
    error: {
      op_id: opId,
      rule: 'transfer_leg_hard_block',
      reason: `delete_duplicate op involves a transfer leg (${legs.join(', ')}); a transfer inflow/outflow pair is never a duplicate, and deleting one leg corrupts the linked account's ledger — hard-blocked, never deletable by this path.`,
      transfer_leg: legs,
    },
  };
}

/**
 * Batch-level analogue of the per-op twin_is_victim guard (#151): within a single
 * change-set, one delete op's SURVIVING TWIN must never be another delete op's
 * VICTIM. Every op's twin-liveness read runs during the executor's prepare phase —
 * applyChangeset prepares EVERY op before dispatching ANY mutation — so in a
 * reciprocal pair (op1: victim=A/twin=B, op2: victim=B/twin=A) each op reads the
 * other side as still alive, both pass the live twin gate, and both deletes
 * dispatch: BOTH copies are removed. An overlapping chain (op1: victim=B/twin=A,
 * op2: victim=C/twin=B) likewise deletes C's intended survivor B. The live gate
 * cannot see a batch-mate's pending delete, so the collision is rejected
 * statically here, before the executor runs. Same-op collisions
 * (op.transaction_id === op.twin.id) are the per-op twin_is_victim guard's domain
 * and are not re-reported; ops with malformed twin/victim ids are
 * validateTwinEvidence's domain and are skipped.
 * @param {readonly object[]} ops the change-set's operations (non-delete ops ignored).
 * @returns {Array<{op_id:string|null, rule:string, reason:string, twin_id:string, victim_op_ids:(string|null)[]}>}
 *   one entry per delete op whose surviving twin a batch-mate deletes; empty = clean.
 */
function findBatchTwinCollisions(ops) {
  const deletes = (Array.isArray(ops) ? ops : [])
    .filter((op) => op !== null && typeof op === 'object' && !Array.isArray(op) && op.type === OP_TYPE);
  const collisions = [];
  for (const op of deletes) {
    const twinId = op.twin !== null && typeof op.twin === 'object' && !Array.isArray(op.twin)
      && typeof op.twin.id === 'string' && op.twin.id.length > 0 ? op.twin.id : null;
    if (twinId === null) continue;
    const victimOps = deletes.filter((other) => other !== op && other.transaction_id === twinId);
    if (victimOps.length === 0) continue;
    const victimOpIds = victimOps.map((o) => (typeof o.id === 'string' ? o.id : null));
    collisions.push({
      op_id: typeof op.id === 'string' ? op.id : null,
      rule: 'twin_batch_collision',
      reason: `delete_duplicate op names surviving twin ${twinId}, but batch-mate op(s) `
        + `${victimOpIds.map((id) => (id != null ? id : '(no id)')).join(', ')} name that same transaction as their VICTIM; `
        + 'applying this change-set would delete the survivor this op\'s delete depends on, removing the only remaining copy. '
        + 'The per-op live twin gate reads pre-dispatch state and cannot see a batch-mate\'s pending delete — rejected before any read or delete.',
      twin_id: twinId,
      victim_op_ids: victimOpIds,
    });
  }
  return collisions;
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
 *      op without provable pairing must never reach an MCP call. The pre-flight also
 *      rejects BATCH twin↔victim collisions (findBatchTwinCollisions): a change-set
 *      whose ops delete each other's survivors aborts with
 *      { ok:false, reason:'twin_batch_collision', batchCollisions } — the per-op live
 *      twin gate reads pre-dispatch state and cannot catch a batch-mate.
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
  const transferLegBlocks = [];
  for (const op of ops) {
    if (op && op.type === OP_TYPE) {
      const legVerdict = validateNotTransferLeg(op);
      if (!legVerdict.valid) transferLegBlocks.push(legVerdict.error);
      const verdict = validateTwinEvidence(op);
      if (!verdict.valid) twinErrors.push(verdict.error);
    }
  }
  // Transfer-leg HARD BLOCK first (GAP-19 / #49): it outranks every other verdict —
  // no read, no delete, no executor. Never `human_review_required`; one-leg deletion
  // is never approvable.
  if (transferLegBlocks.length > 0) {
    return { ok: false, dry_run: dryRun, aborted: true, reason: 'transfer_leg_hard_block', transferLegBlocks, results: [] };
  }
  if (twinErrors.length > 0) {
    return { ok: false, dry_run: dryRun, aborted: true, reason: 'twin_evidence_missing', twinErrors, results: [] };
  }
  // BATCH TWIN↔VICTIM COLLISION (#151): one op's victim must not be another op's
  // surviving twin. The live twin gate below runs during the executor's prepare
  // phase — before ANY delete dispatches — so a reciprocal/overlapping pair passes
  // it and then deletes both copies. Statically rejected here instead, dry-run
  // included: no read, no delete, no executor.
  const batchCollisions = findBatchTwinCollisions(ops);
  if (batchCollisions.length > 0) {
    return { ok: false, dry_run: dryRun, aborted: true, reason: 'twin_batch_collision', batchCollisions, results: [] };
  }

  // Lazy-require the executor so importing this module's pure safety helpers does
  // NOT transitively pull in the Ajv-backed validator — keeping tests/unit/*.test.mjs
  // (CI, run with no node_modules) able to exercise twin validation / preview without
  // an install, faithful to the offline-boot constraint.
  const { applyChangeset, isStale } = require('./apply-executor');

  // LIVE SHAPE RE-DERIVATION (GAP-19 / #49, fail-open fix). The snapshot check above
  // trusts the caller-supplied `op.before` / `op.twin`; the schema leaves the transfer
  // fields optional, so a schema-valid op that simply OMITS them (or lies with nulls)
  // walks straight past it. The one thing a payload cannot talk around is the LIVE
  // read the executor already performs — so the hard block is re-derived there: wrap
  // the injected readLiveState port and re-check isTransferLeg on BOTH live candidates,
  // matching validateNotTransferLeg's "never target OR PAIR WITH a transfer leg"
  // guarantee:
  //   - the VICTIM — the executor's own live read of op.transaction_id;
  //   - the TWIN — a second read through the same port with the twin's id swapped in
  //     (the port resolves whatever `op.transaction_id` names, so no new port is
  //     needed; see skills/delete-duplicate.md). A live transfer-leg twin proves the
  //     "duplicate pair" is really a legitimate transfer pair, so deleting the victim
  //     would be a wrong, irreversible delete even though the victim itself is clean.
  // The same live twin read also feeds the twin LIVENESS + DRIFT gate (#151, below
  // inline): a twin that is gone or materially changed aborts the op the same way.
  // Either live leg throws, which the executor records as a terminal per-op `error`
  // (never dispatched — the delete tool is unreachable for it) while the rest of the
  // batch proceeds under normal per-op semantics. Structurally fail-closed: the ONLY
  // route to `ynab_delete_transaction` runs through a successful live read, and every
  // successful live read passes this gate first — a twin read that fails is a per-op
  // read error, never a skipped check. Requires the port to project the full victim
  // shape — shapeVictimSnapshot(liveTxn), transfer fields included — per
  // skills/delete-duplicate.md.
  const shapeGuardedRead = typeof readLiveState === 'function'
    ? async (op) => {
      const live = await readLiveState(op);
      if (op && op.type === OP_TYPE) {
        if (isTransferLeg(live)) {
          const err = new Error(
            `transfer_leg_hard_block: delete_duplicate op ${op.id != null ? op.id : '(no id)'} targets a LIVE transfer leg `
            + '(the live read carries a non-null transfer_account_id / transfer_transaction_id); deleting one leg of a transfer '
            + 'pair corrupts the linked account\'s ledger — hard-blocked from the live state, regardless of the op\'s snapshot evidence.',
          );
          err.rule = 'transfer_leg_hard_block';
          throw err;
        }
        const twinId = op.twin && typeof op.twin.id === 'string' && op.twin.id.length > 0 ? op.twin.id : null;
        if (twinId !== null) {
          const liveTwin = await readLiveState({ ...op, transaction_id: twinId });
          if (isTransferLeg(liveTwin)) {
            const err = new Error(
              `transfer_leg_hard_block: delete_duplicate op ${op.id != null ? op.id : '(no id)'} pairs with a LIVE transfer-leg `
              + 'TWIN (the live read of the surviving twin carries a non-null transfer_account_id / transfer_transaction_id); '
              + 'the pair is a legitimate transfer, never duplicates — the victim delete is hard-blocked from the live state, '
              + 'regardless of the op\'s snapshot evidence.',
            );
            err.rule = 'transfer_leg_hard_block';
            throw err;
          }
          // SURVIVING-TWIN LIVENESS + DRIFT GATE (#151). AC6 (#62) drift-checks only
          // the VICTIM; if the TWIN is deleted or materially changed by another
          // process during the generate → approve → apply window, the victim's own
          // `before` snapshot is unchanged — the op is NOT stale — and the delete
          // would remove what is now the ONLY remaining copy: the exact outcome the
          // twin_is_victim guard exists to prevent, reached via twin-side staleness.
          // EXTERNAL processes only: this read runs in the executor's prepare phase,
          // before ANY delete in the batch dispatches, so a batch-mate's pending
          // delete of this twin is invisible here — that vector is rejected
          // statically in the pre-flight (findBatchTwinCollisions, above).
          // So before the victim can be dispatched, the twin must be proven ALIVE
          // (a comparable live read) and UNCHANGED on the evidence fields the human
          // approved (payee_name / amount / date — TWIN_REQUIRED_FIELDS minus the id
          // the read itself resolved). Either failure throws, which the executor
          // records as a terminal per-op `error` — the delete tool is unreachable.
          // Decisive only when the victim itself is NOT stale: a stale victim is
          // already skipped by the executor's own drift check (richer skip detail,
          // pinned behavior), and a skipped op never deletes anything.
          if (!isStale(op.before, live)) {
            if (liveTwin === null || typeof liveTwin !== 'object' || Array.isArray(liveTwin)) {
              const err = new Error(
                `twin_missing: delete_duplicate op ${op.id != null ? op.id : '(no id)'} names a surviving twin (${twinId}) `
                + 'whose live read resolved to nothing — the twin no longer exists, so deleting the victim would remove the '
                + 'ONLY remaining copy of the transaction. Aborted before dispatch (fail-closed).',
              );
              err.rule = 'twin_missing';
              throw err;
            }
            const drifted = TWIN_REQUIRED_FIELDS.filter((f) => f !== 'id' && liveTwin[f] !== op.twin[f]);
            if (drifted.length > 0) {
              const err = new Error(
                `twin_drifted: delete_duplicate op ${op.id != null ? op.id : '(no id)'} carries surviving-twin evidence that no `
                + `longer matches the live twin (${twinId}) on: ${drifted.join(', ')}. The twin the human approved as the `
                + 'surviving copy has materially changed since the change-set was generated — the pairing is unproven, so the '
                + 'victim delete is aborted before dispatch (fail-closed).',
              );
              err.rule = 'twin_drifted';
              throw err;
            }
          }
        }
      }
      return live;
    }
    : readLiveState;

  const wrappedApplyOp = (!dryRun && typeof applyOp === 'function')
    ? makeAuditingDeleteApplyOp({ applyOp, audit, changeset, dryRun })
    : applyOp;

  return applyChangeset(changeset, {
    activeBudgetId,
    dryRun,
    toolMap: buildToolMap(),
    readLiveState: shapeGuardedRead,
    applyOp: wrappedApplyOp,
    authPreflight,
    audit,
  });
}

module.exports = {
  OP_TYPE,
  DELETE_TOOL,
  resolveDeleteTool,
  TWIN_REQUIRED_FIELDS,
  VICTIM_SNAPSHOT_FIELDS,
  formatDollars,
  validateTwinEvidence,
  validateNotTransferLeg,
  findBatchTwinCollisions,
  shapeVictimSnapshot,
  renderDeletePreview,
  requiresStrongConfirmation,
  destructiveOps,
  buildToolMap,
  makeAuditingDeleteApplyOp,
  applyDeleteDuplicates,
};
