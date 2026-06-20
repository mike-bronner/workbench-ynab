'use strict';

/**
 * Unit tests for the M4-2 write-safety guardrail.
 *
 * Run with Node's built-in test runner (no extra dependency):
 *   node --test            # from the assets/ directory
 *   npm --prefix assets test
 *
 * Pass cases load the real change-set contract fixtures (assets/fixtures/*) so
 * the guardrail is tested against the exact envelopes M4 produces. Block cases
 * use crafted inputs — many are deliberately NOT schema-valid, because the
 * guardrail is fail-closed and must not assume the schema validator ran first.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('node:child_process');

const {
  LEDGER_ONLY_OP_TYPES,
  ALLOWED_TOOLS,
  DENIED_TOOLS,
  RULES,
  PASS,
  evaluateTool,
  evaluateOperation,
  evaluateChangeset,
} = require('../write-safety-guardrail');

const FIXTURES = path.join(__dirname, '..', 'fixtures');
const loadFixture = (name) => JSON.parse(fs.readFileSync(path.join(FIXTURES, name), 'utf8'));

const BUDGET = 'b1f2c3d4-1111-4a2b-9c3d-000000000001';

// --- Constants are the single source of truth -----------------------------

test('allow-list is exactly the four ledger-only op types', () => {
  assert.deepEqual([...LEDGER_ONLY_OP_TYPES].sort(), [
    'allocate',
    'categorize',
    'delete_duplicate',
    'reconcile',
  ]);
});

test('tool allow-list is exactly the five namespaced ledger-only tools', () => {
  assert.deepEqual([...ALLOWED_TOOLS].sort(), [
    'mcp__plugin_workbench-ynab_ynab__ynab_delete_transaction',
    'mcp__plugin_workbench-ynab_ynab__ynab_reconcile_account',
    'mcp__plugin_workbench-ynab_ynab__ynab_update_category',
    'mcp__plugin_workbench-ynab_ynab__ynab_update_transaction',
    'mcp__plugin_workbench-ynab_ynab__ynab_update_transactions',
  ]);
});

test('deny-list holds the namespaced money-movement tools', () => {
  for (const tool of [
    'mcp__plugin_workbench-ynab_ynab__ynab_create_transaction',
    'mcp__plugin_workbench-ynab_ynab__ynab_create_transactions',
    'mcp__plugin_workbench-ynab_ynab__ynab_create_receipt_split_transaction',
    'mcp__plugin_workbench-ynab_ynab__ynab_create_account',
    'mcp__plugin_workbench-ynab_ynab__ynab_set_default_budget',
  ]) {
    assert.ok(DENIED_TOOLS.includes(tool), `${tool} must be on the deny-list`);
  }
});

// --- (a) a valid categorize op passes --------------------------------------

test('(a) a valid categorize operation passes', () => {
  const cs = loadFixture('categorize.example.json');
  assert.deepEqual(evaluateOperation(cs.operations[0], { activeBudgetId: cs.budget_id }), {
    verdict: 'pass',
  });
  assert.deepEqual(evaluateChangeset(cs), { verdict: 'pass', blocks: [] });
});

test('the combined fixture (all four op types) passes end to end', () => {
  const cs = loadFixture('combined.example.json');
  assert.equal(evaluateChangeset(cs).verdict, 'pass');
});

test('every single-type contract fixture passes', () => {
  for (const name of [
    'categorize.example.json',
    'allocate.example.json',
    'delete-duplicate.example.json',
    'reconcile.example.json',
  ]) {
    assert.equal(evaluateChangeset(loadFixture(name)).verdict, 'pass', `${name} should pass`);
  }
});

// --- (b) ynab_create_transaction is blocked via the deny-list --------------

test('(b) ynab_create_transaction is blocked via the deny-list', () => {
  const v = evaluateTool('mcp__plugin_workbench-ynab_ynab__ynab_create_transaction');
  assert.equal(v.verdict, 'block');
  assert.equal(v.rule, RULES.TOOL_DENIED);
});

test('every allowed tool passes; every denied tool blocks; unknown tools fail closed', () => {
  for (const tool of ALLOWED_TOOLS) {
    assert.deepEqual(evaluateTool(tool), { verdict: 'pass' }, `${tool} should pass`);
  }
  for (const tool of DENIED_TOOLS) {
    const v = evaluateTool(tool);
    assert.equal(v.verdict, 'block', `${tool} should block`);
    assert.equal(v.rule, RULES.TOOL_DENIED);
  }
  const unknown = evaluateTool('mcp__plugin_workbench-ynab_ynab__ynab_do_something_new');
  assert.equal(unknown.verdict, 'block');
  assert.equal(unknown.rule, RULES.TOOL_NOT_ALLOWED);

  // A bare, un-namespaced create tool must NOT slip through the allow-list.
  const bare = evaluateTool('mcp__ynab__ynab_create_transaction');
  assert.equal(bare.verdict, 'block');
});

// --- (c) categorize with transfer_account_id in `after` is blocked ----------

test('(c) categorize with transfer_account_id in after is blocked (transfer detection)', () => {
  const op = {
    id: 'op-x',
    type: 'categorize',
    budget_id: BUDGET,
    transaction_id: 't1',
    before: { category_id: null, category_name: null },
    after: {
      category_id: 'c1',
      category_name: 'Groceries',
      transfer_account_id: 'acct-savings',
    },
    rationale: 'smuggled transfer',
    risk: 'low',
  };
  const v = evaluateOperation(op, { activeBudgetId: BUDGET });
  assert.equal(v.verdict, 'block');
  assert.equal(v.rule, RULES.MONEY_MOVEMENT_IN_CATEGORIZE);
  assert.equal(v.op_id, 'op-x');
  assert.equal(v.op_type, 'categorize');
});

test('categorize with a "Transfer : ..." payee in after is blocked', () => {
  const op = {
    id: 'op-y',
    type: 'categorize',
    budget_id: BUDGET,
    transaction_id: 't2',
    before: { category_id: null, category_name: null },
    after: { category_id: 'c1', payee_name: 'Transfer : Savings' },
    rationale: 'smuggled transfer payee',
    risk: 'low',
  };
  const v = evaluateOperation(op, { activeBudgetId: BUDGET });
  assert.equal(v.verdict, 'block');
  assert.equal(v.rule, RULES.MONEY_MOVEMENT_IN_CATEGORIZE);
});

test('a pre-existing transfer in the read-only before snapshot does NOT false-positive', () => {
  // Deleting a duplicate of a transfer is still ledger-only; the before snapshot
  // legitimately describes the existing transfer, so it must not trip detection.
  const op = {
    id: 'op-dup',
    type: 'delete_duplicate',
    budget_id: BUDGET,
    transaction_id: 't3',
    before: {
      amount: -5000,
      date: '2026-06-01',
      payee_name: 'Transfer : Savings',
      transfer_account_id: 'acct-savings',
    },
    after: { deleted: true },
    rationale: 'duplicate import of a transfer',
    risk: 'destructive',
  };
  assert.deepEqual(evaluateOperation(op, { activeBudgetId: BUDGET }), { verdict: 'pass' });
});

test('(#1) a categorize op that proposes a payee_id is blocked (payee repoint / transfer smuggle)', () => {
  // No ledger-only op legitimately sets a payee, and an opaque payee_id may be an
  // account transfer-payee id that moves real money. The guardrail can't resolve
  // the UUID, so any proposed payee_id fails closed.
  const op = {
    id: 'op-pid',
    type: 'categorize',
    budget_id: BUDGET,
    transaction_id: 't4',
    before: { category_id: null, payee_id: 'p-existing' },
    after: { category_id: 'c1', payee_id: 'p-transfer-savings' },
    rationale: 'smuggled payee repoint',
    risk: 'low',
  };
  const v = evaluateOperation(op, { activeBudgetId: BUDGET });
  assert.equal(v.verdict, 'block');
  assert.equal(v.rule, RULES.MONEY_MOVEMENT_IN_CATEGORIZE);
  assert.equal(v.op_id, 'op-pid');
});

test('a payee_id only in the read-only before snapshot does NOT false-positive', () => {
  const op = {
    id: 'op-pid-before',
    type: 'delete_duplicate',
    budget_id: BUDGET,
    transaction_id: 't5',
    before: { payee_id: 'p-existing', amount: -100 },
    after: { deleted: true },
    rationale: 'duplicate of a normal (non-transfer) transaction',
    risk: 'destructive',
  };
  assert.deepEqual(evaluateOperation(op, { activeBudgetId: BUDGET }), { verdict: 'pass' });
});

test('(#4) a categorize op with transfer_transaction_id in after is blocked', () => {
  // Exercises the other half of TRANSFER_SIGNAL_KEYS, which was previously untested.
  const op = {
    id: 'op-ttid',
    type: 'categorize',
    budget_id: BUDGET,
    transaction_id: 't6',
    before: { category_id: null },
    after: { category_id: 'c1', transfer_transaction_id: 'tt-1' },
    rationale: 'smuggled transfer via transfer_transaction_id',
    risk: 'low',
  };
  const v = evaluateOperation(op, { activeBudgetId: BUDGET });
  assert.equal(v.verdict, 'block');
  assert.equal(v.rule, RULES.MONEY_MOVEMENT_IN_CATEGORIZE);
});

test('(#3) an allocate op with a transfer signal blocks via the non-categorize arm', () => {
  // The MONEY_MOVEMENT_DETECTED rule (transfer signal on a non-categorize op) was
  // previously untested — every transfer test used a categorize op.
  const op = {
    id: 'op-alloc-mm',
    type: 'allocate',
    budget_id: BUDGET,
    category_id: 'c1',
    month: '2026-06-01',
    before: { budgeted: 0 },
    after: { budgeted: 10000, transfer_account_id: 'acct-savings' },
    rationale: 'transfer smuggled into an allocate',
    risk: 'low',
  };
  const v = evaluateOperation(op, { activeBudgetId: BUDGET });
  assert.equal(v.verdict, 'block');
  assert.equal(v.rule, RULES.MONEY_MOVEMENT_DETECTED);
  assert.equal(v.op_type, 'allocate');
});

test('an unanchored "... Transfer : ..." payee still trips detection (regex not start-anchored)', () => {
  const op = {
    id: 'op-unanchored',
    type: 'categorize',
    budget_id: BUDGET,
    transaction_id: 't7',
    before: { category_id: null },
    after: { category_id: 'c1', payee_name: 'My Transfer : Savings' },
    rationale: 'transfer payee not at the start of the string',
    risk: 'low',
  };
  const v = evaluateOperation(op, { activeBudgetId: BUDGET });
  assert.equal(v.verdict, 'block');
  assert.equal(v.rule, RULES.MONEY_MOVEMENT_IN_CATEGORIZE);
});

// --- (d) mismatched budget_id is blocked (scope assertion) ------------------

test('(d) an operation with a mismatched budget_id is blocked', () => {
  const op = {
    id: 'op-b',
    type: 'allocate',
    budget_id: 'some-other-budget',
    category_id: 'c1',
    month: '2026-06-01',
    before: { budgeted: 0 },
    after: { budgeted: 10000 },
    rationale: 'wrong budget',
    risk: 'low',
  };
  const v = evaluateOperation(op, { activeBudgetId: BUDGET });
  assert.equal(v.verdict, 'block');
  assert.equal(v.rule, RULES.BUDGET_ID_MISMATCH);
});

test('an operation budget_id mismatch surfaces through evaluateChangeset', () => {
  const cs = loadFixture('categorize.example.json');
  cs.operations[0].budget_id = 'tampered-budget';
  const result = evaluateChangeset(cs);
  assert.equal(result.verdict, 'block');
  assert.ok(result.blocks.some((b) => b.rule === RULES.BUDGET_ID_MISMATCH));
});

// --- (#1 round 2) evaluateOperation fails closed without a resolvable budget ----

test('(#1) evaluateOperation with NO context fails closed with NO_ACTIVE_BUDGET', () => {
  // The documented M4-4 hot path is evaluateOperation(op, { activeBudgetId }). A caller
  // that omits the budget must NOT silently skip per-op budget scoping and reach pass —
  // a valid op with any budget_id and no context must block, not pass.
  const op = { id: 'op-nobudget', type: 'categorize', budget_id: 'anything', after: { category_id: 'c1' } };
  const v = evaluateOperation(op);
  assert.equal(v.verdict, 'block');
  assert.equal(v.rule, RULES.NO_ACTIVE_BUDGET);
  assert.equal(v.op_id, 'op-nobudget');
  assert.equal(v.op_type, 'categorize');
});

test('(#1) evaluateOperation with an empty {} context also fails closed', () => {
  const op = { id: 'op-emptyctx', type: 'allocate', budget_id: 'anything', after: { budgeted: 1 } };
  assert.equal(evaluateOperation(op, {}).rule, RULES.NO_ACTIVE_BUDGET);
});

test('(#1) evaluateOperation with an empty-string activeBudgetId fails closed', () => {
  const op = { id: 'op-emptybudget', type: 'reconcile', budget_id: 'anything', after: {} };
  assert.equal(evaluateOperation(op, { activeBudgetId: '' }).rule, RULES.NO_ACTIVE_BUDGET);
});

test('(#1) a missing envelope budget surfaces NO_ACTIVE_BUDGET per-op too (defense in depth)', () => {
  // With evaluateOperation now fail-closed, a change-set with no resolvable active budget
  // blocks at BOTH the envelope level and per operation — the per-op verdicts carry the
  // blocked op's id so M4-5 can surface exactly which operations are affected.
  const cs = loadFixture('categorize.example.json');
  delete cs.budget_id;
  const result = evaluateChangeset(cs);
  assert.equal(result.verdict, 'block');
  assert.ok(
    result.blocks.some((b) => b.rule === RULES.NO_ACTIVE_BUDGET && b.op_id !== null),
    'expected at least one per-op NO_ACTIVE_BUDGET block',
  );
});

// --- (e) an unknown operation type is blocked (fail-closed) -----------------

test('(e) an unknown operation type is blocked (fail-closed)', () => {
  const v = evaluateOperation(
    { id: 'op-u', type: 'wire_transfer', budget_id: BUDGET },
    { activeBudgetId: BUDGET },
  );
  assert.equal(v.verdict, 'block');
  assert.equal(v.rule, RULES.OP_TYPE_NOT_ALLOWED);
});

test('a missing operation type is blocked, and malformed operations fail closed', () => {
  assert.equal(evaluateOperation({ id: 'x', budget_id: BUDGET }, { activeBudgetId: BUDGET }).rule, RULES.OP_TYPE_NOT_ALLOWED);
  assert.equal(evaluateOperation(null).rule, RULES.MALFORMED_OPERATION);
  assert.equal(evaluateOperation('nope').rule, RULES.MALFORMED_OPERATION);
  assert.equal(evaluateOperation([]).rule, RULES.MALFORMED_OPERATION);
});

// --- (f) a valid delete_duplicate with destructive risk passes -------------

test('(f) a valid delete_duplicate (risk=destructive) passes', () => {
  const cs = loadFixture('delete-duplicate.example.json');
  assert.deepEqual(evaluateOperation(cs.operations[0], { activeBudgetId: cs.budget_id }), {
    verdict: 'pass',
  });
});

// --- (g) a delete_duplicate missing destructive risk is blocked ------------

test('(g) a delete_duplicate missing risk=destructive is blocked', () => {
  const cs = loadFixture('delete-duplicate.example.json');
  const op = { ...cs.operations[0], risk: 'low' };
  const v = evaluateOperation(op, { activeBudgetId: cs.budget_id });
  assert.equal(v.verdict, 'block');
  assert.equal(v.rule, RULES.DELETE_DUPLICATE_RISK);
});

// --- Envelope-level scope assertions ---------------------------------------

test('money_movement !== false on the envelope is blocked', () => {
  const cs = loadFixture('categorize.example.json');
  cs.money_movement = true;
  const result = evaluateChangeset(cs);
  assert.equal(result.verdict, 'block');
  assert.ok(result.blocks.some((b) => b.rule === RULES.MONEY_MOVEMENT_FLAG));
});

test('a missing money_movement flag fails closed (must be strictly false)', () => {
  const cs = loadFixture('categorize.example.json');
  delete cs.money_movement;
  const result = evaluateChangeset(cs);
  assert.equal(result.verdict, 'block');
  assert.ok(result.blocks.some((b) => b.rule === RULES.MONEY_MOVEMENT_FLAG));
});

test('an explicit activeBudgetId override that disagrees with the envelope is blocked', () => {
  const cs = loadFixture('categorize.example.json');
  const result = evaluateChangeset(cs, { activeBudgetId: 'a-different-active-budget' });
  assert.equal(result.verdict, 'block');
  assert.ok(result.blocks.some((b) => b.rule === RULES.BUDGET_ID_MISMATCH));
});

test('(#2) a change-set with no budget_id and no override fails closed (no resolvable active budget)', () => {
  // Without an override, a missing envelope budget_id would leave activeBudgetId
  // undefined and skip every per-op budget assertion — a fail-open. It must block.
  const cs = loadFixture('categorize.example.json');
  delete cs.budget_id;
  const result = evaluateChangeset(cs);
  assert.equal(result.verdict, 'block');
  assert.ok(result.blocks.some((b) => b.rule === RULES.NO_ACTIVE_BUDGET));
});

test('a null or empty envelope budget_id with no override also fails closed', () => {
  const csNull = loadFixture('categorize.example.json');
  csNull.budget_id = null;
  assert.ok(evaluateChangeset(csNull).blocks.some((b) => b.rule === RULES.NO_ACTIVE_BUDGET));
  const csEmpty = loadFixture('categorize.example.json');
  csEmpty.budget_id = '';
  assert.ok(evaluateChangeset(csEmpty).blocks.some((b) => b.rule === RULES.NO_ACTIVE_BUDGET));
});

test('an explicit override resolves the active budget even when the envelope budget_id is absent... but the envelope must still match it', () => {
  // With an override supplied there IS a resolvable active budget, so NO_ACTIVE_BUDGET
  // never fires; a missing envelope budget_id instead trips the override mismatch.
  const cs = loadFixture('categorize.example.json');
  delete cs.budget_id;
  const result = evaluateChangeset(cs, { activeBudgetId: BUDGET });
  assert.equal(result.verdict, 'block');
  assert.ok(!result.blocks.some((b) => b.rule === RULES.NO_ACTIVE_BUDGET));
  assert.ok(result.blocks.some((b) => b.rule === RULES.BUDGET_ID_MISMATCH));
});

test('pass verdicts reuse the exported PASS constant', () => {
  const cs = loadFixture('categorize.example.json');
  assert.equal(evaluateOperation(cs.operations[0], { activeBudgetId: cs.budget_id }), PASS);
  assert.equal(evaluateTool(ALLOWED_TOOLS[0]), PASS);
});

test('an empty / malformed change-set fails closed', () => {
  assert.equal(evaluateChangeset(null).verdict, 'block');
  assert.equal(evaluateChangeset({ money_movement: false, operations: [] }).verdict, 'block');
  assert.equal(evaluateChangeset({ money_movement: false }).verdict, 'block');
});

test('a block verdict carries the full structured shape', () => {
  const v = evaluateOperation(
    { id: 'op-z', type: 'wire_transfer', budget_id: BUDGET },
    { activeBudgetId: BUDGET },
  );
  assert.deepEqual(Object.keys(v).sort(), ['op_id', 'op_type', 'reason', 'rule', 'verdict']);
  assert.equal(v.verdict, 'block');
  assert.equal(typeof v.reason, 'string');
  assert.ok(v.reason.length > 0);
});

// --- CLI behaviour ----------------------------------------------------------

const MODULE = path.join(__dirname, '..', 'write-safety-guardrail.js');
const FIXTURE_CATEGORIZE = path.join(FIXTURES, 'categorize.example.json');
const runCli = (args) => spawnSync(process.execPath, [MODULE, ...args], { encoding: 'utf8' });

test('CLI: a valid change-set file passes (exit 0, pass verdict JSON on stdout)', () => {
  const r = runCli([FIXTURE_CATEGORIZE]);
  assert.equal(r.status, 0);
  assert.equal(JSON.parse(r.stdout).verdict, 'pass');
});

test('CLI: a wrong --active-budget pin blocks (exit 1, block verdict)', () => {
  const r = runCli(['--active-budget', 'a-different-budget', FIXTURE_CATEGORIZE]);
  assert.equal(r.status, 1);
  assert.equal(JSON.parse(r.stdout).verdict, 'block');
});

test('(#2) CLI: --active-budget as the trailing token is a usage error, not a silent no-override', () => {
  // The flag with no following value must NOT silently fall back to the envelope
  // budget_id — for a money-safety CLI, a malformed budget pin is a hard usage error.
  const r = runCli([FIXTURE_CATEGORIZE, '--active-budget']);
  assert.equal(r.status, 2);
  assert.equal(r.stdout, '', 'no verdict JSON should be emitted on a usage error');
  assert.match(r.stderr, /--active-budget requires a non-empty/);
});

test('(#2) CLI: an empty --active-budget value is a usage error', () => {
  const r = runCli(['--active-budget', '', FIXTURE_CATEGORIZE]);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /--active-budget requires a non-empty/);
});

test('CLI: no file argument is a usage error (exit 2)', () => {
  const r = runCli([]);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /usage:/);
});
