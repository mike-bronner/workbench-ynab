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

const {
  LEDGER_ONLY_OP_TYPES,
  ALLOWED_TOOLS,
  DENIED_TOOLS,
  RULES,
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
