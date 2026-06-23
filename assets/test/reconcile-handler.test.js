'use strict';

/**
 * Unit tests for the M4-9 reconciliation-assist write path.
 *
 * Run with Node's built-in test runner (the reconcile handler `require`s the M4-4
 * executor, which `require`s the Ajv validator), so install the assets deps first:
 *   npm --prefix assets install
 *   npm --prefix assets test          # node --test
 *
 * The reconcile_account pass case loads the real reconcile fixture
 * (assets/fixtures/reconcile.example.json) so the handler is tested against the
 * exact envelope M4 produces. Tool names are resolved from the guardrail's
 * exported ALLOWED_TOOLS by suffix — never typed as literals — so this file holds
 * no hard-coded namespaced tool name (issue #87 guard). All MCP ports are mocked;
 * no live YNAB API call is made.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const {
  SUB_ACTIONS,
  classifySubAction,
  isAdjustmentResponse,
  loadDeferredSchemas,
  processReconcileOp,
  applyReconcile,
  reconcileHandler,
} = require('../reconcile-handler');
const { STATUS } = require('../apply-executor');
const { ALLOWED_TOOLS } = require('../write-safety-guardrail');

const FIXTURES = path.join(__dirname, '..', 'fixtures');
const loadFixture = (name) => JSON.parse(fs.readFileSync(path.join(FIXTURES, name), 'utf8'));
const clone = (x) => JSON.parse(JSON.stringify(x));

// tool-need → allowed namespaced tool, resolved by suffix so no literal
// `mcp__plugin_workbench-ynab_ynab__*` string lives in this file.
const pick = (suffix) => ALLOWED_TOOLS.find((t) => t.endsWith(suffix));
const TOOL_MAP = {
  update_transaction: pick('_update_transaction'),
  update_transactions: pick('_update_transactions'),
  reconcile_account: pick('_reconcile_account'),
};

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

const auditSpy = () => spy(() => undefined);
const inputValidationError = () => Object.assign(new Error('InputValidationError: schemas not loaded yet'), { name: 'InputValidationError' });

// --- fixtures: a reconcile_account op (balanced) and a mark_cleared op ------

const RECONCILE_CS = loadFixture('reconcile.example.json');
const BUDGET = RECONCILE_CS.budget_id;
const reconcileOp = () => clone(RECONCILE_CS.operations[0]); // after.reconciled_balance = 1200000, before.cleared_balance = 1200000

const markClearedOp = (txnIds = ['txn-1', 'txn-2']) => ({
  id: 'op-markcleared-0001',
  type: 'reconcile',
  budget_id: BUDGET,
  account_id: 'acct-1',
  transaction_ids: txnIds,
  before: { cleared: 'uncleared' },
  after: { cleared: 'cleared' },
  rationale: 'Mark these transactions cleared to match the bank feed.',
  risk: 'low',
});

/** live state for a mark_cleared op: transactions at a given cleared status. */
const liveTxns = (txnIds, status = 'uncleared') => ({ transactions: txnIds.map((id) => ({ id, cleared: status })) });

// --- sub-action classification ---------------------------------------------

test('classifySubAction discriminates by op shape (reconciled_balance wins)', () => {
  assert.equal(classifySubAction(reconcileOp()), SUB_ACTIONS.RECONCILE_ACCOUNT);
  assert.equal(classifySubAction(markClearedOp()), SUB_ACTIONS.MARK_CLEARED);
  // neither a reconcile balance nor a cleared+transactions mark → unrecognized
  assert.equal(classifySubAction({ after: {} }), null);
  assert.equal(classifySubAction({ after: { cleared: 'cleared' }, transaction_ids: [] }), null);
  assert.equal(classifySubAction(null), null);
});

// --- (AC1) an unrecognized sub-action errors WITHOUT touching YNAB ----------

test('(AC1) an unrecognized sub-action returns a structured error and never reads/applies', async () => {
  const read = spy();
  const apply = spy();
  const op = { id: 'op-bad', type: 'reconcile', budget_id: BUDGET, account_id: 'a1', before: {}, after: {}, rationale: 'x', risk: 'low' };
  const res = await processReconcileOp(op, { activeBudgetId: BUDGET, dryRun: false, toolMap: TOOL_MAP, readLiveState: read, applyOp: apply });
  assert.equal(res.status, STATUS.ERROR);
  assert.equal(res.detail.reason, 'unrecognized_sub_action');
  assert.equal(read.calls.length, 0); // YNAB untouched
  assert.equal(apply.calls.length, 0);
});

// --- (AC2) mark_cleared dry-run diff ---------------------------------------

test('(AC2) mark_cleared dry-run returns a per-transaction before→after cleared diff; nothing mutated', async () => {
  const op = markClearedOp(['txn-1', 'txn-2']);
  const apply = spy();
  const res = await processReconcileOp(op, {
    activeBudgetId: BUDGET,
    // dryRun omitted → defaults to true
    toolMap: TOOL_MAP,
    readLiveState: spy(() => liveTxns(['txn-1', 'txn-2'], 'uncleared')),
    applyOp: apply,
  });
  assert.equal(res.status, STATUS.APPLIED);
  assert.equal(res.dry_run, true);
  assert.equal(res.detail.simulated, true);
  assert.equal(res.detail.sub_action, SUB_ACTIONS.MARK_CLEARED);
  assert.deepEqual(res.detail.diff, [
    { transaction_id: 'txn-1', before: 'uncleared', after: 'cleared' },
    { transaction_id: 'txn-2', before: 'uncleared', after: 'cleared' },
  ]);
  assert.equal(apply.calls.length, 0); // no mutating tool called
});

// --- (AC3) mark_cleared real apply: field isolation ------------------------

test('(AC3) mark_cleared real apply (batch) sets ONLY the cleared field on each transaction', async () => {
  const op = markClearedOp(['txn-1', 'txn-2']);
  const apply = spy(() => ({ ok: true }));
  const res = await processReconcileOp(op, {
    activeBudgetId: BUDGET,
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: spy(() => liveTxns(['txn-1', 'txn-2'], 'uncleared')),
    applyOp: apply,
  });
  assert.equal(res.status, STATUS.APPLIED);
  assert.equal(res.dry_run, false);
  // batch → the plural tool, resolved from the allow-list.
  assert.equal(apply.calls.length, 1);
  const [toolName, payload] = apply.calls[0];
  assert.equal(toolName, TOOL_MAP.update_transactions);
  // The payload carries ONLY id + cleared per transaction — no other field can leak through.
  assert.deepEqual(payload, { transactions: [{ id: 'txn-1', cleared: 'cleared' }, { id: 'txn-2', cleared: 'cleared' }] });
  for (const t of payload.transactions) assert.deepEqual(Object.keys(t).sort(), ['cleared', 'id']);
});

test('(AC3) mark_cleared real apply (single) uses the singular tool and a minimal patch', async () => {
  const op = markClearedOp(['txn-1']);
  const apply = spy(() => ({ ok: true }));
  const res = await processReconcileOp(op, {
    activeBudgetId: BUDGET,
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: spy(() => liveTxns(['txn-1'], 'uncleared')),
    applyOp: apply,
  });
  assert.equal(res.status, STATUS.APPLIED);
  const [toolName, payload] = apply.calls[0];
  assert.equal(toolName, TOOL_MAP.update_transaction);
  assert.deepEqual(payload, { transaction_id: 'txn-1', cleared: 'cleared' });
});

// --- (AC4) drift-stale skip -------------------------------------------------

test('(AC4) mark_cleared is skipped-stale when a target transaction drifted from the before snapshot', async () => {
  const op = markClearedOp(['txn-1', 'txn-2']);
  const apply = spy();
  // txn-2 already reconciled (live) ≠ before.cleared "uncleared" → stale
  const res = await processReconcileOp(op, {
    activeBudgetId: BUDGET,
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: spy(() => ({ transactions: [{ id: 'txn-1', cleared: 'uncleared' }, { id: 'txn-2', cleared: 'reconciled' }] })),
    applyOp: apply,
  });
  assert.equal(res.status, STATUS.SKIPPED_STALE);
  assert.equal(res.detail.reason, 'stale');
  assert.equal(apply.calls.length, 0); // real apply skips the stale op
});

test('(AC4) reconcile_account is skipped-stale when the account cleared balance drifted; dry-run surfaces it', async () => {
  const op = reconcileOp();
  const apply = spy();
  // live cleared balance moved away from before.cleared_balance (1200000) → stale
  const res = await processReconcileOp(op, {
    activeBudgetId: BUDGET,
    dryRun: true,
    toolMap: TOOL_MAP,
    readLiveState: spy(() => ({ cleared_balance: 1250000, reconciled_balance: 1145010, cleared: 'cleared' })),
    applyOp: apply,
  });
  assert.equal(res.status, STATUS.SKIPPED_STALE);
  assert.equal(res.detail.reason, 'stale');
  assert.equal(apply.calls.length, 0);
});

// --- (AC5) reconcile_account balance-mismatch block ------------------------

test('(AC5) reconcile_account blocks when live cleared balance ≠ asserted balance; reconcile never called; gap shown in currency', async () => {
  const op = reconcileOp();
  op.after.reconciled_balance = 1300000; // assert a balance that differs from the live cleared (1200000)
  const apply = spy();
  const res = await processReconcileOp(op, {
    activeBudgetId: BUDGET,
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: spy(() => ({ cleared_balance: 1200000, reconciled_balance: 1145010, cleared: 'cleared' })),
    applyOp: apply,
  });
  assert.equal(res.status, STATUS.BLOCKED);
  assert.equal(res.detail.reason, 'balance_mismatch');
  assert.equal(res.detail.asserted_balance, 1300000);
  assert.equal(res.detail.live_cleared_balance, 1200000);
  assert.equal(res.detail.discrepancy_milliunits, -100000);
  // discrepancy displayed in currency units (milliunits ÷ 1000)
  assert.equal(res.detail.discrepancy_display, -100);
  assert.equal(res.detail.asserted_balance_display, 1300);
  assert.equal(apply.calls.length, 0); // ynab_reconcile_account never invoked
});

// --- (AC6) reconcile_account adjustment-creation block ---------------------

test('(AC6) reconcile_account blocks when the response indicates a balance-adjustment transaction', async () => {
  const op = reconcileOp(); // balanced: live cleared 1200000 == asserted 1200000
  // applyOp returns a response carrying an auto-created adjustment transaction.
  const apply = spy(() => ({ adjustment_transaction: { id: 'adj-1', amount: -5000 } }));
  const res = await processReconcileOp(op, {
    activeBudgetId: BUDGET,
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: spy(() => ({ cleared_balance: 1200000, reconciled_balance: 1145010, cleared: 'cleared' })),
    applyOp: apply,
  });
  assert.equal(res.status, STATUS.BLOCKED);
  assert.equal(res.detail.reason, 'adjustment_would_create');
  assert.equal(apply.calls.length, 1); // the reconcile ran; the response is what trips the guard
});

test('isAdjustmentResponse trips on every known adjustment signal and nothing else', () => {
  assert.equal(isAdjustmentResponse({ adjustment: true }), true);
  assert.equal(isAdjustmentResponse({ adjustment_transaction: {} }), true);
  assert.equal(isAdjustmentResponse({ adjustment_transaction_id: 'x' }), true);
  assert.equal(isAdjustmentResponse({ ok: true }), false);
  assert.equal(isAdjustmentResponse(null), false);
});

// --- (AC7) reconcile_account dry-run plan -----------------------------------

test('(AC7) reconcile_account dry-run reports the plan when balanced and never calls reconcile', async () => {
  const op = reconcileOp();
  const apply = spy();
  const res = await processReconcileOp(op, {
    activeBudgetId: BUDGET,
    // dryRun omitted → true
    toolMap: TOOL_MAP,
    readLiveState: spy(() => ({ cleared_balance: 1200000, reconciled_balance: 1145010, cleared: 'cleared' })),
    applyOp: apply,
  });
  assert.equal(res.status, STATUS.APPLIED);
  assert.equal(res.dry_run, true);
  assert.equal(res.detail.simulated, true);
  assert.equal(res.detail.sub_action, SUB_ACTIONS.RECONCILE_ACCOUNT);
  assert.equal(res.detail.plan.reconcile_to, 1200000);
  assert.equal(res.detail.plan.reconcile_to_display, 1200);
  assert.equal(apply.calls.length, 0);
});

test('reconcile_account real apply succeeds when balanced and the response carries no adjustment', async () => {
  const op = reconcileOp();
  const apply = spy(() => ({ reconciled: true }));
  const res = await processReconcileOp(op, {
    activeBudgetId: BUDGET,
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: spy(() => ({ cleared_balance: 1200000, reconciled_balance: 1145010, cleared: 'cleared' })),
    applyOp: apply,
  });
  assert.equal(res.status, STATUS.APPLIED);
  assert.equal(res.dry_run, false);
  const [toolName, payload] = apply.calls[0];
  assert.equal(toolName, TOOL_MAP.reconcile_account);
  assert.deepEqual(payload, { account_id: op.account_id, balance: 1200000 });
});

// --- namespaced-tool enforcement -------------------------------------------

test('real apply blocks when the registered tool is denied / un-namespaced (fail-closed)', async () => {
  const op = markClearedOp(['txn-1', 'txn-2']);
  const apply = spy();
  const res = await processReconcileOp(op, {
    activeBudgetId: BUDGET,
    dryRun: false,
    // a bare, un-namespaced create tool — not on the guardrail allow-list
    toolMap: { ...TOOL_MAP, update_transactions: 'mcp__ynab__ynab_create_transaction' },
    readLiveState: spy(() => liveTxns(['txn-1', 'txn-2'], 'uncleared')),
    applyOp: apply,
  });
  assert.equal(res.status, STATUS.BLOCKED);
  assert.equal(res.detail.reason, 'guardrail_block');
  assert.equal(apply.calls.length, 0); // blocked before any dispatch
});

// --- a read failure becomes a per-op error ---------------------------------

test('a readLiveState failure becomes a per-op error (never throws out of the handler)', async () => {
  const op = reconcileOp();
  const res = await processReconcileOp(op, {
    activeBudgetId: BUDGET,
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: spy(() => { throw new Error('YNAB 503'); }),
    applyOp: spy(),
  });
  assert.equal(res.status, STATUS.ERROR);
  assert.equal(res.detail.phase, 'read');
  assert.equal(res.detail.message, 'YNAB 503');
});

// --- (AC9) ToolSearch boot-patience ----------------------------------------

test('(AC9) loadDeferredSchemas retries on InputValidationError (boot patience), not abort', async () => {
  let n = 0;
  const toolSearch = spy(() => { n += 1; if (n < 3) throw inputValidationError(); return { loaded: true }; });
  const sleep = spy(() => undefined);
  await loadDeferredSchemas(toolSearch, { retries: 5, delayMs: 0, sleep });
  assert.equal(toolSearch.calls.length, 3); // failed twice, succeeded on the third
  assert.equal(sleep.calls.length, 2); // one boot-patience sleep between each retry
});

test('(AC9) loadDeferredSchemas propagates a non-InputValidationError immediately', async () => {
  const toolSearch = spy(() => { throw new Error('connection refused'); });
  await assert.rejects(() => loadDeferredSchemas(toolSearch, { retries: 5, delayMs: 0, sleep: spy() }), /connection refused/);
  assert.equal(toolSearch.calls.length, 1); // not retried
});

// --- (AC9 + AC10) applyReconcile loads schemas once, then audits every attempt

test('(AC9+AC10) applyReconcile loads deferred schemas once, then audits every op with dry_run stamped', async () => {
  const ops = [reconcileOp(), markClearedOp(['txn-1'])];
  const audit = auditSpy();
  const toolSearch = spy(() => ({ loaded: true }));
  const out = await applyReconcile(ops, {
    activeBudgetId: BUDGET,
    dryRun: true,
    schemaVersion: RECONCILE_CS.schema_version,
    source: RECONCILE_CS.source,
    toolMap: TOOL_MAP,
    toolSearch,
    bootPatience: { delayMs: 0, sleep: spy() },
    readLiveState: spy((op) => (op.account_id === 'acct-1'
      ? liveTxns(['txn-1'], 'uncleared')
      : { cleared_balance: 1200000, reconciled_balance: 1145010, cleared: 'cleared' })),
    audit,
  });
  assert.equal(out.results.length, 2);
  assert.equal(toolSearch.calls.length, 1); // schemas loaded exactly once for the batch
  assert.equal(audit.calls.length, 2); // every op audited
  for (const [rec] of audit.calls) {
    assert.equal(rec.dryRun, true);
    assert.equal(rec.result.schema_version, RECONCILE_CS.schema_version);
    assert.equal(rec.result.run_id, RECONCILE_CS.source);
  }
});

// --- result contract + registration descriptor ----------------------------

test('every result entry matches the { op_id, status, dry_run, detail } contract', async () => {
  const out = await applyReconcile([reconcileOp(), markClearedOp(['txn-1'])], {
    activeBudgetId: BUDGET,
    dryRun: true,
    toolMap: TOOL_MAP,
    readLiveState: spy((op) => (op.account_id === 'acct-1'
      ? liveTxns(['txn-1'], 'uncleared')
      : { cleared_balance: 1200000, reconciled_balance: 1145010, cleared: 'cleared' })),
    audit: auditSpy(),
  });
  const allowed = new Set(Object.values(STATUS));
  for (const r of out.results) {
    assert.deepEqual(Object.keys(r).sort(), ['detail', 'dry_run', 'op_id', 'status']);
    assert.ok(allowed.has(r.status));
    assert.equal(typeof r.op_id, 'string');
    assert.equal(typeof r.dry_run, 'boolean');
  }
});

test('the registration descriptor names the op type and its two sub-actions', () => {
  assert.equal(reconcileHandler.op_type, 'reconcile');
  assert.deepEqual([...reconcileHandler.sub_actions].sort(), ['mark_cleared', 'reconcile_account']);
  assert.equal(typeof reconcileHandler.process, 'function');
  assert.equal(typeof reconcileHandler.apply, 'function');
});

// --- port contract (fail fast on misconfiguration) -------------------------

test('applyReconcile fails fast on a missing port or activeBudgetId', async () => {
  const ok = { readLiveState: spy(), audit: auditSpy(), toolMap: TOOL_MAP };
  await assert.rejects(() => applyReconcile([], { ...ok }), /activeBudgetId/);
  await assert.rejects(() => applyReconcile([], { activeBudgetId: BUDGET, audit: auditSpy() }), /readLiveState/);
  await assert.rejects(() => applyReconcile([], { activeBudgetId: BUDGET, readLiveState: spy() }), /audit/);
  await assert.rejects(
    () => applyReconcile([], { activeBudgetId: BUDGET, dryRun: false, readLiveState: spy(), audit: auditSpy() }),
    /applyOp/,
  );
});
