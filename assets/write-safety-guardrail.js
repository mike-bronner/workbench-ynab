'use strict';

/**
 * Write-safety guardrail for workbench-ynab write-back (M4-2).
 *
 * The single most important invariant in this plugin: writes are LEDGER-ONLY
 * operations inside YNAB and NEVER move real money — no transfers, no payments
 * (locked decision). This module is the runtime enforcement of that promise. It
 * sits between an approved change-set and the apply executor (M4-4) and the
 * approval command (M4-5): given a change-set (or a single operation, or a tool
 * name), it returns a structured pass/block verdict and refuses anything
 * money-moving, regardless of what the review proposed or the human clicked.
 *
 * It is the runtime half of the M4 safety promise. The change-set schema
 * (assets/changeset-schema.json) makes a money-moving change-set
 * UNREPRESENTABLE (money_movement is a `const false`); this guardrail makes a
 * money-moving apply IMPOSSIBLE. Both must hold.
 *
 * Design rules:
 *  - FAIL-CLOSED. The default verdict is BLOCK. An operation or tool passes only
 *    when it is positively matched to the ledger-only allow-list and clears every
 *    scope assertion. Anything unrecognised is blocked.
 *  - SINGLE SOURCE OF TRUTH. The allow-lists and deny-list below are the only
 *    place write paths are enumerated. Adding a new write path means editing the
 *    relevant constant HERE first — nothing downstream may widen them.
 *  - NAMESPACED tool names only. The deny-list and allow-list hold fully
 *    namespaced `mcp__plugin_workbench-ynab_ynab__*` strings so a typo can't
 *    accidentally allow a bare `mcp__ynab__ynab_create_transaction`.
 *  - NO DEPENDENCIES. The guardrail is pure object inspection (allow/deny/scope),
 *    independent of JSON-Schema validation, so it can be required without an
 *    install step and can never itself be the thing that fails open.
 *
 * Usage as a library (M4-4 apply executor, M4-5 approval command):
 *   const {
 *     evaluateChangeset, evaluateOperation, evaluateTool,
 *   } = require('./assets/write-safety-guardrail');
 *   const result = evaluateChangeset(changeset, { activeBudgetId });
 *   // result.verdict === 'pass' | 'block'; result.blocks === [<verdict>, ...]
 *
 * Usage as a CLI (verdict JSON on stdout, diagnostics on stderr, non-zero exit
 * on block):
 *   node assets/write-safety-guardrail.js [--active-budget <id>] <changeset.json>
 */

const fs = require('fs');

/**
 * The ledger-only operation-type allow-list. EXACTLY these four operation types
 * may pass. Adding a fifth write path requires editing only this constant.
 * @type {readonly string[]}
 */
const LEDGER_ONLY_OP_TYPES = Object.freeze([
  'categorize',
  'allocate',
  'delete_duplicate',
  'reconcile',
]);

/**
 * The namespaced tool allow-list. EXACTLY these tools may be invoked at apply
 * time. Adding a tool requires editing only this constant.
 * @type {readonly string[]}
 */
const ALLOWED_TOOLS = Object.freeze([
  'mcp__plugin_workbench-ynab_ynab__ynab_update_transaction',
  'mcp__plugin_workbench-ynab_ynab__ynab_update_transactions',
  'mcp__plugin_workbench-ynab_ynab__ynab_update_category',
  'mcp__plugin_workbench-ynab_ynab__ynab_delete_transaction',
  'mcp__plugin_workbench-ynab_ynab__ynab_reconcile_account',
]);

/**
 * The money-movement deny-list, as full namespaced strings. These tools create
 * or move funds to/beyond an account boundary (or mutate account/default-budget
 * state) and may NEVER run. The deny-list is belt-and-suspenders to the
 * fail-closed allow-list: even if the allow-list were widened by mistake, these
 * stay explicitly forbidden.
 * @type {readonly string[]}
 */
const DENIED_TOOLS = Object.freeze([
  'mcp__plugin_workbench-ynab_ynab__ynab_create_transaction',
  'mcp__plugin_workbench-ynab_ynab__ynab_create_transactions',
  'mcp__plugin_workbench-ynab_ynab__ynab_create_receipt_split_transaction',
  'mcp__plugin_workbench-ynab_ynab__ynab_create_account',
  'mcp__plugin_workbench-ynab_ynab__ynab_set_default_budget',
]);

/**
 * Rule-name string constants. Every block verdict carries one of these as its
 * `rule`, so consumers can branch on a stable identifier rather than prose.
 * @type {Readonly<Record<string, string>>}
 */
const RULES = Object.freeze({
  OP_TYPE_NOT_ALLOWED: 'op_type_not_in_allow_list',
  TOOL_DENIED: 'denied_tool_money_movement',
  TOOL_NOT_ALLOWED: 'tool_not_in_allow_list',
  MONEY_MOVEMENT_IN_CATEGORIZE: 'money_movement_detected_in_categorize',
  MONEY_MOVEMENT_DETECTED: 'money_movement_detected',
  MONEY_MOVEMENT_FLAG: 'money_movement_flag_not_false',
  BUDGET_ID_MISMATCH: 'budget_id_mismatch',
  NO_ACTIVE_BUDGET: 'no_resolvable_active_budget',
  DELETE_DUPLICATE_RISK: 'delete_duplicate_missing_destructive_risk',
  MALFORMED_OPERATION: 'malformed_operation',
  MALFORMED_CHANGESET: 'malformed_changeset',
});

/** Object keys that signal a YNAB transfer (money crossing an account boundary). */
const TRANSFER_SIGNAL_KEYS = Object.freeze(['transfer_account_id', 'transfer_transaction_id']);
/** Payee keys whose value, when a "Transfer : <account>"-style string, signals a transfer. */
const PAYEE_KEYS = Object.freeze(['payee_name', 'payee']);
/**
 * Keys whose mere presence (any non-empty value) in an operation's PROPOSED state
 * disqualifies it. None of the four ledger-only op types legitimately repoints a
 * transaction's payee: setting a `payee_id` to an account's transfer-payee id turns
 * the transaction into a real money-moving transfer, and the allow-listed
 * `ynab_update_transaction` forwards `payee_id` straight to the YNAB API. The
 * guardrail does pure object inspection with no API lookup, so it cannot tell a
 * transfer-payee id from an ordinary one — it fails closed and treats ANY proposed
 * `payee_id` as a money-movement signal.
 */
const PAYEE_REPOINT_KEYS = Object.freeze(['payee_id']);
/**
 * YNAB names transfer payees "Transfer : <account>". Matched UNANCHORED — the
 * "Transfer :" marker need not sit at the very start of the string — and
 * case-insensitively. A false-positive here only ever *blocks*, which is the
 * fail-closed safe direction; real transfers also carry `transfer_account_id`.
 */
const TRANSFER_PAYEE_RE = /transfer\s*:/i;

/** The canonical pass verdict. */
const PASS = Object.freeze({ verdict: 'pass' });

/**
 * Prototype-pollution-safe membership check. Every allow-list / deny-list / signal-key
 * test in this module goes through `includesIn` rather than `arr.includes(x)`. The
 * canonical `Array.prototype.includes` is captured HERE, at module load — before any
 * untrusted change-set is parsed — so a host that later poisons `Array.prototype.includes`
 * (e.g. via `__proto__` pollution) cannot make a transfer-signal or deny-list check
 * silently return the wrong answer. For a guardrail whose `false` can mean "money may
 * move," the membership primitive itself must be unpoisonable.
 * @param {readonly unknown[]} arr
 * @param {unknown} value
 * @returns {boolean}
 */
const arrayIncludes = Array.prototype.includes;
function includesIn(arr, value) {
  return arrayIncludes.call(arr, value);
}

/**
 * Build a structured block verdict.
 * @param {string|null} opId   the blocked operation's id (null for envelope/tool-level blocks).
 * @param {string|null} opType the operation type (null when unknown / not applicable).
 * @param {string} rule        a RULES.* string constant.
 * @param {string} reason      a human-readable sentence.
 * @returns {{verdict:'block', op_id:string|null, op_type:string|null, rule:string, reason:string}}
 */
function block(opId, opType, rule, reason) {
  return {
    verdict: 'block',
    op_id: opId == null ? null : opId,
    op_type: opType == null ? null : opType,
    rule,
    reason,
  };
}

/**
 * Recursively scan a value for any transfer / money-movement signal: a truthy
 * `transfer_account_id` / `transfer_transaction_id`, a non-empty `payee_id`
 * (a proposed payee repoint — disqualifying for every ledger-only op), or a
 * "Transfer : ..."-style payee. Cycle-safe.
 * @param {unknown} value
 * @param {Set<object>} [seen]
 * @returns {boolean}
 */
function hasTransferSignal(value, seen = new Set()) {
  if (value === null || typeof value !== 'object') return false;
  if (seen.has(value)) return false;
  seen.add(value);

  if (Array.isArray(value)) {
    return value.some((entry) => hasTransferSignal(entry, seen));
  }

  for (const [key, v] of Object.entries(value)) {
    if (includesIn(TRANSFER_SIGNAL_KEYS, key) && v !== null && v !== undefined && v !== '') {
      return true;
    }
    if (includesIn(PAYEE_REPOINT_KEYS, key) && v !== null && v !== undefined && v !== '') {
      return true;
    }
    if (includesIn(PAYEE_KEYS, key) && typeof v === 'string' && TRANSFER_PAYEE_RE.test(v)) {
      return true;
    }
    if (v !== null && typeof v === 'object' && hasTransferSignal(v, seen)) {
      return true;
    }
  }
  return false;
}

/**
 * Evaluate a single tool name against the allow-list / deny-list. Fail-closed:
 * a tool passes ONLY if it is on the ledger-only allow-list.
 * @param {unknown} toolName the fully namespaced tool name about to be invoked.
 * @returns {{verdict:'pass'}|{verdict:'block', op_id:null, op_type:null, rule:string, reason:string}}
 */
function evaluateTool(toolName) {
  if (typeof toolName !== 'string' || toolName.length === 0) {
    return block(null, null, RULES.TOOL_NOT_ALLOWED, 'No tool name supplied; fail-closed block.');
  }
  if (includesIn(DENIED_TOOLS, toolName)) {
    return block(
      null,
      null,
      RULES.TOOL_DENIED,
      `Tool "${toolName}" is on the money-movement deny-list and may never run.`,
    );
  }
  if (includesIn(ALLOWED_TOOLS, toolName)) {
    return PASS;
  }
  return block(
    null,
    null,
    RULES.TOOL_NOT_ALLOWED,
    `Tool "${toolName}" is not on the ledger-only allow-list; fail-closed block.`,
  );
}

/**
 * Evaluate a single change-set operation. Fail-closed: returns pass ONLY when the
 * operation is a recognised ledger-only type, targets the active budget, carries
 * no money-movement signal, and (for delete_duplicate) is tagged destructive.
 * @param {unknown} op the operation object.
 * @param {{activeBudgetId?: string}} [context]
 * @returns {{verdict:'pass'}|{verdict:'block', op_id:string|null, op_type:string|null, rule:string, reason:string}}
 */
function evaluateOperation(op, context = {}) {
  const activeBudgetId = context.activeBudgetId;

  if (op === null || typeof op !== 'object' || Array.isArray(op)) {
    return block(null, null, RULES.MALFORMED_OPERATION, 'Operation is not an object; fail-closed block.');
  }

  const opId = typeof op.id === 'string' ? op.id : null;
  const opType = typeof op.type === 'string' ? op.type : null;

  // 1. Ledger-only op-type allow-list (fail-closed).
  if (opType === null || !includesIn(LEDGER_ONLY_OP_TYPES, opType)) {
    return block(
      opId,
      opType,
      RULES.OP_TYPE_NOT_ALLOWED,
      `Operation type ${opType === null ? '(missing)' : `"${opType}"`} is not in the ledger-only ` +
        `allow-list [${LEDGER_ONLY_OP_TYPES.join(', ')}]; fail-closed block.`,
    );
  }

  // 2. Scope assertion: budget_id must match the active budget. FAIL-CLOSED — with
  //    no resolvable active budget there is nothing to scope the operation against,
  //    so block; never skip. This is the documented M4-4 hot path
  //    (evaluateOperation(op, { activeBudgetId }) before every tool call): a caller
  //    that omits the budget must not silently disable per-op budget scoping. Mirrors
  //    the NO_ACTIVE_BUDGET guard in evaluateChangeset — the module can never itself
  //    be the thing that fails open.
  if (typeof activeBudgetId !== 'string' || activeBudgetId.length === 0) {
    return block(
      opId,
      opType,
      RULES.NO_ACTIVE_BUDGET,
      'No resolvable active budget supplied to evaluateOperation; the per-op budget scope ' +
        'assertion cannot run, so the operation is blocked fail-closed.',
    );
  }
  if (op.budget_id !== activeBudgetId) {
    return block(
      opId,
      opType,
      RULES.BUDGET_ID_MISMATCH,
      `Operation budget_id ${JSON.stringify(op.budget_id)} does not match the active budget ` +
        `"${activeBudgetId}".`,
    );
  }

  // 3. Money-movement / transfer smuggling. Scan the proposed state and every
  //    field EXCEPT the read-only `before` snapshot — `before` may legitimately
  //    describe a pre-existing transfer (e.g. a duplicate of a transfer being
  //    removed), which is not itself a money movement.
  const { before, ...proposed } = op;
  if (hasTransferSignal(proposed)) {
    const rule = opType === 'categorize'
      ? RULES.MONEY_MOVEMENT_IN_CATEGORIZE
      : RULES.MONEY_MOVEMENT_DETECTED;
    return block(
      opId,
      opType,
      rule,
      'Operation carries a transfer / money-movement signal (transfer account, transfer payee, ' +
        'or a proposed payee_id repoint) in its proposed state; ledger-only writes may never move money.',
    );
  }

  // 4. Scope assertion: delete_duplicate must be tagged destructive.
  if (opType === 'delete_duplicate' && op.risk !== 'destructive') {
    return block(
      opId,
      opType,
      RULES.DELETE_DUPLICATE_RISK,
      `delete_duplicate operation must carry risk "destructive"; got ${JSON.stringify(op.risk)}.`,
    );
  }

  return PASS;
}

/**
 * Evaluate a whole change-set. Asserts the envelope invariants (money_movement
 * flag, budget targeting) and runs every operation through evaluateOperation.
 * Fail-closed throughout. M4-5 calls this to surface every blocked operation
 * before presenting options to the human; M4-4 additionally calls
 * evaluateOperation / evaluateTool before each individual tool call.
 * @param {unknown} changeset
 * @param {{activeBudgetId?: string}} [options] when activeBudgetId is supplied, the
 *   envelope (and every operation) must target it; otherwise the envelope's own
 *   budget_id is treated as the active budget.
 * @returns {{verdict:'pass', blocks:[]}|{verdict:'block', blocks:Array<object>}}
 */
function evaluateChangeset(changeset, options = {}) {
  const blocks = [];

  if (changeset === null || typeof changeset !== 'object' || Array.isArray(changeset)) {
    blocks.push(block(null, null, RULES.MALFORMED_CHANGESET, 'Change-set is not an object; fail-closed block.'));
    return { verdict: 'block', blocks };
  }

  // Envelope invariant: money_movement must be STRICTLY false.
  if (changeset.money_movement !== false) {
    blocks.push(block(
      null,
      null,
      RULES.MONEY_MOVEMENT_FLAG,
      `Envelope money_movement must be false; got ${JSON.stringify(changeset.money_movement)}.`,
    ));
  }

  // Active budget: explicit override, else the envelope's own budget_id.
  const overrideBudget = options.activeBudgetId !== undefined && options.activeBudgetId !== null;
  const activeBudgetId = overrideBudget ? options.activeBudgetId : changeset.budget_id;

  // When an override is supplied, the envelope itself must target it.
  if (overrideBudget && changeset.budget_id !== options.activeBudgetId) {
    blocks.push(block(
      null,
      null,
      RULES.BUDGET_ID_MISMATCH,
      `Envelope budget_id ${JSON.stringify(changeset.budget_id)} does not match the active budget ` +
        `"${options.activeBudgetId}".`,
    ));
  }

  // Fail-closed: without an explicit override, the envelope MUST carry a resolvable
  // active budget. This is belt-and-suspenders with evaluateOperation's own
  // NO_ACTIVE_BUDGET guard (which now blocks per-op when activeBudgetId is unresolved),
  // surfacing the missing budget once at the envelope level in addition to per-op —
  // no resolvable budget = block, never a silently-skipped scope assertion.
  if (!overrideBudget && (typeof changeset.budget_id !== 'string' || changeset.budget_id.length === 0)) {
    blocks.push(block(
      null,
      null,
      RULES.NO_ACTIVE_BUDGET,
      `No resolvable active budget: neither an activeBudgetId override nor a valid envelope ` +
        `budget_id was supplied (got ${JSON.stringify(changeset.budget_id)}); fail-closed block.`,
    ));
  }

  const operations = changeset.operations;
  if (!Array.isArray(operations) || operations.length === 0) {
    blocks.push(block(
      null,
      null,
      RULES.MALFORMED_CHANGESET,
      'Change-set has no non-empty operations array; fail-closed block.',
    ));
    return { verdict: 'block', blocks };
  }

  for (const op of operations) {
    const verdict = evaluateOperation(op, { activeBudgetId });
    if (verdict.verdict === 'block') blocks.push(verdict);
  }

  if (blocks.length > 0) return { verdict: 'block', blocks };
  return { verdict: 'pass', blocks: [] };
}

module.exports = {
  LEDGER_ONLY_OP_TYPES,
  ALLOWED_TOOLS,
  DENIED_TOOLS,
  RULES,
  PASS,
  hasTransferSignal,
  evaluateTool,
  evaluateOperation,
  evaluateChangeset,
};

// CLI entry point: read a change-set file, print its verdict as JSON on stdout,
// diagnostics on stderr only, and exit non-zero on block.
if (require.main === module) {
  const USAGE = 'usage: node write-safety-guardrail.js [--active-budget <id>] <changeset.json>\n';
  const argv = process.argv.slice(2);
  let activeBudgetId;
  const files = [];
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--active-budget') {
      // FAIL-CLOSED CLI: a malformed budget pin (flag is the trailing token, or its
      // value is empty) must be a usage error, never a silent no-override that falls
      // back to the envelope budget_id — for a money-safety CLI, silently ignoring the
      // active-budget pin is exactly the kind of quiet fail-open the module forbids.
      const value = argv[i + 1];
      if (value === undefined || value.length === 0) {
        process.stderr.write(USAGE);
        process.stderr.write('error: --active-budget requires a non-empty <id> value.\n');
        process.exit(2);
      }
      activeBudgetId = value;
      i += 1;
    } else {
      files.push(argv[i]);
    }
  }

  if (files.length !== 1) {
    process.stderr.write(USAGE);
    process.exit(2);
  }

  let data;
  try {
    data = JSON.parse(fs.readFileSync(files[0], 'utf8'));
  } catch (err) {
    process.stderr.write(`could not read/parse ${files[0]}: ${err.message}\n`);
    process.exit(2);
  }

  const result = evaluateChangeset(data, activeBudgetId ? { activeBudgetId } : {});
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);

  if (result.verdict === 'block') {
    process.stderr.write(`BLOCK: ${result.blocks.length} invariant/operation refused.\n`);
    process.exit(1);
  }
  process.stderr.write('PASS: change-set is ledger-only and safe to apply.\n');
  process.exit(0);
}
