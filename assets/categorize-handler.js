'use strict';

/**
 * Categorize / recategorize write path for workbench-ynab write-back (M4-6).
 *
 * The first concrete write path that plugs into the M4-4 apply executor. Given
 * `categorize` operations from a validated, guardrail-passed change-set (M4-1 /
 * M4-2), it sets the proposed `category_id` on each target transaction via the
 * namespaced YNAB update-transaction tools — under approval, never autonomously.
 *
 * It is a DUMB, SAFE applier: it changes ONLY the category field. It never
 * touches payee, account, amount, date, or a transfer payee — recategorization
 * (overwriting an existing category) and first-time categorization (an
 * uncategorized transaction) flow through exactly the same code path; only the
 * dry-run narrative differs. Tax-awareness and category choice live upstream in
 * the proposal (M4-10), not here.
 *
 * Design rules (mirroring the executor's, deliberately):
 *  - DRY-RUN BY DEFAULT. `dryRun` is true unless the caller passes an explicit
 *    `false`. A dry-run produces a per-op before→after category diff and calls
 *    NO mutating tool.
 *  - FIELD ISOLATION. The single-transaction update payload carries ONLY
 *    `category_id` (plus the `budget_id` / `transaction_id` addressing the
 *    flat YNAB tool requires) — never `payee_id`, `account_id`, `amount`,
 *    `date`, or `transfer_account_id`, even when those appear in an op's
 *    `before` / `after` snapshots. The bulk per-entry shape is likewise just
 *    `{ id, category_id }`.
 *  - PURE LOGIC, INJECTED I/O. This module owns payload-building, category
 *    resolution, the bulk-vs-single decision, and the dry-run diff, but holds no
 *    MCP coupling: the side-effecting operations are injected as ports —
 *    `callTool(toolName, payload)` (the mutating dispatch), `listCategories(budgetId)`
 *    (read-only name→id resolution), and `toolSearch(names)` (deferred-schema
 *    loading). That keeps it unit-testable and keeps the read tool name entirely
 *    in the runtime that wires the port.
 *  - NO HARD-CODED TOOL NAMES. The write tool names are resolved from the
 *    guardrail's exported `ALLOWED_TOOLS` by suffix, so no concrete
 *    `mcp__plugin_workbench-ynab_ynab__*` string lives in this file (the
 *    swap-ready single-source-of-truth invariant, issue #87). Only the family
 *    glob — explicitly safe to mention anywhere — appears, for the ToolSearch
 *    select. Bare `mcp__ynab__*` names are never produced.
 *  - SHARED RESULT CONTRACT. Per-op results reuse the executor's `STATUS`
 *    constants, so `applied` / `skipped-stale` / `blocked` / `error` mean the
 *    same thing here as in M4-4.
 *
 * Library-only by design (like the executor): no CLI — it cannot run without its
 * MCP-backed ports, which exist only in the agent runtime that wires them.
 *
 * Usage (M4-5 approval command):
 *   const { applyCategorize, categorizeToolMap } = require('./assets/categorize-handler');
 *   const results = await applyCategorize(categorizeOps, {
 *     dryRun: false,                                  // omit/true = simulate
 *     callTool: async (toolName, payload) => ({ ...mcp result }),
 *     listCategories: async (budgetId) => [{ id, name }, ...],
 *     toolSearch: async (names) => { ...ToolSearch select },
 *     bulkPartialUpdate: true,                        // see bulk note below
 *   });
 *   // results: [{ op_id, transaction_id, status, before, after, dry_run, detail }, ...]
 */

const { STATUS } = require('./apply-executor');
const { ALLOWED_TOOLS } = require('./write-safety-guardrail');

/** The op type this handler is the sole registered handler for (M4-4 registration). */
const CATEGORIZE_TYPE = 'categorize';

/**
 * The YNAB MCP tool family glob. Safe to mention anywhere (it is the documented
 * namespace derivation rule, not a concrete name the swap-guard matches), so it
 * is used for the ToolSearch select that loads the deferred read+write schemas.
 * @type {string}
 */
const TOOL_FAMILY_GLOB = 'mcp__plugin_workbench-ynab_ynab__ynab_*';

/**
 * Resolve the two write tools this path uses from the guardrail's allow-list by
 * suffix — never a hard-coded namespaced name. `endsWith('_update_transaction')`
 * matches only the singular (the plural ends in `s`); `_update_transactions`
 * matches only the bulk tool.
 * @returns {{single: string, bulk: string}}
 */
function resolveTools() {
  const single = ALLOWED_TOOLS.find((t) => t.endsWith('_update_transaction'));
  const bulk = ALLOWED_TOOLS.find((t) => t.endsWith('_update_transactions'));
  if (!single || !bulk) {
    throw new Error(
      'categorize handler: update-transaction tool(s) not found on the guardrail allow-list — ' +
        'the ledger-only allow-list must enumerate ynab_update_transaction(s).',
    );
  }
  return { single, bulk };
}

/**
 * The executor registration point: op-type → namespaced mutating tool. The
 * single-transaction tool is the executor's per-op dispatch target; the bulk
 * tool is used by this handler's own batch path (the executor's per-op loop
 * cannot express a single bulk call across multiple ops).
 * @returns {Record<string, string>}
 */
function categorizeToolMap() {
  return { [CATEGORIZE_TYPE]: resolveTools().single };
}

/** Extract a human-readable message from a thrown value. */
function errMessage(err) {
  if (err && typeof err.message === 'string') return err.message;
  return String(err);
}

/**
 * Whether a thrown error is an unloaded-schema InputValidationError (deferred
 * tool schema not loaded yet) rather than a server outage — the boot-patience
 * signal.
 * @param {unknown} err
 * @returns {boolean}
 */
function isInputValidationError(err) {
  const name = err && err.name;
  const msg = (err && err.message) || '';
  return name === 'InputValidationError' || /InputValidationError/i.test(String(msg));
}

/** Default boot-patience sleep. */
const defaultSleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Run `fn`, retrying on an InputValidationError with brief sleeps (boot patience):
 * an unloaded deferred schema is NOT an outage — the YNAB MCP may take ~10s to
 * boot, so retry before concluding failure (mirrors the bujo-orchestrator
 * pattern). A non-InputValidationError propagates immediately.
 * @template T
 * @param {() => Promise<T>} fn
 * @param {{sleep?: Function, retries?: number, delayMs?: number}} [opts]
 * @returns {Promise<T>}
 */
async function withBootPatience(fn, { sleep = defaultSleep, retries = 5, delayMs = 2000 } = {}) {
  let lastErr;
  for (let attempt = 0; attempt <= retries; attempt += 1) {
    try {
      return await fn();
    } catch (err) {
      if (!isInputValidationError(err)) throw err;
      lastErr = err;
      if (attempt < retries) await sleep(delayMs);
    }
  }
  throw lastErr;
}

/**
 * Load the deferred YNAB tool schemas before the first MCP call (read or write),
 * via an injected `ToolSearch` select on the resolved write tools plus the family
 * glob (which covers the read tools). Boot-patient: an InputValidationError is
 * treated as "schema not loaded yet" and retried, never as an outage. A no-op
 * when no `toolSearch` port is wired (e.g. pure dry-run unit tests).
 * @param {{toolSearch?: Function, sleep?: Function, retries?: number, delayMs?: number}} [ctx]
 */
async function loadSchemas({ toolSearch, sleep, retries, delayMs } = {}) {
  if (typeof toolSearch !== 'function') return;
  const { single, bulk } = resolveTools();
  const names = [single, bulk, TOOL_FAMILY_GLOB];
  await withBootPatience(() => toolSearch(names), { sleep, retries, delayMs });
}

/**
 * Resolve the proposed category id for an op. PREFER the already-resolved
 * `after.category_id` — the M4-10 proposal SHOULD pre-resolve ids so this lookup
 * never runs. ONLY when the id is absent do we fall back to a name lookup via the
 * injected read port (`listCategories`). Never throws: an unresolvable name (or a
 * lookup failure, or a missing port) returns `{ error }`, which the caller turns
 * into an `error` result so the rest of the batch still proceeds.
 * @param {object} op
 * @param {{listCategories?: Function}} ctx
 * @returns {Promise<{category_id: string, category_name: string|null}|{error: string}>}
 */
async function resolveCategory(op, { listCategories }) {
  const after = (op && op.after) || {};
  if (typeof after.category_id === 'string' && after.category_id.length > 0) {
    return { category_id: after.category_id, category_name: after.category_name ?? null };
  }

  const name = after.category_name;
  if (typeof name !== 'string' || name.length === 0) {
    return { error: `categorize op ${op && op.id}: after carries neither a category_id nor a category_name to resolve.` };
  }
  if (typeof listCategories !== 'function') {
    return { error: `categorize op ${op.id}: after.category_id absent and no listCategories port wired to resolve "${name}".` };
  }

  let categories;
  try {
    categories = await listCategories(op.budget_id);
  } catch (err) {
    return { error: `categorize op ${op.id}: category lookup failed: ${errMessage(err)}` };
  }
  const match = (Array.isArray(categories) ? categories : []).find((c) => c && c.name === name);
  if (!match || typeof match.id !== 'string' || match.id.length === 0) {
    return { error: `categorize op ${op.id}: category name "${name}" did not resolve to an id.` };
  }
  return { category_id: match.id, category_name: name };
}

/**
 * Field-isolated single-transaction update payload: ONLY the category field, plus
 * the `budget_id` / `transaction_id` addressing the flat YNAB tool requires. No
 * payee / account / amount / date / transfer field is ever included.
 * @returns {{budget_id: string, transaction_id: string, category_id: string}}
 */
function buildSingleUpdate(op, categoryId) {
  return { budget_id: op.budget_id, transaction_id: op.transaction_id, category_id: categoryId };
}

/**
 * Field-isolated bulk per-transaction entry: ONLY `{ id, category_id }`. The bulk
 * tool keys each entry on the transaction `id`; we never resupply amount/date/etc.
 * @returns {{id: string, category_id: string}}
 */
function buildBulkEntry(op, categoryId) {
  return { id: op.transaction_id, category_id: categoryId };
}

/**
 * A per-op before→after category diff (ids + names), conforming to the executor's
 * dry-run detail structure (`{ simulated, diff }`). Recategorization and
 * first-time categorization share this builder; ONLY the narrative wording
 * differs (first-time when `before.category_id` is null/absent).
 */
function buildDiff(op, resolved) {
  const before = (op && op.before) || {};
  const firstTime = before.category_id == null || before.category_id === '';
  const beforeView = { category_id: before.category_id ?? null, category_name: before.category_name ?? null };
  const afterView = { category_id: resolved.category_id, category_name: resolved.category_name ?? null };
  const toLabel = afterView.category_name ?? afterView.category_id;
  const narrative = firstTime
    ? `categorize uncategorized transaction as ${toLabel}`
    : `recategorize from ${beforeView.category_name ?? beforeView.category_id} to ${toLabel}`;
  return { before: beforeView, after: afterView, narrative };
}

/**
 * Build a per-op result in the executor's contract, extended with the
 * categorize-specific `transaction_id` / `before` / `after` the M4-5 command
 * renders (AC8).
 */
function result(op, status, dryRun, detail) {
  return {
    op_id: (op && op.id) == null ? null : op.id,
    transaction_id: (op && op.transaction_id) == null ? null : op.transaction_id,
    status,
    dry_run: dryRun,
    before: (op && op.before) == null ? null : op.before,
    after: (op && op.after) == null ? null : op.after,
    detail,
  };
}

/**
 * Whether the batch can go through a single bulk call. Bulk is PREFERRED for ≥2
 * resolvable ops that share a budget and each yield a `{ id, category_id }` entry;
 * anything else falls back to per-transaction calls. (A single op gets a single
 * call with no batching benefit; a cross-budget batch cannot be one bulk call,
 * since the bulk tool takes one budget_id.)
 * @param {Array<{op: object, resolved: {category_id?: string}}>} candidates
 * @returns {boolean}
 */
function bulkFits(candidates) {
  if (candidates.length < 2) return false;
  const budgetId = candidates[0].op.budget_id;
  return candidates.every(({ op, resolved }) =>
    typeof op.transaction_id === 'string' && op.transaction_id.length > 0 &&
    typeof resolved.category_id === 'string' && resolved.category_id.length > 0 &&
    op.budget_id === budgetId);
}

/** Apply one op via the single-transaction tool. Returns its per-op result. */
async function applySingle(op, categoryId, { callTool, singleTool, sleep, retries, delayMs }) {
  try {
    const mcp = await withBootPatience(
      () => callTool(singleTool, buildSingleUpdate(op, categoryId)),
      { sleep, retries, delayMs },
    );
    return result(op, STATUS.APPLIED, false, { tool: singleTool, result: mcp == null ? null : mcp });
  } catch (err) {
    return result(op, STATUS.ERROR, false, { phase: 'apply', tool: singleTool, message: errMessage(err) });
  }
}

/** Apply each candidate individually via the single-transaction tool (the fallback path). */
async function applyPerTransaction(candidates, deps) {
  const out = [];
  for (const { op, resolved } of candidates) {
    out.push(await applySingle(op, resolved.category_id, deps));
  }
  return out;
}

/**
 * Apply a batch of `categorize` ops. Dry-run by default — real apply requires an
 * explicit `dryRun: false` (the M4-5 approval command sets it only after the human
 * approves). Returns one per-op result (AC8); never throws for a per-op failure —
 * an unresolvable category or a tool error is isolated as an `error` result and the
 * rest of the batch proceeds.
 *
 * Real-apply dispatch PREFERS a single bulk `ynab_update_transactions` call to
 * minimize round-trips, and falls back to per-transaction `ynab_update_transaction`
 * calls when the bulk call shape does not fit. The documented fallback conditions:
 *   (a) the batch has fewer than 2 resolvable ops (no batching benefit);
 *   (b) an op cannot form a `{ id, category_id }` bulk entry, or the batch spans
 *       multiple budgets (`bulkFits` is false); or
 *   (c) the bulk dispatch is rejected at runtime because the bulk tool's per-entry
 *       schema does not accept a category-only partial update — each op is then
 *       retried individually as a flat `{ budget_id, transaction_id, category_id }`
 *       update. Retrying is SAFE because a categorize write is idempotent
 *       (re-setting the same category is a no-op-equivalent, never money movement).
 *
 * @param {object[]} ops the `categorize` operations (already schema-validated and
 *   guardrail-passed by the executor / approval command).
 * @param {object} [ctx]
 * @param {boolean} [ctx.dryRun=true] real apply requires an explicit `false`.
 * @param {(toolName: string, payload: object) => (unknown|Promise<unknown>)} [ctx.callTool]
 *   REQUIRED for real apply — the mutating MCP dispatch.
 * @param {(budgetId: string) => (Array|Promise<Array>)} [ctx.listCategories] read-only
 *   port for name→id resolution; only needed when an op's `after.category_id` is absent.
 * @param {(names: string[]) => (unknown|Promise<unknown>)} [ctx.toolSearch] ToolSearch
 *   select port to load deferred schemas before the first MCP call.
 * @param {Function} [ctx.sleep] @param {number} [ctx.retries] @param {number} [ctx.delayMs]
 *   boot-patience knobs.
 * @returns {Promise<Array<{op_id:string|null, transaction_id:string|null, status:string,
 *   before:object|null, after:object|null, dry_run:boolean, detail:object}>>}
 */
async function applyCategorize(ops, ctx = {}) {
  const operations = Array.isArray(ops) ? ops : [];
  const { dryRun = true, callTool, listCategories, toolSearch, sleep, retries, delayMs } = ctx;
  const patience = { sleep, retries, delayMs };

  // Load the deferred tool schemas before the FIRST MCP call, in any mode (AC7).
  await loadSchemas({ toolSearch, ...patience });

  // Resolve every op's target category id up front (AC6). Field-isolated; an
  // unresolvable name is carried as an error and never dispatched.
  const prepared = [];
  for (const op of operations) {
    prepared.push({ op, resolved: await resolveCategory(op, { listCategories }) });
  }

  // Dry-run: a per-op before→after category diff, no mutating call (AC5).
  if (dryRun) {
    return prepared.map(({ op, resolved }) => (resolved.error
      ? result(op, STATUS.ERROR, true, { phase: 'resolve', message: resolved.error })
      : result(op, STATUS.APPLIED, true, { simulated: true, diff: buildDiff(op, resolved) })));
  }

  // Real apply requires the mutating dispatch port.
  if (typeof callTool !== 'function') {
    throw new TypeError('applyCategorize real apply (dryRun: false) requires a callTool(toolName, payload) function');
  }
  const { single: singleTool, bulk: bulkTool } = resolveTools();
  const deps = { callTool, singleTool, ...patience };

  // Unresolvable ops become error results immediately; only resolvable ops dispatch.
  const errored = prepared.filter(({ resolved }) => resolved.error);
  const candidates = prepared.filter(({ resolved }) => !resolved.error);
  const results = errored.map(({ op, resolved }) => result(op, STATUS.ERROR, false, { phase: 'resolve', message: resolved.error }));

  if (candidates.length === 0) return results;

  if (bulkFits(candidates)) {
    const payload = {
      budget_id: candidates[0].op.budget_id,
      transactions: candidates.map(({ op, resolved }) => buildBulkEntry(op, resolved.category_id)),
    };
    try {
      const mcp = await withBootPatience(() => callTool(bulkTool, payload), patience);
      for (const { op } of candidates) {
        results.push(result(op, STATUS.APPLIED, false, { tool: bulkTool, bulk: true, result: mcp == null ? null : mcp }));
      }
    } catch (err) {
      // Fallback (c): the bulk tool rejected the category-only batch shape. Retry
      // each op individually — safe because a categorize write is idempotent.
      const fallback = await applyPerTransaction(candidates, deps);
      results.push(...fallback);
    }
    return results;
  }

  // Fallback (a)/(b): per-transaction calls.
  results.push(...(await applyPerTransaction(candidates, deps)));
  return results;
}

module.exports = {
  CATEGORIZE_TYPE,
  TOOL_FAMILY_GLOB,
  resolveTools,
  categorizeToolMap,
  isInputValidationError,
  withBootPatience,
  loadSchemas,
  resolveCategory,
  buildSingleUpdate,
  buildBulkEntry,
  buildDiff,
  bulkFits,
  applyCategorize,
};
