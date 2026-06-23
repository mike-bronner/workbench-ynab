// tests/unit/estimated-tax.test.mjs — unit tests for the quarterly estimated-tax
// tracker (lib/tax/estimatedTax.mjs, issue #82 / M6-4).
//
// Runs under the built-in node:test runner with NO node_modules present (only
// node: built-ins and repo-local files), per docs/testing.md. The pure math is
// tested with hand-verified figures; the state functions use a temp data dir via
// the module's documented trackerPath / dataDir seams.
//
// Covers the issue AC: Schedule C net + SE tax (net × rate) + half-SE deduction
// before income tax + marginal-bracket income tax; uneven quarter attribution;
// payee/category payment detection (outflow only); idempotent quarter upsert
// that preserves payments; payment reconciliation that dedupes by transaction id
// and recomputes remaining_due; first-run state-file creation with the required
// schema; and the read-only YTD summary render.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, existsSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  scheduleCNet,
  selfEmploymentTax,
  incomeTax,
  computeEstimate,
  quarterlyEstimate,
  quarterForDate,
  summarizeBusinessActivity,
  isEstimatedTaxPayment,
  detectPayments,
  trackerPathFor,
  emptyTracker,
  loadTracker,
  saveTracker,
  upsertQuarterEstimate,
  reconcilePayments,
  renderYtdSummary,
  TRACKER_SCHEMA_VERSION,
} from '../../lib/tax/estimatedTax.mjs';

// Default federal due dates with the uneven income-attribution boundaries,
// matching the bundled defaults (assets/tax/us-tax-lines.json).
const DUE_DATES = [
  { quarter: 1, month: 4, day: 15, periodStartMonth: 1, periodStartDay: 1, periodEndMonth: 3, periodEndDay: 31 },
  { quarter: 2, month: 6, day: 15, periodStartMonth: 4, periodStartDay: 1, periodEndMonth: 5, periodEndDay: 31 },
  { quarter: 3, month: 9, day: 15, periodStartMonth: 6, periodStartDay: 1, periodEndMonth: 8, periodEndDay: 31 },
  { quarter: 4, month: 1, day: 15, periodStartMonth: 9, periodStartDay: 1, periodEndMonth: 12, periodEndDay: 31 },
];

// MFJ 2025 marginal brackets (assets/tax/us-tax-lines.json).
const MFJ_2025 = [
  { upTo: 23850, rate: 0.10 },
  { upTo: 96950, rate: 0.12 },
  { upTo: 206700, rate: 0.22 },
  { upTo: 394600, rate: 0.24 },
  { upTo: 501050, rate: 0.32 },
  { upTo: 751600, rate: 0.35 },
  { rate: 0.37 },
];

const TMP = mkdtempSync(join(tmpdir(), 'ynab-tracker-'));

// --- Pure tax math ----------------------------------------------------------

test('scheduleCNet subtracts deductible expenses (and can be negative)', () => {
  assert.equal(scheduleCNet({ grossIncome: 80000, deductibleExpenses: 20000 }), 60000);
  assert.equal(scheduleCNet({ grossIncome: 1000, deductibleExpenses: 1500 }), -500);
  assert.equal(scheduleCNet({}), 0);
});

test('selfEmploymentTax is net × rate, and zero at or below a zero net', () => {
  assert.equal(selfEmploymentTax(60000, 0.153), 9180);
  assert.equal(selfEmploymentTax(0, 0.153), 0);
  assert.equal(selfEmploymentTax(-500, 0.153), 0);
});

test('incomeTax sums marginal bracket slices; zero base owes nothing', () => {
  const b = [{ upTo: 10000, rate: 0.10 }, { upTo: 40000, rate: 0.20 }, { rate: 0.30 }];
  assert.equal(incomeTax(5000, b), 500); // 5000 × 10%
  assert.equal(incomeTax(50000, b), 10000); // 1000 + 6000 + 3000
  assert.equal(incomeTax(0, b), 0);
  assert.equal(incomeTax(-100, b), 0);
  assert.equal(incomeTax(50000, []), 0); // no brackets → nothing to apply
});

test('computeEstimate applies the half-SE deduction BEFORE income tax and exposes every input', () => {
  const est = computeEstimate({
    grossIncome: 80000, deductibleExpenses: 20000, seRate: 0.153, brackets: MFJ_2025,
    meta: { taxYear: 2025, filingStatus: 'mfj' },
  });
  assert.equal(est.scheduleCNet, 60000);
  assert.equal(est.seTax, 9180);
  assert.equal(est.halfSeDeduction, 4590);
  assert.equal(est.incomeTaxBase, 55410); // 60000 − 4590, NOT the raw net
  assert.equal(est.incomeTax, 6172.2); // 23850×10% + (55410−23850)×12%
  assert.equal(est.totalLiability, 15352.2);
  // computed_inputs are explainable from the stored object alone.
  assert.equal(est.seTaxRate, 0.153);
  assert.equal(est.taxYear, 2025);
  assert.equal(est.filingStatus, 'mfj');
});

test('quarterlyEstimate nets out the prior cumulative liability (Q1 has no prior)', () => {
  const cumThrough = computeEstimate({ grossIncome: 80000, deductibleExpenses: 20000, seRate: 0.153, brackets: MFJ_2025 });
  const q1 = quarterlyEstimate(cumThrough, null);
  assert.equal(q1.priorCumulativeLiability, 0);
  assert.equal(q1.quarterLiability, 15352.2);
  const later = quarterlyEstimate(cumThrough, { totalLiability: 5000 });
  assert.equal(later.priorCumulativeLiability, 5000);
  assert.equal(later.quarterLiability, 10352.2);
});

// --- Quarter attribution ----------------------------------------------------

test('quarterForDate maps dates onto the uneven federal quarter boundaries', () => {
  assert.equal(quarterForDate('2025-02-10', DUE_DATES), 1);
  assert.equal(quarterForDate('2025-03-31', DUE_DATES), 1); // inclusive end
  assert.equal(quarterForDate('2025-04-01', DUE_DATES), 2); // inclusive start
  assert.equal(quarterForDate('2025-05-31', DUE_DATES), 2);
  assert.equal(quarterForDate('2025-07-01', DUE_DATES), 3);
  assert.equal(quarterForDate('2025-11-30', DUE_DATES), 4);
  assert.equal(quarterForDate('not-a-date', DUE_DATES), null);
});

test('quarterForDate falls back to month mapping when boundaries are absent', () => {
  const bare = [{ quarter: 1, month: 4, day: 15 }];
  assert.equal(quarterForDate('2025-02-10', bare), 1);
  assert.equal(quarterForDate('2025-05-10', bare), 2);
  assert.equal(quarterForDate('2025-12-10', bare), 4);
});

// --- Business activity summarization (reuses the mapping engine) -------------

const summarizeProfile = {
  filingStatus: 'mfj',
  taxYear: 2025,
  lines: [
    { id: 'schedC.1', schedule: 'C', category: 'income', appliesToBusinessEntities: true },
    { id: 'schedC.27a', schedule: 'C', category: 'expense', appliesToBusinessEntities: true },
  ],
  businessEntities: [],
  mappingRules: [
    { id: 't-income', match: { payeeKeywords: ['client pay'] }, taxLineId: 'schedC.1', priority: 1, confidence: 0.9, reason: 'business income' },
    { id: 't-expense', match: { payeeKeywords: ['supply co'] }, taxLineId: 'schedC.27a', priority: 1, confidence: 0.9, reason: 'business expense' },
  ],
};

test('summarizeBusinessActivity classifies income vs expense and honours the date window', () => {
  const txns = [
    { id: 'i1', date: '2025-02-01', payee_name: 'Client Pay Inc', amount: 5000000 }, // +$5000 income
    { id: 'e1', date: '2025-02-05', payee_name: 'Supply Co', amount: -1000000 }, // −$1000 expense
    { id: 'x1', date: '2025-02-06', payee_name: 'Random Coffee', amount: -50000 }, // unclassified
    { id: 'old', date: '2024-12-31', payee_name: 'Client Pay Inc', amount: 9999000 }, // out of window
  ];
  const s = summarizeBusinessActivity(txns, summarizeProfile, { sinceISO: '2025-01-01', throughISO: '2025-03-31' });
  assert.equal(s.grossIncome, 5000);
  assert.equal(s.deductibleExpenses, 1000); // absolute magnitude of the outflow
  assert.equal(s.incomeCount, 1);
  assert.equal(s.expenseCount, 1);
  assert.equal(s.skipped, 2); // unclassified + out-of-window
});

// --- Estimated-tax payment detection ----------------------------------------

const MATCHERS = { payeeKeywords: ['irs', 'eftps'], categoryNames: ['Estimated Taxes'], categoryGroups: [], accounts: [] };

test('isEstimatedTaxPayment matches outflows by payee keyword or category; never inflows', () => {
  assert.equal(isEstimatedTaxPayment({ payee_name: 'IRS USA TAX PYMT', amount: -300000 }, MATCHERS), true);
  assert.equal(isEstimatedTaxPayment({ payee_name: 'EFTPS', amount: -1000 }, MATCHERS), true);
  assert.equal(isEstimatedTaxPayment({ payee_name: 'Anybody', category_name: 'Estimated Taxes', amount: -1000 }, MATCHERS), true);
  assert.equal(isEstimatedTaxPayment({ payee_name: 'IRS refund', amount: 300000 }, MATCHERS), false); // inflow
  assert.equal(isEstimatedTaxPayment({ payee_name: 'Grocery Store', amount: -5000 }, MATCHERS), false);
});

test('detectPayments shapes payment records and attributes them to a quarter', () => {
  const txns = [
    { id: 'p1', date: '2025-04-15', payee_name: 'IRS USA TAX PYMT', amount: -300000 }, // Q2 period? 04-15 → Q2
    { id: 'p2', date: '2025-02-10', payee_name: 'EFTPS', amount: -250000 }, // Q1
    { id: 'skip', date: '2025-02-11', payee_name: 'Grocery', amount: -5000 },
    { id: '', date: '2025-02-12', payee_name: 'IRS', amount: -100000 }, // no id → skipped
  ];
  const got = detectPayments(txns, MATCHERS, DUE_DATES);
  assert.equal(got.length, 2);
  const p1 = got.find((p) => p.ynab_transaction_id === 'p1');
  assert.deepEqual(p1, { date: '2025-04-15', amount_usd: 300, ynab_transaction_id: 'p1', quarter: 2 });
  const p2 = got.find((p) => p.ynab_transaction_id === 'p2');
  assert.equal(p2.quarter, 1);
  assert.equal(p2.amount_usd, 250);
});

// --- Tracker state ----------------------------------------------------------

test('trackerPathFor honours the explicit path, env, and data-dir seams', () => {
  assert.equal(trackerPathFor({ trackerPath: '/x/t.json' }), '/x/t.json');
  assert.equal(trackerPathFor({ dataDir: '/data' }), join('/data', 'tax-tracker.json'));
  assert.equal(trackerPathFor({ env: { YNAB_TAX_TRACKER_FILE: '/e/t.json' } }), '/e/t.json');
});

test('loadTracker returns a fresh tracker when absent; saveTracker creates the file + dir with the required schema', () => {
  const dir = join(TMP, 'fresh', 'nested'); // does not exist yet
  const trackerPath = join(dir, 'tax-tracker.json');
  assert.equal(existsSync(trackerPath), false);

  const fresh = loadTracker({ trackerPath });
  assert.equal(fresh.schemaVersion, TRACKER_SCHEMA_VERSION);
  assert.deepEqual(fresh.years, {});

  const est = quarterlyEstimate(
    computeEstimate({ grossIncome: 40000, deductibleExpenses: 10000, seRate: 0.153, brackets: MFJ_2025, meta: { taxYear: 2025 } }),
    null,
  );
  upsertQuarterEstimate(fresh, { year: 2025, quarter: 1, estimate: est });
  saveTracker(fresh, { trackerPath });

  assert.equal(existsSync(trackerPath), true);
  const onDisk = JSON.parse(readFileSync(trackerPath, 'utf8'));
  const q1 = onDisk.years['2025']['1'];
  // Required schema shape per the issue AC.
  assert.ok('estimated_liability' in q1 && Array.isArray(q1.payments) && 'remaining_due' in q1 && 'computed_inputs' in q1);
  assert.equal(q1.estimated_liability, est.quarterLiability);
  assert.equal(q1.remaining_due, est.quarterLiability); // no payments yet
  assert.ok(q1.computed_inputs.scheduleCNet === 30000);
});

test('upsertQuarterEstimate is idempotent: a second run overwrites the estimate but preserves payments', () => {
  const state = emptyTracker();
  const est1 = quarterlyEstimate(computeEstimate({ grossIncome: 40000, deductibleExpenses: 10000, seRate: 0.153, brackets: MFJ_2025 }), null);
  upsertQuarterEstimate(state, { year: 2025, quarter: 1, estimate: est1 });
  // Record a payment, then re-run the estimate for the same quarter.
  state.years['2025']['1'].payments.push({ date: '2025-04-15', amount_usd: 1000, ynab_transaction_id: 'pay-1' });
  reconcileRemaining(state); // local helper recomputes remaining so the assertion below is meaningful

  const est2 = quarterlyEstimate(computeEstimate({ grossIncome: 60000, deductibleExpenses: 10000, seRate: 0.153, brackets: MFJ_2025 }), null);
  upsertQuarterEstimate(state, { year: 2025, quarter: 1, estimate: est2 });

  const q1 = state.years['2025']['1'];
  assert.equal(q1.estimated_liability, est2.quarterLiability); // overwritten, not appended
  assert.notEqual(est1.quarterLiability, est2.quarterLiability); // the figure really changed
  assert.equal(q1.payments.length, 1); // payment preserved
  assert.equal(q1.payments[0].ynab_transaction_id, 'pay-1');
  assert.equal(q1.remaining_due, Math.round((est2.quarterLiability - 1000) * 100) / 100);
});

// tiny local helper: recompute remaining for every quarter (mirrors the module's
// internal recompute, exercised indirectly via reconcilePayments elsewhere).
function reconcileRemaining(state) {
  for (const y of Object.values(state.years)) {
    for (const q of Object.values(y)) {
      const paid = q.payments.reduce((s, p) => s + p.amount_usd, 0);
      q.remaining_due = Math.max(0, Math.round((q.estimated_liability - paid) * 100) / 100);
    }
  }
}

test('reconcilePayments records detected payments per quarter, dedupes by id, and recomputes remaining_due', () => {
  const state = emptyTracker();
  upsertQuarterEstimate(state, {
    year: 2025, quarter: 1,
    estimate: quarterlyEstimate(computeEstimate({ grossIncome: 40000, deductibleExpenses: 10000, seRate: 0.153, brackets: MFJ_2025 }), null),
  });
  const liability = state.years['2025']['1'].estimated_liability;

  const txns = [
    { id: 'pay-1', date: '2025-02-10', payee_name: 'EFTPS', amount: -1500000 }, // $1500 Q1
  ];
  const detected = detectPayments(txns, MATCHERS, DUE_DATES);
  const first = reconcilePayments(state, { year: 2025, payments: detected });
  assert.equal(first.added, 1);
  assert.equal(state.years['2025']['1'].payments.length, 1);
  assert.equal(state.years['2025']['1'].remaining_due, Math.round((liability - 1500) * 100) / 100);

  // Re-running with the same transaction adds nothing (idempotent dedupe).
  const second = reconcilePayments(state, { year: 2025, payments: detectPayments(txns, MATCHERS, DUE_DATES) });
  assert.equal(second.added, 0);
  assert.equal(state.years['2025']['1'].payments.length, 1);
});

test('a corrupt tracker file throws rather than silently discarding payment history', () => {
  const trackerPath = join(TMP, 'corrupt.json');
  writeFileSync(trackerPath, '{ not valid json', 'utf8');
  assert.throws(() => loadTracker({ trackerPath }), /invalid JSON/);
});

// --- YTD summary render (read-only) ------------------------------------------

test('renderYtdSummary reads numbers straight from state with no recomputation', () => {
  const state = emptyTracker();
  upsertQuarterEstimate(state, {
    year: 2025, quarter: 1,
    estimate: quarterlyEstimate(computeEstimate({ grossIncome: 40000, deductibleExpenses: 10000, seRate: 0.153, brackets: MFJ_2025 }), null),
  });
  reconcilePayments(state, { year: 2025, payments: detectPayments([{ id: 'pay-1', date: '2025-02-10', payee_name: 'EFTPS', amount: -1000000 }], MATCHERS, DUE_DATES) });

  const md = renderYtdSummary(state, { year: 2025 });
  assert.match(md, /## YTD Tax Summary \(2025\)/);
  assert.match(md, /\| Q1 \|/);
  assert.match(md, /\$1000\.00/); // the recorded payment
  assert.match(md, /\*\*YTD\*\*/);
  assert.match(md, /not tax advice/i);
});

test('renderYtdSummary returns a friendly empty block for a year with no data', () => {
  const md = renderYtdSummary(emptyTracker(), { year: 2099 });
  assert.match(md, /No estimated-tax data recorded yet for 2099/);
});

test.after(() => rmSync(TMP, { recursive: true, force: true }));
