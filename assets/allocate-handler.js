'use strict';

/**
 * Allocate / set-budgeted-amount write path for workbench-ynab write-back (M4-7).
 *
 * The op-type-specific layer the apply executor (M4-4, assets/apply-executor.js)
 * runs an `allocate` operation through. The executor owns the generic apply loop
 * (validate → guardrail → drift-check → simulate-or-dispatch → audit); this
 * module supplies only what is unique to `allocate`:
 *   - the op-type → mutating-tool registration (`toolMapEntry`), so the executor
 *     dispatches `allocate` ops to `ynab_update_category`;
 *   - the argument shape for that tool (`buildApplyArgs`), so the runtime's
 *     `applyOp` port knows what to pass;
 *   - field validation (`validateAllocateOp`) that rejects a malformed op with a
 *     descriptive error before any tool is touched;
 *   - the human-readable dry-run rendering (`renderDiff`, `formatMilliunits`);
 *   - the Ready-to-Assign (RTA) over-allocation check (`assessOverAllocation`,
 *     `dryRunAllocate`) that warns — advisory only — when a batch of allocations
 *     would drive RTA negative.
 *
 * WHAT ALLOCATE IS — AND IS NOT. An `allocate` operation is a LEDGER-INTERNAL
 * reassignment of *budgeted dollars*: it sets a category's `budgeted` amount for
 * a month, moving dollars between categories / out of Ready-to-Assign INSIDE the
 * budget. It does NOT move real money. The M4-2 write-safety guardrail classifies
 * it as `allocate` (allowed, non-money-movement). This handler MUST NEVER call any
 * account-to-account, transfer, or transaction-creating tool — its only mutating
 * tool is `ynab_update_category` (resolved below), which sets `budgeted` and
 * nothing else (no goals, no category name, no hidden state).
 *
 * Design rules (mirror the executor):
 *  - NAMESPACED TOOLS ONLY, never hard-coded here. The mutating tool name is
 *    resolved at runtime from the guardrail's exported `ALLOWED_TOOLS` by suffix,
 *    so no literal `mcp__plugin_workbench-ynab_ynab__*` string lives in this file
 *    (the swap-ready single-source-of-truth invariant, issue #87; enforced by
 *    bin/check-tool-name-sources.sh). The read tool used for the RTA check
 *    (`ynab_get_month`) is supplied by the caller as the injected `getMonth` port,
 *    wired from skills/protocol/ynab-tools.md — same reason.
 *  - MILLIUNITS THROUGHOUT. `before.budgeted` / `after.budgeted` and every RTA
 *    figure are raw integer milliunits, passed to the YNAB API verbatim. The ÷1000
 *    currency conversion happens ONLY in human-facing output (`formatMilliunits`),
 *    never on the apply path. Negative `budgeted` (de-funding a category) is valid.
 *  - DRY-RUN IS READ-ONLY. `dryRunAllocate` issues NO write call; it reads
 *    `ynab_get_month` (via the port) purely to compute the advisory RTA warning.
 *  - LIBRARY-ONLY, no CLI. Like the executor, the dry-run path cannot run without
 *    its injected MCP read port, which exists only in the agent runtime.
 *
 * Wiring (M4-5 approval command / the executor's ports):
 *   const allocate = require('./assets/allocate-handler');
 *   // 1. register with the executor's toolMap:
 *   const toolMap = { ...allocate.toolMapEntry() };       // { allocate: <namespaced update_category> }
 *   // 2. the runtime's applyOp shapes the call from buildApplyArgs:
 *   const applyOp = async (toolName, op) =>
 *     mcp(toolName, op.type === 'allocate' ? allocate.buildApplyArgs(op) : ...);
 *   // 3. before approval, render the dry-run + RTA warning:
 *   const preview = await allocate.dryRunAllocate(changeset.operations, {
 *     getMonth: async ({ budget_id, month }) => mcp('<ynab_get_month>', { budget_id, month }),
 *   });
 */

const { ALLOWED_TOOLS } = require('./write-safety-guardrail');
const { formatMoney } = require('./format-money');

/** The operation type this handler owns. */
const OP_TYPE = 'allocate';

/**
 * Suffix of the namespaced mutating tool (`ynab_update_category`). Resolved from
 * the guardrail allow-list rather than written literally, so the concrete
 * `mcp__plugin_workbench-ynab_ynab__*` name never appears in this file (#87 guard).
 */
const APPLY_TOOL_SUFFIX = '_update_category';

/**
 * Suffix of the read tool the RTA check needs (`ynab_get_month`). Documented here
 * for the wiring layer; this module does NOT resolve it (read tools are not on the
 * guardrail allow-list) — the caller injects a `getMonth` port wired to it from
 * skills/protocol/ynab-tools.md.
 */
const READ_TOOL_SUFFIX = '_get_month';

/**
 * Resolve the fully-namespaced `ynab_update_category` tool from the guardrail's
 * allow-list by suffix. Throws if it is somehow absent (a guardrail/handler
 * mismatch is a hard configuration error, never a silent fallback).
 * @returns {string} the namespaced mutating tool name.
 */
function applyToolName() {
  const tool = ALLOWED_TOOLS.find((t) => t.endsWith(APPLY_TOOL_SUFFIX));
  if (!tool) {
    throw new Error(
      `allocate handler: no allow-listed tool ending in "${APPLY_TOOL_SUFFIX}" — ` +
        'the guardrail ALLOWED_TOOLS and this handler are out of sync.',
    );
  }
  return tool;
}

/**
 * The registration entry for the apply executor's `toolMap`: maps the `allocate`
 * op type to its namespaced mutating tool. Spread into the executor's toolMap.
 * @returns {{allocate: string}}
 */
function toolMapEntry() {
  return { [OP_TYPE]: applyToolName() };
}

/**
 * Validate an `allocate` operation's required fields. Independent of the Ajv schema
 * (assets/changeset-schema.json) so the handler can reject a malformed op fast,
 * with a descriptive, op-local error, before building apply args or touching any
 * tool. Checks: type, the three string targets (budget_id, category_id, month),
 * the month format (YNAB `YYYY-MM-01`), and integer `before.budgeted` /
 * `after.budgeted` milliunits.
 * @param {unknown} op
 * @returns {{valid: boolean, errors: string[]}}
 */
function validateAllocateOp(op) {
  const errors = [];
  if (op === null || typeof op !== 'object' || Array.isArray(op)) {
    return { valid: false, errors: ['operation is not an object'] };
  }
  if (op.type !== OP_TYPE) {
    errors.push(`type must be "${OP_TYPE}"; got ${JSON.stringify(op.type)}`);
  }
  for (const field of ['budget_id', 'category_id', 'month']) {
    if (typeof op[field] !== 'string' || op[field].length === 0) {
      errors.push(`${field} is required and must be a non-empty string`);
    }
  }
  if (typeof op.month === 'string' && !/^\d{4}-(0[1-9]|1[0-2])-01$/.test(op.month)) {
    errors.push(`month must be a YNAB first-of-month date (YYYY-MM-01); got ${JSON.stringify(op.month)}`);
  }
  for (const side of ['before', 'after']) {
    const snapshot = op[side];
    if (snapshot === null || typeof snapshot !== 'object' || Array.isArray(snapshot)) {
      errors.push(`${side} is required and must be an object with an integer budgeted`);
    } else if (!Number.isInteger(snapshot.budgeted)) {
      errors.push(`${side}.budgeted is required and must be an integer (milliunits); got ${JSON.stringify(snapshot.budgeted)}`);
    }
  }
  return { valid: errors.length === 0, errors };
}

/**
 * Build the argument object for `ynab_update_category` from an `allocate` op. The
 * vendored YNAB MCP takes a FLAT shape — `{ budget_id, category_id, budgeted, month }`
 * — and `budgeted` is set to `after.budgeted` in RAW milliunits (verbatim, no
 * conversion). Sets `budgeted` and nothing else: no goal, category name, or hidden
 * state is touched. Throws a descriptive error on an invalid op so a malformed
 * operation can never reach the YNAB API.
 * @param {object} op an `allocate` operation.
 * @returns {{budget_id: string, category_id: string, month: string, budgeted: number}}
 */
function buildApplyArgs(op) {
  const { valid, errors } = validateAllocateOp(op);
  if (!valid) {
    throw new Error(`allocate handler: invalid allocate op — ${errors.join('; ')}`);
  }
  return {
    budget_id: op.budget_id,
    category_id: op.category_id,
    month: op.month,
    budgeted: op.after.budgeted,
  };
}

/**
 * Format raw milliunits as a human-readable currency string. Display-only: the
 * ÷1000 conversion happens on the display path (contract §2: `250000` → `$250.00`,
 * `-54990` → `-$54.99`), never on the apply path. Delegates to the shared money
 * helper (assets/format-money.js — issue #34, ROADMAP #8, contract §2), the single
 * source of truth for milliunits → currency formatting. The write path does not
 * fetch the budget's `currency_format`, so the dry-run renders with the US/USD
 * default; when a non-USD write path is built it passes the budget's format here.
 * @param {number} milliunits raw integer milliunits.
 * @returns {string}
 */
function formatMilliunits(milliunits) {
  return formatMoney(milliunits);
}

/**
 * Render a single allocate op as a human-readable before→after diff line, showing
 * the category name (resolved by the caller; falls back to the category id) and the
 * budgeted delta in currency units. Pure — no I/O.
 * @param {object} op an `allocate` operation.
 * @param {string} [categoryName] resolved category name; defaults to the category id.
 * @returns {string} e.g. "Groceries — 2026-06-01: $0.00 → $250.00 (+$250.00)"
 */
function renderDiff(op, categoryName) {
  const before = op.before.budgeted;
  const after = op.after.budgeted;
  const delta = after - before;
  const name = categoryName || op.category_id;
  const deltaStr = delta > 0 ? `+${formatMilliunits(delta)}` : formatMilliunits(delta);
  return `${name} — ${op.month}: ${formatMilliunits(before)} → ${formatMilliunits(after)} (${deltaStr})`;
}

/**
 * Assess whether a set of allocate ops over-allocates a month's Ready-to-Assign.
 * Pure arithmetic: RTA decreases by the net budgeted delta, so the projected RTA
 * is `readyToAssign − Σ(after.budgeted − before.budgeted)`; the batch over-allocates
 * when that projection is negative. ADVISORY ONLY — this never blocks; the human
 * decides at the approval step (M4-5).
 * @param {object[]} ops allocate operations (non-allocate ops are ignored).
 * @param {number} readyToAssign current month Ready-to-Assign (`to_be_budgeted`), milliunits.
 * @returns {{total_delta:number, ready_to_assign:number, projected_ready_to_assign:number,
 *   over_allocated:boolean, message:(string|null)}}
 */
function assessOverAllocation(ops, readyToAssign) {
  const allocateOps = (Array.isArray(ops) ? ops : []).filter((op) => op && op.type === OP_TYPE);
  const totalDelta = allocateOps.reduce((sum, op) => sum + (op.after.budgeted - op.before.budgeted), 0);
  const projected = readyToAssign - totalDelta;
  const overAllocated = projected < 0;
  return {
    total_delta: totalDelta,
    ready_to_assign: readyToAssign,
    projected_ready_to_assign: projected,
    over_allocated: overAllocated,
    message: overAllocated
      ? `⚠️ Over-allocation: this batch budgets a net ${formatMilliunits(totalDelta)} but only ` +
        `${formatMilliunits(readyToAssign)} is Ready to Assign — Ready to Assign would fall to ` +
        `${formatMilliunits(projected)}.`
      : null,
  };
}

/**
 * Produce the dry-run preview for a batch's allocate ops: a per-op before→after
 * diff plus a per-month advisory over-allocation warning. Issues NO write call.
 *
 * Reads `ynab_get_month` (via the injected `getMonth` port) once per distinct
 * (budget_id, month) to obtain that month's Ready-to-Assign and its category names,
 * then groups the allocate ops by month and runs `assessOverAllocation` per group —
 * Ready-to-Assign is inherently per-month, so a batch spanning months is checked
 * month-by-month rather than as one cross-month sum.
 *
 * @param {object[]} operations the change-set operations (non-allocate ops are skipped).
 * @param {object} ports
 * @param {(args:{budget_id:string, month:string})=>(object|Promise<object>)} ports.getMonth
 *   REQUIRED read-only port returning the month entity (`{ to_be_budgeted, categories? }`),
 *   wired to `ynab_get_month` by the runtime. Throws if missing.
 * @returns {Promise<{dry_run:true, over_allocated:boolean,
 *   operations:Array<{op_id:(string|null), category_id:string, month:string, budget_id:string,
 *     before:number, after:number, delta:number, diff:string}>,
 *   warnings:Array<{budget_id:string, month:string, ready_to_assign:(number|null),
 *     total_delta:number, projected_ready_to_assign:(number|null), message:string}>}>}
 */
async function dryRunAllocate(operations, ports = {}) {
  const { getMonth } = ports;
  if (typeof getMonth !== 'function') {
    throw new TypeError('dryRunAllocate requires a getMonth({ budget_id, month }) read port');
  }

  const allocateOps = (Array.isArray(operations) ? operations : []).filter((op) => op && op.type === OP_TYPE);

  // Read each distinct (budget_id, month) month exactly once; cache by key.
  const monthCache = new Map();
  const monthKey = (op) => `${op.budget_id} ${op.month}`;
  for (const op of allocateOps) {
    const key = monthKey(op);
    if (!monthCache.has(key)) {
      monthCache.set(key, await getMonth({ budget_id: op.budget_id, month: op.month }));
    }
  }

  // Build an id→name map from a month entity's categories (defensive about shape).
  const categoryName = (month, categoryId) => {
    const categories = month && Array.isArray(month.categories) ? month.categories : [];
    const match = categories.find((c) => c && c.id === categoryId);
    return match && typeof match.name === 'string' ? match.name : undefined;
  };

  const opsOut = allocateOps.map((op) => {
    const month = monthCache.get(monthKey(op));
    return {
      op_id: op.id == null ? null : op.id,
      category_id: op.category_id,
      month: op.month,
      budget_id: op.budget_id,
      before: op.before.budgeted,
      after: op.after.budgeted,
      delta: op.after.budgeted - op.before.budgeted,
      diff: renderDiff(op, categoryName(month, op.category_id)),
    };
  });

  // One over-allocation assessment per distinct month group.
  const warnings = [];
  const seen = new Set();
  for (const op of allocateOps) {
    const key = monthKey(op);
    if (seen.has(key)) continue;
    seen.add(key);
    const month = monthCache.get(key);
    const rta = month && Number.isFinite(month.to_be_budgeted) ? month.to_be_budgeted : null;
    const groupOps = allocateOps.filter((o) => monthKey(o) === key);
    // RTA unavailable (port returned no usable to_be_budgeted) → no advisory warning;
    // never invent a figure, and never block on a missing read.
    if (rta === null) continue;
    const assessment = assessOverAllocation(groupOps, rta);
    if (assessment.over_allocated) {
      warnings.push({
        budget_id: op.budget_id,
        month: op.month,
        ready_to_assign: assessment.ready_to_assign,
        total_delta: assessment.total_delta,
        projected_ready_to_assign: assessment.projected_ready_to_assign,
        message: assessment.message,
      });
    }
  }

  return {
    dry_run: true,
    over_allocated: warnings.length > 0,
    operations: opsOut,
    warnings,
  };
}

module.exports = {
  OP_TYPE,
  APPLY_TOOL_SUFFIX,
  READ_TOOL_SUFFIX,
  applyToolName,
  toolMapEntry,
  validateAllocateOp,
  buildApplyArgs,
  formatMilliunits,
  renderDiff,
  assessOverAllocation,
  dryRunAllocate,
};
