'use strict';

/**
 * Unit tests for the M4-6 categorize / recategorize write path.
 *
 * Run with Node's built-in test runner. The handler requires the M4-4 executor
 * (which requires the Ajv-backed validator), so install the assets deps first:
 *   npm --prefix assets install
 *   npm --prefix assets test          # node --test
 *
 * The handler ROUTES THROUGH THE EXECUTOR (M4-6 Option 1), so every apply flows
 * through the real `applyChangeset` here — the executor is NOT mocked. That is what
 * proves bulk dispatch still inherits per-op drift detection, the guardrail, and the
 * audit trail. The injected ports (callTool / listCategories / toolSearch /
 * readLiveState / audit / sleep) are mocked as spies, and tool names are taken from
 * the guardrail's exported ALLOWED_TOOLS — never typed as literals — so this file
 * holds no hard-coded namespaced tool name (issue #87 guard).
 */

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  categorizeToolMap,
  categorizeBulkToolMap,
  categorizeBulkFits,
  resolveTools,
  resolveCategory,
  enrichAfter,
  buildSingleUpdate,
  buildBulkEntry,
  makeCategorizeApplyOp,
  makeCategorizeBulkApplyOp,
  applyCategorize,
  TOOL_FAMILY_GLOB,
} = require('../categorize-handler');
const { ALLOWED_TOOLS } = require('../write-safety-guardrail');
const { STATUS, OUTCOME, describeAuthFailure } = require('../apply-executor');
const { classifyError } = require('../write-error');

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

const clone = (x) => JSON.parse(JSON.stringify(x));
/** A no-op sleep spy, so boot-patience retries never actually wait. */
const noWait = () => spy(() => undefined);
/** readLiveState that echoes each op's own `before` snapshot → never stale. */
const noDrift = () => spy((op) => clone(op.before));
/** A no-op audit sink spy. */
const auditSpy = () => spy(() => undefined);

/**
 * The REAL confirmed `ynab_update_transactions` response for a bulk payload — the
 * vendored shape (`{ success, summary, results:[{ request_index, status,
 * transaction_id }] }`) with every entry `updated`, NOT an off-contract `{ ok: true }`
 * (which the executor now reads fail-closed as unconfirmed). Fed the bulk call's payload.
 */
const bulkUpdated = (payload) => ({
  success: true,
  summary: { updated: payload.transactions.length, failed: 0 },
  results: payload.transactions.map((t, i) => ({ request_index: i, status: 'updated', transaction_id: t.id, correlation_key: `k${i}` })),
});

/** A callTool spy: BULK calls resolve the confirmed vendored shape; single calls resolve ok. */
const bulkAwareCallTool = () => spy((toolName, payload) => (
  toolName === BULK_TOOL && payload && Array.isArray(payload.transactions)
    ? bulkUpdated(payload)
    : { ok: true }
));

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

/** Wrap ops in a schema-valid change-set envelope. */
function changeset(ops, over = {}) {
  return {
    schema_version: '1.0.0',
    generated_at: '2026-06-19T14:30:00Z',
    budget_id: BUDGET,
    budget_name: 'Family Budget',
    source: 'review-2026-06-19T14-00-00Z',
    money_movement: false,
    operations: ops,
    ...over,
  };
}

/** Default ctx: the executor's mandatory ports wired to spies + a no-wait sleep. */
function baseCtx(over = {}) {
  return { activeBudgetId: BUDGET, readLiveState: noDrift(), authPreflight: spy(async () => ({ budgets: [] })), audit: auditSpy(), sleep: noWait(), ...over };
}

// --- registration point ----------------------------------------------------

test('categorizeToolMap / categorizeBulkToolMap register the tools, resolved from the allow-list (not hard-coded)', () => {
  assert.equal(categorizeToolMap().categorize, SINGLE_TOOL);
  assert.equal(categorizeBulkToolMap().categorize, BULK_TOOL);
  assert.equal(resolveTools().bulk, BULK_TOOL);
  // Namespaced, never the bare un-namespaced form (AC10).
  for (const t of [categorizeToolMap().categorize, categorizeBulkToolMap().categorize]) {
    assert.ok(t.startsWith(NAMESPACE_PREFIX));
    assert.ok(!t.startsWith(BARE_PREFIX));
  }
});

test('categorizeBulkFits: ≥2 ops each forming an { id, category_id } entry → bulk; else per-op', () => {
  const a = op({ id: 'op-1', transaction_id: 't-a' });
  const b = op({ id: 'op-2', transaction_id: 't-b' });
  assert.equal(categorizeBulkFits([a, b]), true);
  assert.equal(categorizeBulkFits([a]), false); // single op — no batching benefit
  assert.equal(categorizeBulkFits([a, op({ transaction_id: '' })]), false); // no transaction_id
  assert.equal(categorizeBulkFits([a, op({ after: {} })]), false); // no resolved category_id
});

// --- (g) field isolation (at the dispatch boundary) -------------------------

test('(g) buildSingleUpdate / buildBulkEntry are field-isolated to the category — never payee/amount/account/transfer', () => {
  // A "dirty" op whose before/after carry non-category fields the builders must ignore.
  const dirty = op({
    before: { category_id: 'c-old', category_name: 'Dining', payee_name: 'Whole Foods', amount: -54990 },
    after: { category_id: 'c-new', category_name: 'Groceries', payee_id: 'p-evil', amount: -54990, account_id: 'a-1' },
  });
  assert.deepEqual(buildSingleUpdate(dirty, 'c-new'), {
    budget_id: BUDGET, transaction_id: dirty.transaction_id, category_id: 'c-new',
  });
  assert.deepEqual(buildBulkEntry(dirty, 'c-new'), { id: dirty.transaction_id, category_id: 'c-new' });
});

test('(g) the per-op applyOp dispatch payload carries ONLY category_id + addressing keys', async () => {
  const dirty = op({ after: { category_id: 'c-new', category_name: 'Groceries', payee_id: 'p-evil', amount: -54990, account_id: 'a-1' } });
  const callTool = spy(() => ({ ok: true }));
  const applyOp = makeCategorizeApplyOp({ callTool });
  await applyOp(SINGLE_TOOL, dirty);

  const [toolName, payload] = callTool.calls[0];
  assert.equal(toolName, SINGLE_TOOL);
  assert.deepEqual(Object.keys(payload).sort(), ['budget_id', 'category_id', 'transaction_id']);
  assert.equal(payload.category_id, 'c-new');
  for (const forbidden of ['payee_id', 'payee_name', 'account_id', 'amount', 'date', 'transfer_account_id']) {
    assert.ok(!(forbidden in payload), `payload must not carry ${forbidden}`);
  }
});

test('(g) the BULK bulkApplyOp dispatch payload carries ONLY { id, category_id } entries — dirty fields never leak', async () => {
  // Two "dirty" ops whose before/after carry non-category fields; drive them through
  // the REAL bulk dispatch port and assert every entry is field-isolated end-to-end.
  const dirtyA = op({ id: 'op-1', transaction_id: 't-a', before: { category_id: 'c-old', payee_name: 'Whole Foods', amount: -54990 }, after: { category_id: 'c-a', category_name: 'A', payee_id: 'p-evil', amount: -54990, account_id: 'acct-1' } });
  const dirtyB = op({ id: 'op-2', transaction_id: 't-b', before: { category_id: null }, after: { category_id: 'c-b', category_name: 'B', transfer_account_id: 'x', date: '2026-06-01' } });
  const callTool = bulkAwareCallTool();
  const bulkApplyOp = makeCategorizeBulkApplyOp({ callTool });
  await bulkApplyOp(BULK_TOOL, [dirtyA, dirtyB]);

  const [toolName, payload] = callTool.calls[0];
  assert.equal(toolName, BULK_TOOL);
  assert.deepEqual(Object.keys(payload).sort(), ['budget_id', 'transactions']);
  assert.deepEqual(payload.transactions, [
    { id: 't-a', category_id: 'c-a' },
    { id: 't-b', category_id: 'c-b' },
  ]);
  for (const entry of payload.transactions) {
    assert.deepEqual(Object.keys(entry).sort(), ['category_id', 'id']);
    for (const forbidden of ['payee_id', 'payee_name', 'account_id', 'amount', 'date', 'transfer_account_id']) {
      assert.ok(!(forbidden in entry), `bulk entry must not carry ${forbidden}`);
    }
  }
});

// --- (#50) port wrappers throw on a resolved { isError: true } envelope -----

/** The vendored MCP's error shape: a RESOLVED { isError: true } result, NOT a throw. */
const isErrorEnvelope = (status, message) => ({
  isError: true,
  content: [{ type: 'text', text: `{"error":{"message":"${message} (HTTP ${status})"}}` }],
});

test('makeCategorizeApplyOp THROWS on a resolved { isError: true } envelope (fail-closed, classifiable)', async () => {
  // The vendored MCP surfaces a 401 as a resolved { isError: true } result, not a
  // rejected promise. The wrapper must convert it to a throw so the executor's
  // auth-abort machinery (which only runs in a catch) engages — else it fails OPEN.
  const applyOp = makeCategorizeApplyOp({ callTool: spy(async () => isErrorEnvelope(401, 'token revoked')), sleep: noWait() });
  await assert.rejects(() => applyOp(SINGLE_TOOL, op()), (err) => {
    assert.equal(classifyError(err).error_class, 'auth_revoked'); // the status survives → classifiable
    return true;
  });
});

test('makeCategorizeBulkApplyOp THROWS on a resolved { isError: true } envelope (fail-closed, classifiable)', async () => {
  const bulkApplyOp = makeCategorizeBulkApplyOp({ callTool: spy(async () => isErrorEnvelope(403, 'insufficient scope')), sleep: noWait() });
  const ops = [op({ id: 'op-1', transaction_id: 't-a' }), op({ id: 'op-2', transaction_id: 't-b' })];
  await assert.rejects(() => bulkApplyOp(BULK_TOOL, ops), (err) => {
    assert.equal(classifyError(err).error_class, 'insufficient_scope');
    return true;
  });
});

test('a resolved { isError: true } auth envelope from callTool ABORTS the batch (no fail-open) — bulk path', async () => {
  // End-to-end proof the money path fails CLOSED: two resolvable ops → bulk dispatch;
  // callTool resolves an { isError: true } 401 for every call. The bulk wrapper throws,
  // the executor falls back to per-op (also throws), classifies auth_revoked, and aborts
  // — nothing is recorded applied. Before the wrappers threw, this 401 flowed in as a
  // payload and the batch fell OPEN.
  const callTool = spy(async () => isErrorEnvelope(401, 'token revoked'));
  const audit = auditSpy();
  const cs = changeset([
    op({ id: 'op-1', transaction_id: 't-a', after: { category_id: 'c-a', category_name: 'A' } }),
    op({ id: 'op-2', transaction_id: 't-b', after: { category_id: 'c-b', category_name: 'B' } }),
  ]);
  const out = await applyCategorize(cs, baseCtx({ dryRun: false, callTool, audit }));

  assert.equal(out.ok, false);
  assert.equal(out.reason, OUTCOME.AUTH_ABORT);
  assert.ok(!out.results.some((r) => r.status === STATUS.APPLIED)); // nothing applied — fail-closed
});

// --- (#50) a mid-batch auth abort preserves the applied ops (AC#6 / AC#7) ---

test('a mid-batch auth abort PRESERVES the ops that applied — not clobbered as errors (#50 AC#6/#7)', async () => {
  // op-1 applies, op-2 hits a 401, op-3 never runs. The returned results MUST keep op-1
  // APPLIED (the old length-based remap rewrote the whole batch to schema errors), so
  // describeAuthFailure renders "1 of 3 applied, stopped at op 2" — not "No changes
  // applied." The durable audit log was already correct; this fixes the caller's results.
  const httpError = (s, m) => Object.assign(new Error(m || `HTTP ${s}`), { status: s });
  const hasTb = (payload) => payload.transaction_id === 't-b'
    || (Array.isArray(payload.transactions) && payload.transactions.some((t) => t.id === 't-b'));
  // The bulk call (which carries t-b) 401s → per-op fallback: t-a applies, t-b 401s → abort.
  const callTool = spy(async (_tool, payload) => {
    if (hasTb(payload)) throw httpError(401, 'unauthorized');
    return { ok: true };
  });
  const cs = changeset([
    op({ id: 'op-1', transaction_id: 't-a', after: { category_id: 'c-a', category_name: 'A' } }),
    op({ id: 'op-2', transaction_id: 't-b', after: { category_id: 'c-b', category_name: 'B' } }),
    op({ id: 'op-3', transaction_id: 't-c', after: { category_id: 'c-c', category_name: 'C' } }),
  ]);
  const out = await applyCategorize(cs, baseCtx({ dryRun: false, callTool }));

  assert.equal(out.reason, OUTCOME.AUTH_ABORT);
  const byId = Object.fromEntries(out.results.map((r) => [r.op_id, r]));
  assert.equal(byId['op-1'].status, STATUS.APPLIED); // ← regression guard: was clobbered to error/schema
  assert.equal(byId['op-2'].status, STATUS.ERROR);
  assert.equal(byId['op-2'].detail.error_class, 'auth_revoked');
  assert.equal(byId['op-3'].status, STATUS.ERROR); // un-run tail → not-attempted
  // The M4-5 renderer's message distinguishes "N of M applied" from "No changes applied".
  assert.match(describeAuthFailure(out), /1 of 3 op\(s\) applied, batch stopped at op 2/);
});

// --- (a) single-txn first-time categorization -------------------------------

test('(a) single-txn first-time categorization applies via the single tool', async () => {
  const firstTime = op({ before: { category_id: null, category_name: null } });
  const callTool = spy(() => ({ ok: true }));
  const out = await applyCategorize(changeset([firstTime]), baseCtx({ dryRun: false, callTool }));

  assert.equal(out.results.length, 1);
  assert.equal(out.results[0].status, STATUS.APPLIED);
  assert.equal(out.results[0].dry_run, false);
  assert.equal(out.results[0].transaction_id, firstTime.transaction_id);
  assert.equal(callTool.calls.length, 1);
  assert.equal(callTool.calls[0][0], SINGLE_TOOL);
  assert.equal(callTool.calls[0][1].category_id, firstTime.after.category_id);
});

// --- (b) single-txn recategorization ----------------------------------------

test('(b) single-txn recategorization flows through the SAME path (existing before.category_id)', async () => {
  const recat = op({ before: { category_id: 'c-old', category_name: 'Dining' } });
  const callTool = spy(() => ({ ok: true }));
  // Live state must still match the op's before snapshot, or drift detection skips it.
  const readLiveState = spy(() => ({ category_id: 'c-old', category_name: 'Dining' }));
  const out = await applyCategorize(changeset([recat]), baseCtx({ dryRun: false, callTool, readLiveState }));

  assert.equal(out.results[0].status, STATUS.APPLIED);
  assert.equal(callTool.calls[0][0], SINGLE_TOOL);
  assert.equal(callTool.calls[0][1].category_id, recat.after.category_id);
});

// --- (c) multi-txn bulk path — through the executor -------------------------

test('(c) multi-txn prefers a single bulk update_transactions call — and still drift-checks + audits each op', async () => {
  const a = op({ id: 'op-1', transaction_id: 't-a', after: { category_id: 'c-a', category_name: 'A' } });
  const b = op({ id: 'op-2', transaction_id: 't-b', after: { category_id: 'c-b', category_name: 'B' } });
  const callTool = bulkAwareCallTool(); // real confirmed per-entry bulk shape
  const readLiveState = noDrift();
  const audit = auditSpy();
  const out = await applyCategorize(changeset([a, b]), baseCtx({ dryRun: false, callTool, readLiveState, audit }));

  // Exactly one call, to the bulk tool, with field-isolated { id, category_id } entries.
  assert.equal(callTool.calls.length, 1);
  const [toolName, payload] = callTool.calls[0];
  assert.equal(toolName, BULK_TOOL);
  assert.equal(payload.budget_id, BUDGET);
  assert.deepEqual(payload.transactions, [
    { id: 't-a', category_id: 'c-a' },
    { id: 't-b', category_id: 'c-b' },
  ]);
  assert.equal(out.results.length, 2);
  for (const r of out.results) {
    assert.equal(r.status, STATUS.APPLIED);
    assert.equal(r.detail.bulk, true);
    assert.equal(r.detail.tool, BULK_TOOL);
  }
  // The bulk path went THROUGH the executor: every op got a live re-read (drift) + an audit record.
  assert.equal(readLiveState.calls.length, 2);
  assert.equal(audit.calls.length, 2);
});

// --- (d) multi-txn per-transaction fallback ---------------------------------

test('(d) when the bulk shape is rejected at runtime, the executor falls back to per-transaction calls', async () => {
  const a = op({ id: 'op-1', transaction_id: 't-a', after: { category_id: 'c-a', category_name: 'A' } });
  const b = op({ id: 'op-2', transaction_id: 't-b', after: { category_id: 'c-b', category_name: 'B' } });
  const callTool = spy((toolName) => {
    if (toolName === BULK_TOOL) throw new Error('unrecognized_request_field: each transaction requires amount/date');
    return { ok: true };
  });
  const out = await applyCategorize(changeset([a, b]), baseCtx({ dryRun: false, callTool }));

  const bulkCalls = callTool.calls.filter(([t]) => t === BULK_TOOL);
  const singleCalls = callTool.calls.filter(([t]) => t === SINGLE_TOOL);
  assert.equal(bulkCalls.length, 1); // one rejected bulk attempt
  assert.equal(singleCalls.length, 2); // then one single call per op (the fallback)
  assert.equal(out.results.length, 2);
  for (const r of out.results) assert.equal(r.status, STATUS.APPLIED);
  // Field isolation holds on the fallback payloads too.
  for (const [, payload] of singleCalls) {
    assert.deepEqual(Object.keys(payload).sort(), ['budget_id', 'category_id', 'transaction_id']);
  }
});

test('a single resolvable op never uses the bulk tool (no batching benefit)', async () => {
  const callTool = spy(() => ({ ok: true }));
  await applyCategorize(changeset([op()]), baseCtx({ dryRun: false, callTool }));
  assert.equal(callTool.calls.length, 1);
  assert.equal(callTool.calls[0][0], SINGLE_TOOL);
});

// --- executor integration: drift + guardrail now reach categorize -----------

test('drift on one op of a bulk batch skips it (skipped-stale) while the clean op applies — bulk path is drift-safe now', async () => {
  const a = op({ id: 'op-1', transaction_id: 't-a', before: { category_id: null, category_name: null }, after: { category_id: 'c-a', category_name: 'A' } });
  const b = op({ id: 'op-2', transaction_id: 't-b', before: { category_id: 'c-old', category_name: 'Dining' }, after: { category_id: 'c-b', category_name: 'B' } });
  // op-2's live state has drifted from its `before` snapshot since the change-set was made.
  const readLiveState = spy((o) => (o.id === 'op-2' ? { category_id: 'c-moved', category_name: 'Travel' } : clone(o.before)));
  const callTool = spy(() => ({ ok: true }));
  const out = await applyCategorize(changeset([a, b]), baseCtx({ dryRun: false, callTool, readLiveState }));

  const byId = Object.fromEntries(out.results.map((r) => [r.op_id, r]));
  assert.equal(byId['op-2'].status, STATUS.SKIPPED_STALE);
  assert.equal(byId['op-1'].status, STATUS.APPLIED);
  // Only one survivor → per-op single call for op-1; the stale op was never dispatched.
  assert.ok(!callTool.calls.some(([, p]) => p.transaction_id === 't-b'
    || (Array.isArray(p.transactions) && p.transactions.some((e) => e.id === 't-b'))));
});

test('a guardrail block (wrong active budget) aborts the whole batch — nothing dispatched (categorize is guardrailed now)', async () => {
  const callTool = spy(() => ({ ok: true }));
  const out = await applyCategorize(changeset([op(), op({ id: 'op-2', transaction_id: 't-b' })]), baseCtx({
    dryRun: false, callTool, activeBudgetId: 'a-different-active-budget',
  }));
  assert.equal(out.ok, false);
  assert.equal(out.aborted, true);
  assert.equal(out.reason, OUTCOME.GUARDRAIL_BLOCK);
  for (const r of out.results) assert.equal(r.status, STATUS.BLOCKED);
  assert.equal(callTool.calls.length, 0);
});

// --- (e) dry-run diff output ------------------------------------------------

test('(e) dry-run produces a before→after category diff and calls NO mutating tool', async () => {
  const callTool = spy();
  const out = await applyCategorize(changeset([op()]), baseCtx({ callTool })); // dryRun omitted → default true

  assert.equal(callTool.calls.length, 0);
  assert.equal(out.dry_run, true);
  assert.equal(out.results[0].status, STATUS.APPLIED);
  assert.equal(out.results[0].dry_run, true);
  assert.equal(out.results[0].detail.simulated, true);
  const { diff } = out.results[0].detail;
  assert.deepEqual(diff.before, { category_id: null, category_name: null });
  assert.deepEqual(diff.after, { category_id: 'c0000000-0000-4000-8000-0000000000c1', category_name: 'Groceries' });
});

test('(AC9) recat and first-time share ONE code path — the diff differs only in content, never in branch/shape', async () => {
  const first = op({ id: 'op-first', transaction_id: 't-1', before: { category_id: null, category_name: null } });
  const recat = op({ id: 'op-recat', transaction_id: 't-2', before: { category_id: 'c-old', category_name: 'Dining' } });
  const readLiveState = spy((o) => clone(o.before));
  const out = await applyCategorize(changeset([first, recat]), baseCtx({ readLiveState })); // dry-run
  const byId = Object.fromEntries(out.results.map((r) => [r.op_id, r]));
  // Identical result/diff structure; only the before content differs.
  assert.deepEqual(Object.keys(byId['op-first'].detail.diff).sort(), Object.keys(byId['op-recat'].detail.diff).sort());
  assert.equal(byId['op-first'].detail.diff.before.category_id, null);
  assert.equal(byId['op-recat'].detail.diff.before.category_id, 'c-old');
});

// --- (f) category-name-to-id resolution -------------------------------------

test('(f) a name-only after is resolved to a category_id via the listCategories port (real apply)', async () => {
  const nameOnly = op({ after: { category_name: 'Groceries' } }); // no category_id
  const listCategories = spy(() => [
    { id: 'c-dining', name: 'Dining Out' },
    { id: 'c-groceries', name: 'Groceries' },
  ]);
  const callTool = spy(() => ({ ok: true }));
  const out = await applyCategorize(changeset([nameOnly]), baseCtx({ dryRun: false, callTool, listCategories }));

  assert.equal(listCategories.calls[0][0], BUDGET); // looked up against the op's budget
  assert.equal(out.results[0].status, STATUS.APPLIED);
  assert.equal(callTool.calls[0][1].category_id, 'c-groceries');
});

test('resolveCategory prefers the present id and only falls back to a name lookup when absent', async () => {
  const withId = await resolveCategory(op(), {});
  assert.equal(withId.category_id, 'c0000000-0000-4000-8000-0000000000c1');
  const byName = await resolveCategory(op({ after: { category_name: 'Groceries' } }), {
    listCategories: async () => [{ id: 'c-g', name: 'Groceries' }],
  });
  assert.equal(byName.category_id, 'c-g');
});

test('enrichAfter writes the resolved id into a COPY and never sets a null category_name (schema: string)', () => {
  const nameless = op({ after: { category_name: 'Groceries' } });
  const enriched = enrichAfter(nameless, { category_id: 'c-g', category_name: 'Groceries' });
  assert.equal(enriched.after.category_id, 'c-g');
  assert.notEqual(enriched, nameless); // a copy — the input op is untouched
  const noName = enrichAfter(op({ after: { category_id: 'x' } }), { category_id: 'c-g', category_name: null });
  assert.ok(!('category_name' in noName.after)); // never a null string field
});

test('resolveCategory errors on an AMBIGUOUS category name (>1 match) instead of guessing the first', async () => {
  // YNAB allows identically-named categories across groups; `after` carries no group.
  const nameOnly = op({ after: { category_name: 'Groceries' } });
  const listCategories = spy(() => [
    { id: 'c-g1', name: 'Groceries' }, // e.g. under "Monthly"
    { id: 'c-g2', name: 'Groceries' }, // duplicate name under "Weekly"
  ]);
  const resolved = await resolveCategory(nameOnly, { listCategories, activeBudgetId: BUDGET });
  assert.ok(resolved.error);
  assert.match(resolved.error, /ambiguous/i);
});

test('resolveCategory refuses a cross-budget category READ (defense-in-depth ahead of the guardrail)', async () => {
  const foreign = op({ budget_id: 'other-budget', after: { category_name: 'Groceries' } });
  const listCategories = spy(() => [{ id: 'c-g', name: 'Groceries' }]);
  const resolved = await resolveCategory(foreign, { listCategories, activeBudgetId: BUDGET });
  assert.ok(resolved.error);
  assert.match(resolved.error, /cross-budget/);
  assert.equal(listCategories.calls.length, 0); // the read never happened
});

// --- Holmes fold-in: name resolution in DRY-RUN too -------------------------

test('(fold-in) dry-run resolves a name-only after and the diff carries the resolved id/name — no mutating call', async () => {
  const nameOnly = op({ after: { category_name: 'Groceries' } });
  const listCategories = spy(() => [{ id: 'c-groceries', name: 'Groceries' }]);
  const callTool = spy();
  const out = await applyCategorize(changeset([nameOnly]), baseCtx({ callTool, listCategories })); // dry-run

  assert.equal(callTool.calls.length, 0);
  assert.equal(out.results[0].status, STATUS.APPLIED);
  assert.equal(out.results[0].dry_run, true);
  assert.equal(out.results[0].detail.diff.after.category_id, 'c-groceries');
  assert.equal(out.results[0].detail.diff.after.category_name, 'Groceries');
});

test('(fold-in) an unresolvable name in DRY-RUN returns an `error` result, not a simulated apply', async () => {
  const bad = op({ after: { category_name: 'Nonexistent' } });
  const listCategories = spy(() => [{ id: 'c-ok', name: 'OK' }]);
  const out = await applyCategorize(changeset([bad]), baseCtx({ listCategories })); // dry-run
  assert.equal(out.results[0].status, STATUS.ERROR);
  assert.match(out.results[0].detail.message, /did not resolve to an id/);
});

// --- (h) unresolvable category name returns an error result -----------------

test('(h) an unresolvable category name returns an `error` result (no throw, no dispatch, batch proceeds)', async () => {
  const good = op({ id: 'op-good', transaction_id: 't-good', after: { category_id: 'c-ok', category_name: 'OK' } });
  const bad = op({ id: 'op-bad', transaction_id: 't-bad', after: { category_name: 'Nonexistent' } });
  const listCategories = spy(() => [{ id: 'c-ok', name: 'OK' }]); // 'Nonexistent' has no match
  const callTool = spy(() => ({ ok: true }));
  const out = await applyCategorize(changeset([good, bad]), baseCtx({ dryRun: false, callTool, listCategories }));

  const byId = Object.fromEntries(out.results.map((r) => [r.op_id, r]));
  assert.equal(byId['op-bad'].status, STATUS.ERROR);
  assert.match(byId['op-bad'].detail.message, /did not resolve to an id/);
  // The clean op still applied — the bad one was never dispatched.
  assert.equal(byId['op-good'].status, STATUS.APPLIED);
  assert.ok(!callTool.calls.some(([, p]) => p && p.transaction_id === 't-bad'));
  assert.ok(!callTool.calls.some(([, p]) => Array.isArray(p.transactions) && p.transactions.some((e) => e.id === 't-bad')));
});

test('when every op is an unresolvable name, the batch completes with all-error results (not an abort)', async () => {
  const bad = op({ after: { category_name: 'Nope' } });
  const out = await applyCategorize(changeset([bad]), baseCtx({ dryRun: false, callTool: spy(), listCategories: async () => [] }));
  assert.equal(out.ok, true);
  assert.equal(out.aborted, false);
  assert.equal(out.results[0].status, STATUS.ERROR);
});

// --- blocker 1: a malformed / empty envelope must fail CLOSED, not fail open -----

test('(blocker 1) applyCategorize(null) fails CLOSED as schema_invalid — never a fail-open success', async () => {
  const out = await applyCategorize(null); // the exact repro: no changeset, no ctx
  assert.equal(out.ok, false);
  assert.equal(out.aborted, true);
  assert.equal(out.reason, OUTCOME.SCHEMA_INVALID);
  assert.deepEqual(out.results, []);
});

test('(blocker 1) an empty / non-array operations envelope returns schema_invalid, not "nothing to do, all good"', async () => {
  for (const bad of [{}, { operations: [] }, { operations: 'nope' }]) {
    const out = await applyCategorize(bad, baseCtx({ dryRun: false, callTool: spy(() => ({ ok: true })) }));
    assert.equal(out.ok, false, `${JSON.stringify(bad)} must not report success`);
    assert.equal(out.aborted, true);
    assert.equal(out.reason, OUTCOME.SCHEMA_INVALID);
    assert.deepEqual(out.results, []);
  }
});

// --- blocker 2: an executor abort must not discard already-computed results ------

test('(blocker 2) a schema_invalid executor abort still returns EVERY op result — resolve-phase errors are never dropped', async () => {
  // op A: schema-invalid categorize (missing `rationale`) but passes resolveCategory
  //       (it carries after.category_id) → handed to the executor, whose trimmed
  //       batch aborts as schema_invalid (results: []).
  // op B: a name-only after that can't resolve → a resolve-phase ERROR in `merged`.
  const a = op({ id: 'op-a', transaction_id: 't-a' });
  delete a.rationale; // makes the trimmed change-set schema-invalid
  const b = op({ id: 'op-b', transaction_id: 't-b', after: { category_name: 'Nonexistent' } });
  const listCategories = spy(() => []); // 'Nonexistent' resolves to nothing
  const out = await applyCategorize(changeset([a, b]), baseCtx({ dryRun: false, callTool: spy(() => ({ ok: true })), listCategories }));

  assert.equal(out.ok, false);
  assert.equal(out.reason, OUTCOME.SCHEMA_INVALID);
  assert.equal(out.results.length, 2); // nothing lost — one result per op the caller handed us
  const byId = Object.fromEntries(out.results.map((r) => [r.op_id, r]));
  // The bug: op-b's resolve error was silently discarded when the executor aborted.
  assert.equal(byId['op-b'].status, STATUS.ERROR);
  assert.match(byId['op-b'].detail.message, /did not resolve to an id/);
  // op-a (in the aborted run set) is surfaced as an error too, not vanished.
  assert.equal(byId['op-a'].status, STATUS.ERROR);
});

// --- blocker (this round): a foreign-type op must not poison the valid batch -----

test('(blocker) a mixed-type change-set does NOT poison the valid categorize op — the foreign op errors, categorize still applies', async () => {
  // The M4-1 schema allows mixed-type envelopes. A foreign (allocate) op has no
  // categorize tool: forwarding it into the executor batch would abort the WHOLE
  // batch in the tool pre-flight, reporting the valid categorize op as blocked.
  const cat = op({ id: 'op-cat', transaction_id: 't-cat', after: { category_id: 'c-a', category_name: 'A' } });
  const foreign = { id: 'op-alloc', type: 'allocate', budget_id: BUDGET, category_id: 'c-x', month: '2026-06-01', before: { budgeted: 0 }, after: { budgeted: 100000 }, rationale: 'r', risk: 'low' };
  const callTool = bulkAwareCallTool();
  const out = await applyCategorize(changeset([cat, foreign]), baseCtx({ dryRun: false, callTool }));

  const byId = Object.fromEntries(out.results.map((r) => [r.op_id, r]));
  // The valid categorize op applied — it was NOT dragged down by the foreign op.
  assert.equal(byId['op-cat'].status, STATUS.APPLIED);
  // The foreign op got its own terminal routing error (never forwarded, never dispatched).
  assert.equal(byId['op-alloc'].status, STATUS.ERROR);
  assert.equal(byId['op-alloc'].detail.phase, 'routing');
  assert.match(byId['op-alloc'].detail.message, /only processes "categorize"/);
  // The categorize op WAS dispatched; the foreign op's id/type never hit the tool.
  assert.ok(callTool.calls.some(([, p]) => (p && p.transaction_id === 't-cat') || (Array.isArray(p.transactions) && p.transactions.some((e) => e.id === 't-cat'))));
  assert.ok(!callTool.calls.some(([, p]) => p && (p.category_id === 'c-x' || p.month)));
});

// --- blocker (this round): activeBudgetId is mandatory before any resolution read --

test('(blocker) a name-only op with NO activeBudgetId throws BEFORE any cross-budget listCategories read', async () => {
  const nameOnly = op({ budget_id: 'SOMEONE-ELSES-BUDGET', after: { category_name: 'Groceries' } });
  const listCategories = spy(() => [{ id: 'c-g', name: 'Groceries' }]);
  // activeBudgetId omitted → must throw up front, before resolution runs the READ.
  await assert.rejects(
    () => applyCategorize(changeset([nameOnly]), { readLiveState: noDrift(), audit: auditSpy(), sleep: noWait(), listCategories, dryRun: true }),
    /activeBudgetId/,
  );
  assert.equal(listCategories.calls.length, 0); // the cross-budget read never fired
});

// --- deferred-schema loading (AC7) ------------------------------------------

test('(AC7) ToolSearch select runs before the first MCP call, with the resolved tools + family glob', async () => {
  const calls = [];
  const toolSearch = spy((names) => { calls.push(['search', names]); });
  const callTool = spy((toolName) => { calls.push(['call', toolName]); return { ok: true }; });
  await applyCategorize(changeset([op()]), baseCtx({ dryRun: false, callTool, toolSearch }));

  assert.equal(calls[0][0], 'search'); // schema load happens first
  assert.equal(calls[1][0], 'call');
  const names = toolSearch.calls[0][0];
  assert.ok(names.includes(SINGLE_TOOL) && names.includes(BULK_TOOL) && names.includes(TOOL_FAMILY_GLOB));
});

test('(AC7) an InputValidationError on the MCP call is treated as an unloaded schema — schemas are RELOADED, then it retries', async () => {
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
  const toolSearch = spy(() => undefined);
  const sleep = noWait();
  const out = await applyCategorize(changeset([op()]), baseCtx({ dryRun: false, callTool, toolSearch, sleep, retries: 3, delayMs: 1 }));

  assert.equal(out.results[0].status, STATUS.APPLIED); // succeeded on the retry
  assert.equal(attempts, 2);
  assert.ok(sleep.calls.length >= 1); // boot-patience waited before retrying
  // The reload re-ran ToolSearch: once up front + once on the retry (not just a sleep).
  assert.ok(toolSearch.calls.length >= 2);
});

// --- result contract + namespaced enforcement -------------------------------

test('(AC8/AC10) every result matches the contract and only namespaced tools are dispatched', async () => {
  const callTool = spy(() => ({ ok: true }));
  const out = await applyCategorize(changeset([op()]), baseCtx({ dryRun: false, callTool }));
  const allowed = new Set(Object.values(STATUS));
  for (const r of out.results) {
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
  await assert.rejects(() => applyCategorize(changeset([op()]), baseCtx({ dryRun: false })), /callTool/);
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
  const out = await applyCategorize(changeset([a, b]), baseCtx({ dryRun: false, callTool }));
  const byId = Object.fromEntries(out.results.map((r) => [r.op_id, r]));
  assert.equal(byId['op-1'].status, STATUS.ERROR);
  assert.equal(byId['op-1'].detail.message, 'YNAB 500');
  assert.equal(byId['op-2'].status, STATUS.APPLIED);
});
