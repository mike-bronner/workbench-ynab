'use strict';

/**
 * End-to-end write-back integration test (issue #55, M4-12): drives the M4-1
 * combined change-set through the REAL apply executor — dry-run, then simulated
 * approval, then real apply — against the in-process mock YNAB MCP
 * (tests/lib/mock-ynab-mcp.cjs), with the audit port wired to the REAL M4-3
 * bash writer (bin/audit-log.sh, YNAB_AUDIT_DIR test seam). Needs the assets
 * deps (Ajv, via the executor's validator): npm --prefix assets ci && npm --prefix assets test.
 *
 * Also proves the #49 live-read hard blocks end to end: a `before`/`twin`
 * snapshot that OMITS shape evidence is still blocked once the mock's live read
 * reveals the true shape (categorize → transfer leg / split parent; delete →
 * one-leg transfer).
 *
 * Port wiring mirrors skills/apply-executor.md; no concrete tool name is
 * hard-coded here (issue #87) — everything resolves via the mock's derived ids.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const { applyChangeset, STATUS, OUTCOME } = require('../apply-executor');
const { applyCategorize } = require('../categorize-handler');
const { applyDeleteDuplicates } = require('../delete-duplicate');
const {
  TOOLS, MUTATION_TOOL_IDS, NEVER_ALLOW_TOOL_IDS, createMockYnab,
} = require('../../tests/lib/mock-ynab-mcp.cjs');

const ROOT = path.join(__dirname, '..', '..');
const loadJson = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));
const fixtureBudget = () => loadJson(path.join(ROOT, 'tests', 'fixtures', 'mock-budget.json'));
const combinedChangeset = () => loadJson(path.join(ROOT, 'assets', 'fixtures', 'combined.example.json'));

const BUDGET = 'b1f2c3d4-1111-4a2b-9c3d-000000000001';
const ACC_CHECKING = 'a0000000-0000-4000-8000-00000000ac01';
const CAT_GROCERIES = 'c0000000-0000-4000-8000-0000000000c1';
const TXN_UNCAT = 't0000000-0000-4000-8000-00000000a001';
const TXN_VICTIM = 't0000000-0000-4000-8000-00000000d002';
const TXN_TWIN = 't0000000-0000-4000-8000-00000000d001';
const TXN_HIDDEN_TRANSFER = 't0000000-0000-4000-8000-00000000n001';
const TXN_DOPPELGANGER = 't0000000-0000-4000-8000-00000000n003';
const TXN_SPLIT = 't0000000-0000-4000-8000-00000000s001';
const MONTH = '2026-06-01';

// Op-type → mutating tool, from the mock's guardrail-derived ids (issue #87).
const TOOL_MAP = {
  categorize: TOOLS.update_transaction,
  allocate: TOOLS.update_category,
  delete_duplicate: TOOLS.delete_transaction,
  reconcile: TOOLS.reconcile_account,
};

/**
 * Wire the executor's ports to the mock, per skills/apply-executor.md. The live
 * reads project an object shaped like each op type's `before` snapshot — PLUS
 * the shape-evidence fields, which the #49 guarded handlers require the live
 * read to carry.
 */
function wirePorts(mock) {
  const call = mock.callTool;
  const readLiveState = async (op) => {
    if (op.type === 'categorize' || op.type === 'delete_duplicate') {
      const { transaction: t } = await call(TOOLS.get_transaction, { budget_id: op.budget_id, transaction_id: op.transaction_id });
      const shape = {
        subtransactions: t.subtransactions,
        transfer_account_id: t.transfer_account_id,
        transfer_transaction_id: t.transfer_transaction_id,
      };
      return op.type === 'categorize'
        ? { category_id: t.category_id, category_name: t.category_name, ...shape }
        : {
          amount: t.amount, date: t.date, payee_name: t.payee_name, category_id: t.category_id,
          account_id: t.account_id, cleared: t.cleared, memo: t.memo, import_id: t.import_id, ...shape,
        };
    }
    if (op.type === 'allocate') {
      const { category } = await call(TOOLS.get_category, { budget_id: op.budget_id, category_id: op.category_id, month: op.month });
      return { budgeted: category.budgeted };
    }
    // reconcile: account balances + the common cleared status of the listed txns.
    const { account } = await call(TOOLS.get_account, { budget_id: op.budget_id, account_id: op.account_id });
    const states = await Promise.all((op.transaction_ids || []).map(async (id) => (
      (await call(TOOLS.get_transaction, { budget_id: op.budget_id, transaction_id: id })).transaction.cleared
    )));
    return {
      cleared_balance: account.cleared_balance,
      reconciled_balance: account.reconciled_balance,
      cleared: states.every((s) => s === 'cleared') ? 'cleared' : 'mixed',
    };
  };
  const applyOp = (toolName, op) => {
    const payloads = {
      categorize: { budget_id: op.budget_id, transaction_id: op.transaction_id, category_id: op.after && op.after.category_id },
      allocate: { budget_id: op.budget_id, category_id: op.category_id, month: op.month, budgeted: op.after && op.after.budgeted },
      delete_duplicate: { budget_id: op.budget_id, transaction_id: op.transaction_id },
      reconcile: { account_id: op.account_id, balance: op.after && op.after.reconciled_balance },
    };
    return call(toolName, payloads[op.type]);
  };
  const authPreflight = () => call(TOOLS.list_budgets, {});
  return { readLiveState, applyOp, authPreflight };
}

/** An audit port wired to the REAL M4-3 bash writer, appending under a temp dir. */
function realAuditSink() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ynab-e2e-audit-'));
  const script = path.join(ROOT, 'bin', 'audit-log.sh');
  const audit = ({ operation, result, dryRun }) => {
    execFileSync('bash', [
      '-c', 'source "$1" && _audit_append "$2" "$3" "$4"', 'bash',
      script, JSON.stringify(operation), JSON.stringify(result), String(dryRun),
    ], { env: { ...process.env, YNAB_AUDIT_DIR: dir, YNAB_AUDIT_MONTH: '2026-06' }, stdio: ['ignore', 'ignore', 'inherit'] });
  };
  const records = () => fs.readFileSync(path.join(dir, 'audit-2026-06.jsonl'), 'utf8')
    .trim().split('\n').map((line) => JSON.parse(line));
  return { audit, records };
}

const mutationCalls = (mock) => mock.callLog.filter((c) => MUTATION_TOOL_IDS.includes(c.tool));
const neverCreateCalls = (mock) => mock.callLog.filter((c) => NEVER_ALLOW_TOOL_IDS.includes(c.tool));

// ---------------------------------------------------------------------------
// The end-to-end flow: proposal → dry-run → approval → apply, one shared state.
// ---------------------------------------------------------------------------

test('E2E: dry-run then approved apply of the combined change-set against the mock', async () => {
  const mock = createMockYnab(fixtureBudget());
  const ports = wirePorts(mock);
  const { audit, records } = realAuditSink();
  const changeset = combinedChangeset();
  const ctx = { activeBudgetId: BUDGET, toolMap: TOOL_MAP, ...ports, audit };

  // --- Phase 1: dry-run (the default mode — no explicit dryRun flag) --------
  const dry = await applyChangeset(changeset, ctx);
  assert.equal(dry.ok, true);
  assert.equal(dry.reason, OUTCOME.DRY_RUN_COMPLETE);
  assert.equal(dry.results.length, 4);
  assert.ok(dry.results.every((r) => r.status === STATUS.APPLIED && r.dry_run === true && r.detail.simulated === true));

  // ZERO mutation tools were called — the dry run only read.
  assert.deepEqual(mutationCalls(mock), []);

  // The REAL audit log carries one record per op, each stamped dry_run: true.
  const dryRecords = records();
  assert.equal(dryRecords.length, 4);
  assert.ok(dryRecords.every((r) => r.dry_run === true));

  // --- Simulated approval → Phase 2: real apply ------------------------------
  const applied = await applyChangeset(changeset, { ...ctx, dryRun: false });
  assert.equal(applied.ok, true);
  assert.equal(applied.reason, OUTCOME.APPLY_COMPLETE);
  assert.ok(applied.results.every((r) => r.status === STATUS.APPLIED && r.dry_run === false));

  // Each op's mutation tool was called exactly once, with the right args
  // (milliunit amounts verbatim).
  assert.deepEqual(mutationCalls(mock).map((c) => c.tool), [
    TOOLS.update_transaction, TOOLS.update_category, TOOLS.delete_transaction, TOOLS.reconcile_account,
  ]);
  assert.deepEqual(mock.callsTo(TOOLS.update_transaction)[0].args, { budget_id: BUDGET, transaction_id: TXN_UNCAT, category_id: CAT_GROCERIES });
  assert.deepEqual(mock.callsTo(TOOLS.update_category)[0].args, { budget_id: BUDGET, category_id: CAT_GROCERIES, month: MONTH, budgeted: 250000 });
  assert.deepEqual(mock.callsTo(TOOLS.delete_transaction)[0].args, { budget_id: BUDGET, transaction_id: TXN_VICTIM });
  assert.deepEqual(mock.callsTo(TOOLS.reconcile_account)[0].args, { account_id: ACC_CHECKING, balance: 1200000 });

  // The in-memory budget reflects every change.
  const txn = mock.budget.transactions.find((t) => t.id === TXN_UNCAT);
  assert.equal(txn.category_id, CAT_GROCERIES);
  const month = mock.budget.months.find((m) => m.month === MONTH);
  assert.equal(month.categories.find((c) => c.id === CAT_GROCERIES).budgeted, 250000);
  assert.equal(month.to_be_budgeted, 250000); // 500000 headroom - 250000 allocated
  assert.equal(mock.budget.transactions.find((t) => t.id === TXN_VICTIM).deleted, true);
  assert.equal(mock.budget.transactions.find((t) => t.id === TXN_TWIN).deleted, false); // the twin survives
  const account = mock.budget.accounts.find((a) => a.id === ACC_CHECKING);
  assert.equal(account.reconciled_balance, 1200000);
  assert.equal(mock.budget.transactions.find((t) => t.id === 't0000000-0000-4000-8000-00000000r001').cleared, 'reconciled');
  assert.equal(mock.budget.transactions.find((t) => t.id === 't0000000-0000-4000-8000-00000000r002').cleared, 'reconciled');

  // The audit log holds matching before/after records for each applied op,
  // appended after the four dry-run records in the same trail.
  const all = records();
  assert.equal(all.length, 8);
  const applyRecords = all.slice(4);
  assert.ok(applyRecords.every((r) => r.dry_run === false));
  changeset.operations.forEach((op, i) => {
    assert.deepEqual(applyRecords[i].before, op.before);
    assert.deepEqual(applyRecords[i].after, op.after);
    assert.equal(applyRecords[i].operation_id, op.id);
    assert.equal(applyRecords[i].result_status, STATUS.APPLIED);
    assert.equal(applyRecords[i].tool, TOOL_MAP[op.type]);
  });

  // NEVER-CREATE INVARIANT, end to end: across the entire dry-run + apply
  // sequence, zero calls to any create/transfer/payment tool.
  assert.deepEqual(neverCreateCalls(mock), []);
  assert.deepEqual(mock.neverAllowAttempts, []);
});

// ---------------------------------------------------------------------------
// #49 live-read hard blocks: shape evidence OMITTED from the snapshot is still
// caught by the live read (the one thing a payload cannot talk around).
// ---------------------------------------------------------------------------

const catOp = (transactionId) => ({
  schema_version: '2.0.0',
  generated_at: '2026-06-19T14:30:00Z',
  budget_id: BUDGET,
  budget_name: 'Family Budget',
  source: 'manual',
  money_movement: false,
  operations: [{
    id: 'op-block-1',
    type: 'categorize',
    budget_id: BUDGET,
    transaction_id: transactionId,
    before: { category_id: null, category_name: null }, // NO shape evidence
    after: { category_id: CAT_GROCERIES, category_name: 'Groceries' },
    rationale: 'block-test op',
    risk: 'low',
  }],
});

async function assertCategorizeBlocked(transactionId) {
  const mock = createMockYnab(fixtureBudget());
  const ports = wirePorts(mock);
  const audited = [];
  const out = await applyCategorize(catOp(transactionId), {
    activeBudgetId: BUDGET,
    dryRun: false,
    callTool: mock.callTool,
    ...ports,
    audit: async (r) => { audited.push(r); },
  });
  assert.equal(out.results.length, 1);
  assert.equal(out.results[0].status, STATUS.ERROR);
  assert.match(out.results[0].detail.message, /transaction_shape_live_mismatch/);
  assert.deepEqual(mutationCalls(mock), []); // the update tool was never reached
  return out;
}

test('E2E block: categorize whose snapshot omits shape evidence is blocked when the live read reveals a transfer leg', async () => {
  await assertCategorizeBlocked(TXN_HIDDEN_TRANSFER);
});

test('E2E block: categorize whose snapshot omits shape evidence is blocked when the live read reveals a split parent', async () => {
  await assertCategorizeBlocked(TXN_SPLIT);
});

test('E2E block: one-leg transfer delete whose snapshot and twin omit shape evidence is blocked by the live read', async () => {
  const mock = createMockYnab(fixtureBudget());
  const ports = wirePorts(mock);
  // The victim is SECRETLY a live transfer leg (neutral payee, so the snapshot
  // carries no transfer signal the guardrail could catch); the twin is its
  // innocent same-payee/amount/date doppelganger.
  const cs = {
    schema_version: '2.0.0',
    generated_at: '2026-06-19T14:30:00Z',
    budget_id: BUDGET,
    budget_name: 'Family Budget',
    source: 'manual',
    money_movement: false,
    operations: [{
      id: 'op-block-del-1',
      type: 'delete_duplicate',
      budget_id: BUDGET,
      transaction_id: TXN_HIDDEN_TRANSFER,
      twin: { id: TXN_DOPPELGANGER, payee_name: 'Rent Share', amount: -95000, date: '2026-06-08' },
      before: {
        amount: -95000,
        date: '2026-06-08',
        payee_name: 'Rent Share',
        category_id: null,
        account_id: ACC_CHECKING,
        cleared: 'uncleared',
        memo: 'a transfer leg DISGUISED by a neutral payee name — shape evidence lives only in the transfer fields',
        import_id: 'YNAB:-95000:2026-06-08:1',
      }, // NO transfer_account_id / transfer_transaction_id — evidence omitted
      after: { deleted: true },
      rationale: 'block-test op',
      risk: 'destructive',
    }],
  };
  const audited = [];
  const out = await applyDeleteDuplicates(cs, {
    activeBudgetId: BUDGET,
    dryRun: false,
    ...ports,
    applyOp: ports.applyOp,
    audit: async (r) => { audited.push(r); },
  });
  assert.equal(out.results.length, 1);
  assert.equal(out.results[0].status, STATUS.ERROR);
  assert.match(out.results[0].detail.message, /transfer_leg_hard_block/);
  assert.deepEqual(mock.callsTo(TOOLS.delete_transaction), []); // no delete ever dispatched
  assert.equal(mock.budget.transactions.find((t) => t.id === TXN_HIDDEN_TRANSFER).deleted, false);
});

// AC (conditional, now met — issue #212): the duplicate-candidate SURFACING
// logic is code (assets/duplicate-candidates.js), and
// e2e-duplicate-surfacing.test.js asserts the t001/t002 legitimate transfer
// pair is never surfaced as a duplicate candidate — complementing the
// delete-path hard-block backstop proven above.
