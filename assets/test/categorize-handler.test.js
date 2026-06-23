'use strict';

/**
 * Unit tests for the M4-6 categorize / recategorize write path.
 *
 * Run with Node's built-in test runner. The handler requires the M4-4 executor
 * (which requires the Ajv-backed validator), so install the assets deps first:
 *   npm --prefix assets install
 *   npm --prefix assets test          # node --test
 *
 * The injected ports (callTool / listCategories / toolSearch / sleep) are mocked
 * as spies, and tool names are taken from the guardrail's exported ALLOWED_TOOLS —
 * never typed as literals here — so this file holds no hard-coded namespaced tool
 * name (issue #87 guard).
 */

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  categorizeToolMap,
  resolveTools,
  buildSingleUpdate,
  buildBulkEntry,
  buildDiff,
  bulkFits,
  applyCategorize,
  TOOL_FAMILY_GLOB,
} = require('../categorize-handler');
const { ALLOWED_TOOLS } = require('../write-safety-guardrail');
const { STATUS } = require('../apply-executor');

// Resolve the namespaced tools from the guardrail allow-list by suffix, so no
// literal `mcp__plugin_workbench-ynab_ynab__*` string lives in this file.
const SINGLE_TOOL = ALLOWED_TOOLS.find((t) => t.endsWith('_update_transaction'));
const BULK_TOOL = ALLOWED_TOOLS.find((t) => t.endsWith('_update_transactions'));
const NAMESPACE_PREFIX = 'mcp__plugin_workbench-ynab_ynab__'; // bare prefix — safe to mention
const BARE_PREFIX = 'mcp__ynab__'; // the forbidden un-namespaced form (AC10)

const BUDGET = 'b1f2c3d4-1111-4a2b-9c3d-000000000001';

/** A spy that records its calls and returns a (optionally per-call) value. */
function spy(impl) {
  const calls = [];
  const fn = async (...args) => {
    calls.push(args);
    return impl ? impl(...args) : undefined;
  };
  fn.calls = calls;
  return fn;
}

/** A no-op sleep spy, so boot-patience retries never actually wait. */
const noWait = () => spy(() => undefined);

/** Build a categorize op; override any field. */
function op(overrides = {}) {
  return {
    id: 'op-categorize-0001',
    type: 'categorize',
    budget_id: BUDGET,
    transaction_id: 't0000000-0000-4000-8000-00000000a001',
    before: { category_id: null, category_name: null },
    after: { category_id: 'c0000000-0000-4000-8000-0000000000c1', category_name: 'Groceries' },
    rationale: 'Whole Foods purchase matches Groceries by payee history.',
    risk: 'low',
    ...overrides,
  };
}

// --- registration point ----------------------------------------------------

test('categorizeToolMap registers the single update tool, resolved from the allow-list (not hard-coded)', () => {
  const map = categorizeToolMap();
  assert.equal(map.categorize, SINGLE_TOOL);
  assert.equal(resolveTools().bulk, BULK_TOOL);
  // Namespaced, never the bare un-namespaced form (AC10).
  assert.ok(map.categorize.startsWith(NAMESPACE_PREFIX));
  assert.ok(!map.categorize.startsWith(BARE_PREFIX));
});

// --- (g) field isolation ----------------------------------------------------

test('(g) the single-transaction payload carries ONLY category_id — never payee/amount/account/transfer', async () => {
  // before/after deliberately carry non-category fields the handler must ignore.
  const dirty = op({
    before: { category_id: 'c-old', category_name: 'Dining', payee_name: 'Whole Foods', amount: -54990 },
    after: { category_id: 'c-new', category_name: 'Groceries', payee_id: 'p-evil', amount: -54990, account_id: 'a-1' },
  });
  const callTool = spy(() => ({ ok: true }));
  const out = await applyCategorize([dirty], { dryRun: false, callTool, sleep: noWait() });

  assert.equal(out[0].status, STATUS.APPLIED);
  const [toolName, payload] = callTool.calls[0];
  assert.equal(toolName, SINGLE_TOOL);
  // Exactly the addressing keys + the single category field — nothing else.
  assert.deepEqual(Object.keys(payload).sort(), ['budget_id', 'category_id', 'transaction_id']);
  assert.equal(payload.category_id, 'c-new');
  for (const forbidden of ['payee_id', 'payee_name', 'account_id', 'amount', 'date', 'transfer_account_id']) {
    assert.ok(!(forbidden in payload), `payload must not carry ${forbidden}`);
  }
});

test('buildSingleUpdate and buildBulkEntry are field-isolated to the category', () => {
  const o = op();
  assert.deepEqual(buildSingleUpdate(o, 'c-x'), {
    budget_id: BUDGET, transaction_id: o.transaction_id, category_id: 'c-x',
  });
  assert.deepEqual(buildBulkEntry(o, 'c-x'), { id: o.transaction_id, category_id: 'c-x' });
});

// --- (a) single-txn first-time categorization -------------------------------

test('(a) single-txn first-time categorization applies via the single tool', async () => {
  const firstTime = op({ before: { category_id: null, category_name: null } });
  const callTool = spy(() => ({ ok: true }));
  const out = await applyCategorize([firstTime], { dryRun: false, callTool, sleep: noWait() });

  assert.equal(out.length, 1);
  assert.equal(out[0].status, STATUS.APPLIED);
  assert.equal(out[0].dry_run, false);
  assert.equal(out[0].transaction_id, firstTime.transaction_id);
  assert.equal(callTool.calls.length, 1);
  assert.equal(callTool.calls[0][0], SINGLE_TOOL);
  assert.equal(callTool.calls[0][1].category_id, firstTime.after.category_id);
});

// --- (b) single-txn recategorization ----------------------------------------

test('(b) single-txn recategorization flows through the SAME path (existing before.category_id)', async () => {
  const recat = op({ before: { category_id: 'c-old', category_name: 'Dining' } });
  const callTool = spy(() => ({ ok: true }));
  const out = await applyCategorize([recat], { dryRun: false, callTool, sleep: noWait() });

  assert.equal(out[0].status, STATUS.APPLIED);
  assert.equal(callTool.calls[0][0], SINGLE_TOOL);
  assert.equal(callTool.calls[0][1].category_id, recat.after.category_id);
});

// --- (c) multi-txn bulk path ------------------------------------------------

test('(c) multi-txn prefers a single bulk update_transactions call', async () => {
  const a = op({ id: 'op-1', transaction_id: 't-a', after: { category_id: 'c-a', category_name: 'A' } });
  const b = op({ id: 'op-2', transaction_id: 't-b', after: { category_id: 'c-b', category_name: 'B' } });
  const callTool = spy(() => ({ ok: true }));
  const out = await applyCategorize([a, b], { dryRun: false, callTool, sleep: noWait() });

  // Exactly one call, to the bulk tool, with field-isolated { id, category_id } entries.
  assert.equal(callTool.calls.length, 1);
  const [toolName, payload] = callTool.calls[0];
  assert.equal(toolName, BULK_TOOL);
  assert.equal(payload.budget_id, BUDGET);
  assert.deepEqual(payload.transactions, [
    { id: 't-a', category_id: 'c-a' },
    { id: 't-b', category_id: 'c-b' },
  ]);
  assert.equal(out.length, 2);
  for (const r of out) {
    assert.equal(r.status, STATUS.APPLIED);
    assert.equal(r.detail.bulk, true);
  }
  assert.ok(bulkFits([{ op: a, resolved: { category_id: 'c-a' } }, { op: b, resolved: { category_id: 'c-b' } }]));
});

// --- (d) multi-txn per-transaction fallback ---------------------------------

test('(d) when the bulk shape is rejected at runtime, it falls back to per-transaction calls', async () => {
  const a = op({ id: 'op-1', transaction_id: 't-a', after: { category_id: 'c-a', category_name: 'A' } });
  const b = op({ id: 'op-2', transaction_id: 't-b', after: { category_id: 'c-b', category_name: 'B' } });
  // The bulk tool rejects the category-only batch shape; single calls succeed.
  const callTool = spy((toolName) => {
    if (toolName === BULK_TOOL) throw new Error('unrecognized_request_field: each transaction requires amount/date');
    return { ok: true };
  });
  const out = await applyCategorize([a, b], { dryRun: false, callTool, sleep: noWait() });

  // One rejected bulk attempt, then one single call per op (the fallback).
  const bulkCalls = callTool.calls.filter(([t]) => t === BULK_TOOL);
  const singleCalls = callTool.calls.filter(([t]) => t === SINGLE_TOOL);
  assert.equal(bulkCalls.length, 1);
  assert.equal(singleCalls.length, 2);
  assert.equal(out.length, 2);
  for (const r of out) assert.equal(r.status, STATUS.APPLIED);
  // Field isolation holds on the fallback payloads too.
  for (const [, payload] of singleCalls) {
    assert.deepEqual(Object.keys(payload).sort(), ['budget_id', 'category_id', 'transaction_id']);
  }
});

test('a single resolvable op never uses the bulk tool (no batching benefit)', async () => {
  const callTool = spy(() => ({ ok: true }));
  await applyCategorize([op()], { dryRun: false, callTool, sleep: noWait() });
  assert.equal(callTool.calls.length, 1);
  assert.equal(callTool.calls[0][0], SINGLE_TOOL);
});

// --- (e) dry-run diff output ------------------------------------------------

test('(e) dry-run produces a before→after category diff and calls NO mutating tool', async () => {
  const callTool = spy();
  const out = await applyCategorize([op()], { callTool }); // dryRun omitted → default true

  assert.equal(callTool.calls.length, 0);
  assert.equal(out[0].status, STATUS.APPLIED);
  assert.equal(out[0].dry_run, true);
  assert.equal(out[0].detail.simulated, true);
  const { diff } = out[0].detail;
  assert.deepEqual(diff.before, { category_id: null, category_name: null });
  assert.deepEqual(diff.after, { category_id: 'c0000000-0000-4000-8000-0000000000c1', category_name: 'Groceries' });
});

test('(AC9) recat vs first-time share the code path; ONLY the dry-run narrative differs', () => {
  const resolved = { category_id: 'c-new', category_name: 'Groceries' };
  const first = buildDiff(op({ before: { category_id: null, category_name: null } }), resolved);
  const recat = buildDiff(op({ before: { category_id: 'c-old', category_name: 'Dining' } }), resolved);
  assert.match(first.narrative, /^categorize uncategorized transaction as Groceries$/);
  assert.match(recat.narrative, /^recategorize from Dining to Groceries$/);
  // The structural diff shape is identical — only the narrative string differs.
  assert.deepEqual(Object.keys(first).sort(), Object.keys(recat).sort());
});

// --- (f) category-name-to-id resolution -------------------------------------

test('(f) a name-only after is resolved to a category_id via the listCategories port', async () => {
  const nameOnly = op({ after: { category_name: 'Groceries' } }); // no category_id
  const listCategories = spy(() => [
    { id: 'c-dining', name: 'Dining Out' },
    { id: 'c-groceries', name: 'Groceries' },
  ]);
  const callTool = spy(() => ({ ok: true }));
  const out = await applyCategorize([nameOnly], { dryRun: false, callTool, listCategories, sleep: noWait() });

  assert.equal(listCategories.calls[0][0], BUDGET); // looked up against the op's budget
  assert.equal(out[0].status, STATUS.APPLIED);
  assert.equal(callTool.calls[0][1].category_id, 'c-groceries');
});

// --- (h) unresolvable category name returns an error result -----------------

test('(h) an unresolvable category name returns an `error` result (no throw, no dispatch, batch proceeds)', async () => {
  const good = op({ id: 'op-good', transaction_id: 't-good', after: { category_id: 'c-ok', category_name: 'OK' } });
  const bad = op({ id: 'op-bad', transaction_id: 't-bad', after: { category_name: 'Nonexistent' } });
  const listCategories = spy(() => [{ id: 'c-ok', name: 'OK' }]); // 'Nonexistent' has no match
  const callTool = spy(() => ({ ok: true }));
  const out = await applyCategorize([good, bad], { dryRun: false, callTool, listCategories, sleep: noWait() });

  const byId = Object.fromEntries(out.map((r) => [r.op_id, r]));
  assert.equal(byId['op-bad'].status, STATUS.ERROR);
  assert.match(byId['op-bad'].detail.message, /did not resolve to an id/);
  // The clean op still applied — the bad one was never dispatched.
  assert.equal(byId['op-good'].status, STATUS.APPLIED);
  assert.ok(!callTool.calls.some(([, p]) => p && p.transaction_id === 't-bad'));
  assert.ok(!callTool.calls.some(([, p]) => Array.isArray(p.transactions) && p.transactions.some((e) => e.id === 't-bad')));
});

// --- deferred-schema loading (AC7) ------------------------------------------

test('(AC7) ToolSearch select runs before the first MCP call, with the resolved tools + family glob', async () => {
  const calls = [];
  const toolSearch = spy((names) => { calls.push(['search', names]); });
  const callTool = spy((toolName) => { calls.push(['call', toolName]); return { ok: true }; });
  await applyCategorize([op()], { dryRun: false, callTool, toolSearch, sleep: noWait() });

  assert.equal(calls[0][0], 'search'); // schema load happens first
  assert.equal(calls[1][0], 'call');
  const names = toolSearch.calls[0][0];
  assert.ok(names.includes(SINGLE_TOOL) && names.includes(BULK_TOOL) && names.includes(TOOL_FAMILY_GLOB));
});

test('(AC7) an InputValidationError on the MCP call is treated as an unloaded schema and retried (boot patience)', async () => {
  let attempts = 0;
  const callTool = spy(() => {
    attempts += 1;
    if (attempts === 1) {
      const e = new Error('schema not loaded');
      e.name = 'InputValidationError';
      throw e;
    }
    return { ok: true };
  });
  const sleep = noWait();
  const out = await applyCategorize([op()], { dryRun: false, callTool, sleep, retries: 3, delayMs: 1 });

  assert.equal(out[0].status, STATUS.APPLIED); // succeeded on the retry
  assert.equal(attempts, 2);
  assert.ok(sleep.calls.length >= 1); // boot-patience waited before retrying
});

// --- result contract + namespaced enforcement -------------------------------

test('(AC8/AC10) every result matches the contract and only namespaced tools are dispatched', async () => {
  const callTool = spy(() => ({ ok: true }));
  const out = await applyCategorize([op()], { dryRun: false, callTool, sleep: noWait() });
  const allowed = new Set(Object.values(STATUS));
  for (const r of out) {
    assert.deepEqual(Object.keys(r).sort(), ['after', 'before', 'detail', 'dry_run', 'op_id', 'status', 'transaction_id']);
    assert.ok(allowed.has(r.status));
    assert.equal(typeof r.dry_run, 'boolean');
  }
  for (const [toolName] of callTool.calls) {
    assert.ok(toolName.startsWith(NAMESPACE_PREFIX));
    assert.ok(!toolName.startsWith(BARE_PREFIX));
  }
});

test('real apply without a callTool port throws (fail-fast on a misconfigured caller)', async () => {
  await assert.rejects(() => applyCategorize([op()], { dryRun: false }), /callTool/);
});

test('a callTool failure becomes a per-op error and the rest of the batch still applies', async () => {
  const a = op({ id: 'op-1', transaction_id: 't-a', after: { category_id: 'c-a', category_name: 'A' } });
  const b = op({ id: 'op-2', transaction_id: 't-b', after: { category_id: 'c-b', category_name: 'B' } });
  // Force the per-transaction path (bulk rejected), then fail only t-a's single call.
  const callTool = spy((toolName, payload) => {
    if (toolName === BULK_TOOL) throw new Error('bulk shape rejected');
    if (payload.transaction_id === 't-a') throw new Error('YNAB 500');
    return { ok: true };
  });
  const out = await applyCategorize([a, b], { dryRun: false, callTool, sleep: noWait() });
  const byId = Object.fromEntries(out.map((r) => [r.op_id, r]));
  assert.equal(byId['op-1'].status, STATUS.ERROR);
  assert.equal(byId['op-1'].detail.message, 'YNAB 500');
  assert.equal(byId['op-2'].status, STATUS.APPLIED);
});
