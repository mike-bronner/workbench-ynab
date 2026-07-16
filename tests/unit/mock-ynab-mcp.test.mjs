// Unit tests for the mock YNAB MCP (issue #55, M4-12) — tests/lib/mock-ynab-mcp.cjs.
// Dependency-free (node:test + repo-local files only), so this suite runs in the
// no-node_modules lane via scripts/test.sh. The end-to-end write-back test that
// drives the REAL executor against this mock needs Ajv and lives in
// assets/test/e2e-write-back.test.js (the assets-tests CI lane).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  NS_PREFIX, TOOLS, READ_TOOL_IDS, MUTATION_TOOL_IDS, NEVER_ALLOW_TOOL_IDS, createMockYnab,
} from '../lib/mock-ynab-mcp.cjs';
import { ALLOWED_TOOLS, DENIED_TOOLS } from '../../assets/write-safety-guardrail.js';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const fixture = () => JSON.parse(fs.readFileSync(path.join(ROOT, 'tests', 'fixtures', 'mock-budget.json'), 'utf8'));
const BUDGET = 'b1f2c3d4-1111-4a2b-9c3d-000000000001';
const TXN_UNCAT = 't0000000-0000-4000-8000-00000000a001';
const TXN_VICTIM = 't0000000-0000-4000-8000-00000000d002';
const CAT_GROCERIES = 'c0000000-0000-4000-8000-0000000000c1';
const ACC_CHECKING = 'a0000000-0000-4000-8000-00000000ac01';
const MONTH = '2026-06-01';

// --- namespacing (AC: every tool id carries the vendored bundle's prefix) ---

test('every mock tool id is namespaced identically to the real bundle', () => {
  // The prefix is DERIVED from the guardrail allow-list, so equality with every
  // ALLOWED_TOOLS entry proves the mock and the real dispatch path share one
  // namespace — executor and handler code is identical in test and prod.
  for (const id of [...READ_TOOL_IDS, ...MUTATION_TOOL_IDS, ...NEVER_ALLOW_TOOL_IDS]) {
    assert.ok(id.startsWith(NS_PREFIX), `${id} lacks the namespace prefix`);
  }
  assert.ok(ALLOWED_TOOLS.every((t) => t.startsWith(NS_PREFIX)));
  // The mutation ids ARE the guardrail's ledger-only allow-list, verbatim.
  assert.deepEqual([...MUTATION_TOOL_IDS].sort(), [...ALLOWED_TOOLS].sort());
  assert.deepEqual(NEVER_ALLOW_TOOL_IDS, DENIED_TOOLS);
});

test('all executor read tools and all mutation tools are exposed', async () => {
  const mock = createMockYnab(fixture());
  const b = { budget_id: BUDGET };
  assert.ok((await mock.callTool(TOOLS.list_transactions, b)).transactions.length > 0);
  assert.ok((await mock.callTool(TOOLS.list_categories, b)).categories.length > 0);
  assert.ok((await mock.callTool(TOOLS.list_accounts, b)).accounts.length > 0);
  assert.ok((await mock.callTool(TOOLS.list_payees, b)).payees.length > 0);
  assert.equal((await mock.callTool(TOOLS.get_month, { ...b, month: MONTH })).month.to_be_budgeted, 500000);
  assert.equal((await mock.callTool(TOOLS.get_transaction, { ...b, transaction_id: TXN_UNCAT })).transaction.category_id, null);
  assert.equal((await mock.callTool(TOOLS.get_category, { ...b, category_id: CAT_GROCERIES, month: MONTH })).category.budgeted, 0);
  assert.equal((await mock.callTool(TOOLS.get_account, { ...b, account_id: ACC_CHECKING })).account.cleared_balance, 1200000);
  assert.equal((await mock.callTool(TOOLS.list_budgets, {})).budgets[0].id, BUDGET);
});

// --- mutations update state; reads after a write reflect the change ---------

test('update_transaction mutates state and a later read reflects it', async () => {
  const mock = createMockYnab(fixture());
  await mock.callTool(TOOLS.update_transaction, { budget_id: BUDGET, transaction_id: TXN_UNCAT, category_id: CAT_GROCERIES });
  const { transaction } = await mock.callTool(TOOLS.get_transaction, { budget_id: BUDGET, transaction_id: TXN_UNCAT });
  assert.equal(transaction.category_id, CAT_GROCERIES);
  assert.equal(transaction.category_name, 'Groceries');
});

test('update_transactions (bulk) returns the real vendored shape and mutates each entry', async () => {
  const mock = createMockYnab(fixture());
  const out = await mock.callTool(TOOLS.update_transactions, {
    budget_id: BUDGET,
    transactions: [{ id: TXN_UNCAT, category_id: CAT_GROCERIES }, { id: 'nope', category_id: CAT_GROCERIES }],
  });
  assert.equal(out.success, false);
  assert.deepEqual(out.summary, { total_requested: 2, updated: 1, failed: 1 });
  assert.equal(out.results[0].status, 'updated');
  assert.equal(out.results[0].request_index, 0);
  assert.equal(out.results[1].status, 'failed');
  const { transaction } = await mock.callTool(TOOLS.get_transaction, { budget_id: BUDGET, transaction_id: TXN_UNCAT });
  assert.equal(transaction.category_id, CAT_GROCERIES);
});

test('update_category moves budgeted and draws down Ready-to-Assign', async () => {
  const mock = createMockYnab(fixture());
  await mock.callTool(TOOLS.update_category, { budget_id: BUDGET, category_id: CAT_GROCERIES, month: MONTH, budgeted: 250000 });
  assert.equal((await mock.callTool(TOOLS.get_category, { budget_id: BUDGET, category_id: CAT_GROCERIES, month: MONTH })).category.budgeted, 250000);
  assert.equal((await mock.callTool(TOOLS.get_month, { budget_id: BUDGET, month: MONTH })).month.to_be_budgeted, 250000);
});

test('delete_transaction marks the victim deleted; list_transactions stops returning it', async () => {
  const mock = createMockYnab(fixture());
  await mock.callTool(TOOLS.delete_transaction, { budget_id: BUDGET, transaction_id: TXN_VICTIM });
  const { transactions } = await mock.callTool(TOOLS.list_transactions, { budget_id: BUDGET });
  assert.ok(!transactions.some((t) => t.id === TXN_VICTIM));
  // A second delete of the same victim fails — the mutation is not repeatable.
  await assert.rejects(() => mock.callTool(TOOLS.delete_transaction, { budget_id: BUDGET, transaction_id: TXN_VICTIM }));
});

test('reconcile_account flips cleared→reconciled and locks the balance; a mismatched balance is refused with no state change', async () => {
  const mock = createMockYnab(fixture());
  await assert.rejects(
    () => mock.callTool(TOOLS.reconcile_account, { account_id: ACC_CHECKING, balance: 999 }),
    /balance-adjustment/,
  );
  let { account } = await mock.callTool(TOOLS.get_account, { budget_id: BUDGET, account_id: ACC_CHECKING });
  assert.equal(account.reconciled_balance, 1145010); // untouched after the refusal
  await mock.callTool(TOOLS.reconcile_account, { account_id: ACC_CHECKING, balance: 1200000 });
  ({ account } = await mock.callTool(TOOLS.get_account, { budget_id: BUDGET, account_id: ACC_CHECKING }));
  assert.equal(account.reconciled_balance, 1200000);
  const { transactions } = await mock.callTool(TOOLS.list_transactions, { budget_id: BUDGET });
  assert.ok(transactions.filter((t) => t.account_id === ACC_CHECKING).every((t) => t.cleared !== 'cleared'));
});

// --- call log ----------------------------------------------------------------

test('every invocation is recorded (name + args), including unknown tools', async () => {
  const mock = createMockYnab(fixture());
  await mock.callTool(TOOLS.get_account, { budget_id: BUDGET, account_id: ACC_CHECKING });
  await assert.rejects(() => mock.callTool('mcp__ynab__ynab_update_transaction', {}), /unknown tool/); // a bare, mis-namespaced name never resolves
  assert.equal(mock.callLog.length, 2);
  assert.deepEqual(mock.callLog[0], { tool: TOOLS.get_account, args: { budget_id: BUDGET, account_id: ACC_CHECKING } });
  assert.equal(mock.callsTo(TOOLS.get_account).length, 1);
});

// --- the never-allow gate ------------------------------------------------------

test('every never-allow tool throws and the attempt is recorded', async () => {
  const mock = createMockYnab(fixture());
  for (const tool of NEVER_ALLOW_TOOL_IDS) {
    await assert.rejects(() => mock.callTool(tool, { budget_id: BUDGET }), /never-allow/);
  }
  assert.equal(mock.neverAllowAttempts.length, NEVER_ALLOW_TOOL_IDS.length);
  assert.deepEqual(mock.neverAllowAttempts.map((a) => a.tool), [...NEVER_ALLOW_TOOL_IDS]);
});

// --- drift injection -----------------------------------------------------------

test('injectDrift mutates state between phases and later reads reflect it', async () => {
  const mock = createMockYnab(fixture());
  mock.injectDrift((budget) => {
    budget.transactions.find((t) => t.id === TXN_UNCAT).category_id = CAT_GROCERIES;
  });
  const { transaction } = await mock.callTool(TOOLS.get_transaction, { budget_id: BUDGET, transaction_id: TXN_UNCAT });
  assert.equal(transaction.category_id, CAT_GROCERIES);
});

// --- fixture coverage (AC: every op type is represented; milliunits) ------------

test('the fixture budget covers every op type with integer-milliunit amounts', () => {
  const b = fixture().data.budget;
  const txns = b.transactions;
  assert.ok(txns.some((t) => t.category_id === null && !t.transfer_account_id && (t.subtransactions || []).length === 0), 'an uncategorized transaction');
  assert.ok(txns.some((t) => /miscategorized/.test(t.memo || '')), 'a miscategorized transaction');
  const dupes = txns.filter((t) => txns.some((o) => o.id !== t.id && o.payee_name === t.payee_name && o.amount === t.amount && o.date === t.date && !o.transfer_account_id && !t.transfer_account_id));
  assert.ok(dupes.length >= 2, 'a known duplicate pair');
  const month = b.months.find((m) => m.month === MONTH);
  assert.ok(month.to_be_budgeted > 0, 'positive Ready-to-Assign headroom');
  assert.ok(month.categories.some((c) => c.budgeted === 0), 'an unfunded category to allocate');
  const checking = b.accounts.find((a) => a.id === ACC_CHECKING);
  assert.equal(checking.cleared_balance, 1200000, 'a known cleared balance');
  assert.ok(txns.some((t) => t.account_id === ACC_CHECKING && t.cleared === 'uncleared'), 'uncleared transactions on the account');
  // Shape-evidence cases for the #49 live-read blocks: reads must carry the fields.
  assert.ok(txns.some((t) => t.transfer_transaction_id && !/transfer/i.test(t.payee_name)), 'a disguised transfer leg');
  assert.ok(txns.some((t) => (t.subtransactions || []).length > 0), 'a split parent');
  for (const t of txns) {
    assert.ok(Number.isInteger(t.amount), `integer milliunits: ${t.id}`);
    for (const s of t.subtransactions || []) assert.ok(Number.isInteger(s.amount));
  }
});
