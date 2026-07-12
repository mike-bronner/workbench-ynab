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
 * uncategorized transaction) flow through exactly the same code path. Tax-awareness
 * and category choice live upstream in the proposal (M4-10), not here.
 *
 * ROUTES THROUGH THE EXECUTOR (the locked M4-6 architecture, Option 1). This
 * handler does NOT run its own apply loop. It hands the batch to the M4-4 apply
 * executor (`applyChangeset`), registering:
 *  - `categorizeToolMap()` — op-type → the per-op `ynab_update_transaction` tool;
 *  - `categorizeBulkToolMap()` — op-type → the bulk `ynab_update_transactions` tool;
 *  - `makeCategorizeApplyOp` / `makeCategorizeBulkApplyOp` — the field-isolated
 *    dispatch ports (per-op and one-call-for-the-group); and
 *  - `categorizeBulkFits` — the predicate that decides whether a group of survivors
 *    goes through one bulk call.
 * The executor owns the loop, so bulk dispatch STILL gets per-op drift detection
 * (`skipped-stale`), the per-op guardrail re-check (`blocked`), the mandatory M4-3
 * audit record, and the per-op-fallback when the bulk shape is rejected — none of
 * which a bespoke handler loop would inherit. This is why the four result statuses
 * are all reachable through this path.
 *
 * Design rules:
 *  - SINGLE-TYPE BATCHES. This is the SOLE handler for `categorize` ops (AC1), and
 *    M4-5 routes each op to the handler whose op_type matches (the sibling reconcile
 *    / allocate handlers assume the same single-type contract). A foreign-type op is
 *    never forwarded into the executor batch — it would have no categorize tool and
 *    would abort the whole batch in the executor's tool pre-flight, poisoning the
 *    valid categorize ops. A mis-routed op instead gets its own terminal per-op
 *    `error` result (`phase: 'routing'`) and is kept out of the executor batch.
 *  - DRY-RUN BY DEFAULT. `dryRun` is true unless the caller passes an explicit
 *    `false`; a dry-run produces the executor's per-op before→after diff and calls
 *    NO mutating tool.
 *  - FIELD ISOLATION. The single-transaction update payload carries ONLY
 *    `category_id` (plus the `budget_id` / `transaction_id` addressing the flat
 *    YNAB tool requires); the bulk per-entry shape is just `{ id, category_id }`.
 *    No payee / account / amount / date / transfer field is ever included, even
 *    when present in an op's `before` / `after` snapshots.
 *  - CATEGORY RESOLUTION IS A READ-ONLY PREP STEP, BEFORE THE EXECUTOR. When an
 *    op's `after.category_id` is absent, its `after.category_name` is resolved to an
 *    id via the injected `listCategories` port and written into a copy of the op, so
 *    the change-set the executor schema-validates is well-formed and every op still
 *    gets drift / guardrail / audit. On schema-valid input `after.category_id` is
 *    always present (the schema requires it, `changeset-schema.json`), so this is a
 *    pass-through: the name path is the documented fallback the M4-10 proposal
 *    SHOULD make unnecessary. An unresolvable name never reaches the executor — it
 *    becomes an `error` result here (never a thrown exception).
 *  - NO HARD-CODED TOOL NAMES. The write tool names are resolved from the guardrail's
 *    exported `ALLOWED_TOOLS` by suffix, so no concrete
 *    `mcp__plugin_workbench-ynab_ynab__*` string lives in this file (the swap-ready
 *    single-source-of-truth invariant, issue #87). Only the family glob — explicitly
 *    safe to mention anywhere — appears, for the ToolSearch select. Bare
 *    `mcp__ynab__*` names are never produced.
 *  - SHARED RESULT CONTRACT. Per-op results reuse the executor's `STATUS` constants,
 *    extended with the categorize-specific `transaction_id` / `before` / `after` the
 *    M4-5 command renders (AC8).
 *
 * Library-only by design (like the executor): no CLI — it cannot run without its
 * MCP-backed ports, which exist only in the agent runtime that wires them.
 *
 * Usage (M4-5 approval command):
 *   const { applyCategorize } = require('./assets/categorize-handler');
 *   const outcome = await applyCategorize(changeset, {
 *     activeBudgetId,                                 // mandatory non-empty string
 *     dryRun: false,                                  // omit/true = simulate
 *     callTool: async (toolName, payload) => ({ ...mcp result }),
 *     listCategories: async (budgetId) => [{ id, name }, ...],
 *     toolSearch: async (names) => { ...ToolSearch select },
 *     readLiveState: async (op) => ({ ...fields shaped like op.before }),  // drift detection
 *     audit: async ({ operation, result, dryRun }) => { ... },             // M4-3 sink
 *   });
 *   // outcome.results: [{ op_id, transaction_id, status, dry_run, before, after, detail }, ...]
 */

const { STATUS, OUTCOME, applyChangeset } = require('./apply-executor');
const { validateChangeset } = require('./validate-changeset');
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
 * The executor per-op registration point: op-type → the single-transaction tool
 * the executor dispatches (and the bulk path falls back to).
 * @returns {Record<string, string>}
 */
function categorizeToolMap() {
  return { [CATEGORIZE_TYPE]: resolveTools().single };
}

/**
 * The executor bulk registration point: op-type → the bulk `ynab_update_transactions`
 * tool. Supplied alongside `categorizeBulkFits` so the executor collapses a group of
 * survivors into ONE call (while still drift-checking, guardrailing, and auditing
 * each op individually).
 * @returns {Record<string, string>}
 */
function categorizeBulkToolMap() {
  return { [CATEGORIZE_TYPE]: resolveTools().bulk };
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
 *
 * On each retry, `onRetry` (when supplied) runs FIRST — an InputValidationError
 * means the deferred schema isn't loaded, so the fix is to RELOAD it (re-run the
 * ToolSearch select), not merely to sleep and re-hit the same unloaded schema. The
 * reload is best-effort: if it throws, we still wait and retry the call.
 * @template T
 * @param {() => Promise<T>} fn
 * @param {{sleep?: Function, retries?: number, delayMs?: number, onRetry?: Function}} [opts]
 * @returns {Promise<T>}
 */
async function withBootPatience(fn, { sleep = defaultSleep, retries = 5, delayMs = 2000, onRetry } = {}) {
  let lastErr;
  for (let attempt = 0; attempt <= retries; attempt += 1) {
    try {
      return await fn();
    } catch (err) {
      if (!isInputValidationError(err)) throw err;
      lastErr = err;
      if (attempt < retries) {
        if (typeof onRetry === 'function') {
          try { await onRetry(); } catch { /* best-effort reload; fall through to wait + retry */ }
        }
        await sleep(delayMs);
      }
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
 * injected read port (`listCategories`). Never throws: an unresolvable name, an
 * AMBIGUOUS name (>1 match — YNAB allows identically-named categories across
 * groups, and `after` carries no group to disambiguate), a cross-budget op, a
 * lookup failure, or a missing port all return `{ error }`, which the caller turns
 * into an `error` result so the rest of the batch still proceeds.
 *
 * Defense-in-depth: the name lookup reads `listCategories(op.budget_id)` — which
 * runs BEFORE the executor's guardrail — so when `activeBudgetId` is known we
 * refuse the read for an op targeting any other budget. The mutation stays
 * fail-closed at the guardrail regardless; this stops even a cross-budget READ.
 * @param {object} op
 * @param {{listCategories?: Function, activeBudgetId?: string}} ctx
 * @returns {Promise<{category_id: string, category_name: string|null}|{error: string}>}
 */
async function resolveCategory(op, { listCategories, activeBudgetId }) {
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
  // Defense-in-depth: never issue even a READ against a budget other than the
  // active one (the name lookup runs ahead of the executor's guardrail).
  if (typeof activeBudgetId === 'string' && activeBudgetId.length > 0 && op.budget_id !== activeBudgetId) {
    return { error: `categorize op ${op.id}: op.budget_id "${op.budget_id}" is not the active budget — refusing a cross-budget category lookup.` };
  }

  let categories;
  try {
    categories = await listCategories(op.budget_id);
  } catch (err) {
    return { error: `categorize op ${op.id}: category lookup failed: ${errMessage(err)}` };
  }
  const matches = (Array.isArray(categories) ? categories : [])
    .filter((c) => c && c.name === name && typeof c.id === 'string' && c.id.length > 0);
  if (matches.length === 0) {
    return { error: `categorize op ${op.id}: category name "${name}" did not resolve to an id.` };
  }
  if (matches.length > 1) {
    return { error: `categorize op ${op.id}: category name "${name}" is ambiguous — it matches ${matches.length} categories; the M4-10 proposal must pre-resolve the category_id.` };
  }
  return { category_id: matches[0].id, category_name: name };
}

/**
 * A copy of `op` with `after.category_id` set to the resolved id (and
 * `after.category_name` set when resolved to a non-empty string, else omitted — the
 * schema's `after.category_name` is a plain string, never null). Used only when the
 * name path resolved an id that the op did not already carry; the common (already
 * resolved) path passes the original op through untouched.
 */
function enrichAfter(op, resolved) {
  const after = { ...op.after, category_id: resolved.category_id };
  if (typeof resolved.category_name === 'string' && resolved.category_name.length > 0) {
    after.category_name = resolved.category_name;
  } else {
    delete after.category_name;
  }
  return { ...op, after };
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
 * The executor `bulkFits` predicate for categorize: a group of same-type survivors
 * may go through ONE bulk call when there are ≥2 of them and each forms a
 * `{ id, category_id }` entry (a real transaction_id + a resolved category_id). A
 * single op has no batching benefit. No budget check is needed — the executor's
 * guardrail already fails every op whose `budget_id` ≠ the active budget, so all
 * survivors share one budget.
 * @param {object[]} ops
 * @returns {boolean}
 */
function categorizeBulkFits(ops) {
  if (!Array.isArray(ops) || ops.length < 2) return false;
  return ops.every((op) =>
    op && typeof op.transaction_id === 'string' && op.transaction_id.length > 0 &&
    op.after && typeof op.after.category_id === 'string' && op.after.category_id.length > 0);
}

/**
 * Build the executor's per-op `applyOp(toolName, op)` port for categorize: a
 * field-isolated single-transaction update, boot-patient (reloads deferred schemas
 * on an InputValidationError before retrying).
 * @param {{callTool: Function, reloadSchemas?: Function, sleep?: Function, retries?: number, delayMs?: number}} deps
 */
function makeCategorizeApplyOp({ callTool, reloadSchemas, sleep, retries, delayMs }) {
  return (toolName, op) => withBootPatience(
    () => callTool(toolName, buildSingleUpdate(op, op.after.category_id)),
    { onRetry: reloadSchemas, sleep, retries, delayMs },
  );
}

/**
 * Build the executor's `bulkApplyOp(toolName, ops)` port for categorize: ONE bulk
 * `ynab_update_transactions` call carrying field-isolated `{ id, category_id }`
 * entries for the whole group, boot-patient. A throw here makes the executor fall
 * back to per-op `applyOp` calls (safe — categorize is idempotent).
 * @param {{callTool: Function, reloadSchemas?: Function, sleep?: Function, retries?: number, delayMs?: number}} deps
 */
function makeCategorizeBulkApplyOp({ callTool, reloadSchemas, sleep, retries, delayMs }) {
  return (toolName, ops) => {
    const payload = {
      budget_id: ops[0].budget_id,
      transactions: ops.map((op) => buildBulkEntry(op, op.after.category_id)),
    };
    return withBootPatience(() => callTool(toolName, payload), { onRetry: reloadSchemas, sleep, retries, delayMs });
  };
}

/** Build a resolution-phase per-op result in the categorize contract (AC8). */
function catResult(op, status, dryRun, detail) {
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
 * Map an executor result (`{ op_id, status, dry_run, detail }`) into the categorize
 * contract, extended with the `transaction_id` / `before` / `after` the M4-5 command
 * renders (AC8). `op` is the (enriched) op the executor processed.
 */
function toCategorizeResult(r, op) {
  return {
    op_id: r.op_id,
    transaction_id: (op && op.transaction_id) == null ? null : op.transaction_id,
    status: r.status,
    dry_run: r.dry_run,
    before: (op && op.before) == null ? null : op.before,
    after: (op && op.after) == null ? null : op.after,
    detail: r.detail,
  };
}

/**
 * Apply a change-set's `categorize` ops by ROUTING THROUGH THE M4-4 executor.
 * Dry-run by default — real apply requires an explicit `dryRun: false` (the M4-5
 * approval command sets it only after the human approves). Category ids are resolved
 * up front (a read-only prep step); every op then flows through the executor, which
 * drift-checks, guardrails, dispatches (one bulk `ynab_update_transactions` call for
 * a resolvable ≥2-op group, else per-transaction, with per-op fallback on a bulk
 * rejection), and audits it.
 *
 * @param {object} changeset the change-set envelope (assets/changeset-schema.json).
 * @param {object} [ctx]
 * @param {string} ctx.activeBudgetId MANDATORY in BOTH modes — throws when missing/empty.
 *   Category resolution runs a cross-budget read guard in dry-run too, and the executor
 *   fails closed without it, so it is validated up front (before any resolution read),
 *   not just on real apply.
 * @param {boolean} [ctx.dryRun=true] real apply requires an explicit `false`.
 * @param {(toolName: string, payload: object) => (unknown|Promise<unknown>)} [ctx.callTool]
 *   REQUIRED for real apply — the mutating MCP dispatch.
 * @param {(budgetId: string) => (Array|Promise<Array>)} [ctx.listCategories] read-only port for
 *   name→id resolution; only needed when an op's `after.category_id` is absent.
 * @param {(names: string[]) => (unknown|Promise<unknown>)} [ctx.toolSearch] ToolSearch select
 *   port to load deferred schemas before the first MCP call.
 * @param {(op: object) => (object|Promise<object>)} [ctx.readLiveState] REQUIRED — drift-detection read.
 * @param {(record: object) => (void|Promise<void>)} [ctx.audit] REQUIRED — the M4-3 audit sink.
 * @param {Function} [ctx.sleep] @param {number} [ctx.retries] @param {number} [ctx.delayMs]
 *   boot-patience knobs.
 * @returns {Promise<{ok:boolean, dry_run:boolean, aborted:boolean, reason:string,
 *   results:Array<{op_id:string|null, transaction_id:string|null, status:string,
 *   dry_run:boolean, before:object|null, after:object|null, detail:object}>}>}
 */
async function applyCategorize(changeset, ctx = {}) {
  const {
    activeBudgetId, dryRun = true, callTool, listCategories, toolSearch,
    readLiveState, authPreflight, audit, sleep, retries, delayMs,
  } = ctx;
  const patience = { sleep, retries, delayMs };

  if (!dryRun && typeof callTool !== 'function') {
    throw new TypeError('applyCategorize real apply (dryRun: false) requires a callTool(toolName, payload) function');
  }

  const operations = Array.isArray(changeset && changeset.operations) ? changeset.operations : [];

  // A valid change-set requires >=1 operation (schema `minItems`). An empty / non-array
  // `operations` envelope (`null` / `{}` / `{operations: []}` / a non-array) is
  // MALFORMED — fail CLOSED with `schema_invalid` up front (a structured outcome M4-5
  // renders, matching the executor's own shape), before the activeBudgetId guard and
  // any resolution read, so garbage input never reports a fail-open "success".
  if (operations.length === 0) {
    return { ok: false, dry_run: dryRun, aborted: true, reason: OUTCOME.SCHEMA_INVALID, validation: validateChangeset(changeset), results: [] };
  }

  // activeBudgetId is MANDATORY in BOTH modes — validate it BEFORE any resolution read.
  // Category resolution runs ahead of the executor and, when a name-only op needs a
  // lookup, issues `listCategories(op.budget_id)`; its cross-budget guard no-ops
  // without a known active budget. Absent this check, a name-only op could fire a real
  // READ against a proposal-controlled budget_id before the executor's own
  // activeBudgetId assertion ever runs. Fail closed here so no cross-budget read can
  // precede the guard (the executor asserts the same, but only after resolution).
  if (typeof activeBudgetId !== 'string' || activeBudgetId.length === 0) {
    throw new TypeError('applyCategorize requires a non-empty activeBudgetId — the cross-budget read guard and the executor both fail closed without it');
  }

  // Load the deferred tool schemas before the FIRST MCP call, in any mode (AC7).
  const reloadSchemas = () => loadSchemas({ toolSearch, ...patience });
  await reloadSchemas();

  // Category resolution — a READ-ONLY prep step BEFORE the executor (module doc).
  const listCategoriesPatient = typeof listCategories === 'function'
    ? (budgetId) => withBootPatience(() => listCategories(budgetId), { onRetry: reloadSchemas, ...patience })
    : undefined;

  const merged = new Array(operations.length);
  const toRun = []; // { index, op } — ops handed to the executor, in original order
  for (let i = 0; i < operations.length; i += 1) {
    const op = operations[i];
    // SINGLE-TYPE CONTRACT. This handler is the SOLE handler for `categorize` ops
    // (AC1); M4-5 routes each op to the handler whose op_type matches (the sibling
    // reconcile/allocate handlers assume the same). A foreign-type op must NEVER be
    // forwarded into the batch: it has no categorize tool, so the executor's
    // real-apply tool pre-flight would find no tool for it, block, and ABORT the
    // whole batch — reporting the perfectly valid categorize ops as blocked. Instead
    // give the mis-routed op its own terminal per-op `error` result and keep it out
    // of the executor batch, so it can't poison the valid ops.
    if (!op || op.type !== CATEGORIZE_TYPE) {
      const seen = op ? JSON.stringify(op.type) : 'a null/undefined op';
      merged[i] = catResult(op, STATUS.ERROR, dryRun, {
        phase: 'routing',
        message: `categorize handler received a non-categorize op (type: ${seen}) — this handler only processes "${CATEGORIZE_TYPE}" ops; M4-5 must route each op to its own-type handler.`,
      });
      continue;
    }
    const resolved = await resolveCategory(op, { listCategories: listCategoriesPatient, activeBudgetId });
    if (resolved.error) {
      merged[i] = catResult(op, STATUS.ERROR, dryRun, { phase: 'resolve', message: resolved.error });
      continue;
    }
    const alreadyResolved = op.after && typeof op.after.category_id === 'string' && op.after.category_id.length > 0;
    toRun.push({ index: i, op: alreadyResolved ? op : enrichAfter(op, resolved) });
  }

  // Nothing reached the executor, yet the envelope carried operations (an empty /
  // malformed envelope already returned `schema_invalid` up top). So every op was
  // either a mis-routed foreign-type op or a categorize op that errored in resolution
  // (e.g. an unresolvable name). Both are per-op errors, not a batch abort (mirroring
  // the executor's per-op error semantics), so the batch still "completes" with those
  // error results already in `merged`.
  if (toRun.length === 0) {
    return {
      ok: true,
      dry_run: dryRun,
      aborted: false,
      reason: dryRun ? OUTCOME.DRY_RUN_COMPLETE : OUTCOME.APPLY_COMPLETE,
      results: merged,
    };
  }

  const outcome = await applyChangeset(
    { ...changeset, operations: toRun.map(({ op }) => op) },
    {
      activeBudgetId,
      dryRun,
      toolMap: categorizeToolMap(),
      bulkToolMap: categorizeBulkToolMap(),
      bulkFits: categorizeBulkFits,
      applyOp: makeCategorizeApplyOp({ callTool, reloadSchemas, ...patience }),
      bulkApplyOp: makeCategorizeBulkApplyOp({ callTool, reloadSchemas, ...patience }),
      readLiveState,
      authPreflight,
      audit,
    },
  );

  // Map each executor per-op result back to its original slot in the categorize
  // contract. On a normal run and on the guardrail-block / tool-block aborts the
  // executor returns one result per run op (a BLOCKED per op). A `schema_invalid`
  // abort returns `results: []` (no per-op results, nothing audited) — fill those
  // run slots with a per-op schema error so the abort is surfaced WITHOUT
  // discarding the resolve-phase error slots already computed in `merged`. Either
  // way every op the caller handed us gets exactly one result (AC8), and the
  // top-level outcome (`ok` / `aborted` / `reason`) is preserved from the executor.
  if (outcome.results.length === toRun.length) {
    outcome.results.forEach((r, k) => { merged[toRun[k].index] = toCategorizeResult(r, toRun[k].op); });
  } else {
    for (const { index, op } of toRun) {
      merged[index] = catResult(op, STATUS.ERROR, dryRun, { phase: 'schema', reason: outcome.reason, validation: outcome.validation });
    }
  }
  return { ...outcome, results: merged };
}

module.exports = {
  CATEGORIZE_TYPE,
  TOOL_FAMILY_GLOB,
  resolveTools,
  categorizeToolMap,
  categorizeBulkToolMap,
  categorizeBulkFits,
  isInputValidationError,
  withBootPatience,
  loadSchemas,
  resolveCategory,
  enrichAfter,
  buildSingleUpdate,
  buildBulkEntry,
  makeCategorizeApplyOp,
  makeCategorizeBulkApplyOp,
  applyCategorize,
};
