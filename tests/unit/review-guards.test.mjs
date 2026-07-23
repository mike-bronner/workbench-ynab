// review-guards.test.mjs — the empty-state / degenerate-budget guard module
// (issue #33, GAP-4).
//
// Proves the module's promise: every ratio/percentage/health-score guard returns
// the sentinel `null` (never `NaN`, never `Infinity`, never a throw) on a
// zero/absent denominator or an empty dataset (AC#3/#4/#9); the degenerate-state
// detector fires each state independently (AC#1); the business-tax gate and the
// dispatch findings plan pick the right branch (AC#5/#6/#7); and the display
// helpers render the sentinel as the string "n/a" (AC#2).
//
// CommonJS module imported via the default binding (node:test / ESM interop),
// mirroring tests/unit/format-money.test.mjs. Zero dependencies — node:test only.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import guards from '../../assets/review-guards.js';

const {
  NA_DISPLAY,
  DEGENERATE_STATES,
  EMPTY_STATE_MESSAGES,
  NO_BUSINESS_ENTITY_NOTE,
  BUSINESS_TAX_MODE,
  DISPATCH_MODE,
  detectDegenerateStates,
  ratio,
  percentOf,
  savingsRate,
  changePercent,
  subScore,
  overallHealthScore,
  businessTaxSectionMode,
  dispatchFindingsPlan,
  orNa,
  formatPercent,
  formatHealthScore,
} = guards;

// --- AC#9: every divide-by-zero guard returns the sentinel, not NaN/Infinity ---
test('ratio: zero denominator returns null (not Infinity, not a throw)', () => {
  assert.equal(ratio(5, 0), null);
  assert.equal(ratio(0, 0), null); // 0/0 would be NaN without the guard
  assert.equal(ratio(-3, 0), null);
});

test('ratio: non-finite operands return null', () => {
  assert.equal(ratio(NaN, 4), null);
  assert.equal(ratio(4, NaN), null);
  assert.equal(ratio(Infinity, 4), null);
  assert.equal(ratio(4, Infinity), null);
  assert.equal(ratio(undefined, 4), null);
});

test('ratio: a valid division returns the quotient (discriminates a broken guard)', () => {
  assert.equal(ratio(3, 4), 0.75);
  assert.equal(ratio(-10, 5), -2);
});

test('percentOf: zero/absent whole returns null; otherwise a 0–100 percentage', () => {
  assert.equal(percentOf(4, 0), null);
  assert.equal(percentOf(1, 4), 25);
  assert.equal(percentOf(3, 3), 100);
});

test('savingsRate: zero or absent income returns null; otherwise net/income', () => {
  assert.equal(savingsRate(500, 0), null);
  assert.equal(savingsRate(500, NaN), null);
  assert.equal(savingsRate(250, 1000), 0.25);
});

test('changePercent: zero or absent prior base returns null; otherwise the % change', () => {
  assert.equal(changePercent(120, 0), null); // no defined change from a zero base
  assert.equal(changePercent(120, NaN), null);
  assert.equal(changePercent(120, 100), 20);
  assert.equal(changePercent(80, 100), -20);
});

// --- AC#3: health-score guards ------------------------------------------------
test('subScore: null/non-finite ratio yields null; a 0..1 ratio maps to 1..10', () => {
  assert.equal(subScore(null), null);
  assert.equal(subScore(NaN), null);
  assert.equal(subScore(0), 1); // measured-and-worst is 1, never a masking 0
  assert.equal(subScore(1), 10);
  assert.equal(subScore(0.5), 6); // 1 + 0.5*9 = 5.5 → round → 6
  assert.equal(subScore(2), 10); // clamps above 1
  assert.equal(subScore(-1), 1); // clamps below 0
});

test('overallHealthScore: all-null sub-scores (brand-new budget) returns null, not NaN', () => {
  assert.equal(overallHealthScore([null, null, null, null, null, null]), null);
  assert.equal(overallHealthScore([]), null);
  assert.equal(overallHealthScore(undefined), null);
});

test('overallHealthScore: averages the present sub-scores and scales to 0..100', () => {
  // Mean of 8 → 80. A broken (non-null-filtering) roll-up would return NaN here.
  assert.equal(overallHealthScore([8, 8, 8, 8, 8, 8]), 80);
  // Nulls are excluded from the mean, not treated as zero.
  assert.equal(overallHealthScore([10, null, null, null, null, null]), 100);
  assert.equal(overallHealthScore([6, 8, null]), 70); // mean(6,8)=7 → 70
});

// --- AC#1: degenerate-state detection -----------------------------------------
test('detectDegenerateStates: an empty/new budget reports every degenerate state', () => {
  const active = detectDegenerateStates({
    accounts: [],
    transactions: [],
    months: [],
    uncategorizedCount: 0,
    readyToAssign: null,
    businessCategoryGroup: null,
  });
  assert.deepEqual(
    [...active].sort(),
    [
      DEGENERATE_STATES.NEW_BUDGET,
      DEGENERATE_STATES.NO_BUSINESS_GROUP,
      DEGENERATE_STATES.NO_PRIOR_MONTH,
      DEGENERATE_STATES.NO_READY_TO_ASSIGN,
      DEGENERATE_STATES.ZERO_ACCOUNTS,
      DEGENERATE_STATES.ZERO_TRANSACTIONS,
      DEGENERATE_STATES.ZERO_UNCATEGORIZED,
    ].sort(),
  );
});

test('detectDegenerateStates: a fully-populated budget reports no degenerate state', () => {
  const active = detectDegenerateStates({
    accounts: [{ id: 'a' }],
    transactions: [{ id: 't', category_id: 'c' }],
    months: [{ month: '2025-01-01' }, { month: '2025-02-01' }],
    uncategorizedCount: 3,
    readyToAssign: 0, // a real balance (every dollar assigned), NOT absent
    businessCategoryGroup: { id: 'grp-biz' },
  });
  assert.deepEqual(active, []);
});

test('detectDegenerateStates: each state fires independently (discriminating)', () => {
  const base = {
    accounts: [{ id: 'a' }],
    transactions: [{ id: 't', category_id: 'c' }],
    months: [{ month: '2025-01-01' }, { month: '2025-02-01' }],
    uncategorizedCount: 3,
    readyToAssign: 100,
    businessCategoryGroup: { id: 'grp-biz' },
  };
  assert.deepEqual(detectDegenerateStates({ ...base, accounts: [] }), [DEGENERATE_STATES.ZERO_ACCOUNTS]);
  assert.deepEqual(detectDegenerateStates({ ...base, uncategorizedCount: 0 }), [DEGENERATE_STATES.ZERO_UNCATEGORIZED]);
  assert.deepEqual(detectDegenerateStates({ ...base, readyToAssign: null }), [DEGENERATE_STATES.NO_READY_TO_ASSIGN]);
  assert.deepEqual(detectDegenerateStates({ ...base, businessCategoryGroup: null }), [DEGENERATE_STATES.NO_BUSINESS_GROUP]);
  // A single month is "no prior month" but not a brand-new (zero-month) budget.
  assert.deepEqual(detectDegenerateStates({ ...base, months: [{ month: '2025-01-01' }] }), [DEGENERATE_STATES.NO_PRIOR_MONTH]);
});

test('detectDegenerateStates: uncategorizedCount falls back to the transaction list', () => {
  // No explicit count, one uncategorized transaction (no category_id/name) ⇒ not zero.
  const active = detectDegenerateStates({
    accounts: [{ id: 'a' }],
    transactions: [{ id: 't', category_id: null, category_name: null }],
    months: [{ month: '2025-01-01' }, { month: '2025-02-01' }],
    readyToAssign: 100,
    businessCategoryGroup: { id: 'grp-biz' },
  });
  assert.equal(active.includes(DEGENERATE_STATES.ZERO_UNCATEGORIZED), false);
});

// --- AC#5/#6: business-tax gate -----------------------------------------------
test('businessTaxSectionMode: no business entity configured ⇒ omit', () => {
  assert.equal(businessTaxSectionMode({ businessConfigured: false }), BUSINESS_TAX_MODE.OMIT);
  assert.equal(businessTaxSectionMode({}), BUSINESS_TAX_MODE.OMIT);
  assert.equal(businessTaxSectionMode(), BUSINESS_TAX_MODE.OMIT);
});

test('businessTaxSectionMode: configured but zero matching transactions ⇒ empty-state', () => {
  assert.equal(businessTaxSectionMode({ businessConfigured: true, matchingTransactionCount: 0 }), BUSINESS_TAX_MODE.EMPTY_STATE);
  assert.equal(businessTaxSectionMode({ businessConfigured: true }), BUSINESS_TAX_MODE.EMPTY_STATE);
});

test('businessTaxSectionMode: configured with matching transactions ⇒ render', () => {
  assert.equal(businessTaxSectionMode({ businessConfigured: true, matchingTransactionCount: 4 }), BUSINESS_TAX_MODE.RENDER);
});

// --- AC#7: dispatch findings plan ---------------------------------------------
test('dispatchFindingsPlan: zero findings ⇒ skip + "No findings this period" summary', () => {
  const plan = dispatchFindingsPlan(0);
  assert.equal(plan.mode, DISPATCH_MODE.NONE);
  assert.equal(plan.count, 0);
  assert.equal(plan.summary, EMPTY_STATE_MESSAGES.NO_FINDINGS);
});

test('dispatchFindingsPlan: a non-positive / non-finite count fails closed to NONE', () => {
  assert.equal(dispatchFindingsPlan(-2).mode, DISPATCH_MODE.NONE);
  assert.equal(dispatchFindingsPlan(NaN).mode, DISPATCH_MODE.NONE);
  assert.equal(dispatchFindingsPlan(undefined).mode, DISPATCH_MODE.NONE);
});

test('dispatchFindingsPlan: one-to-four findings ⇒ render exactly those, no padding', () => {
  for (const n of [1, 2, 3, 4]) {
    const plan = dispatchFindingsPlan(n);
    assert.equal(plan.mode, DISPATCH_MODE.AS_IS);
    assert.equal(plan.count, n);
    assert.equal(plan.summary, undefined);
  }
});

test('dispatchFindingsPlan: five or more findings ⇒ the fixed five-finding contract', () => {
  assert.deepEqual(dispatchFindingsPlan(5), { mode: DISPATCH_MODE.TOP_FIVE, count: 5 });
  assert.deepEqual(dispatchFindingsPlan(9), { mode: DISPATCH_MODE.TOP_FIVE, count: 5 });
});

// --- AC#2/#3/#4: display helpers render the sentinel as "n/a" -------------------
test('orNa: finite passes through; null/NaN/Infinity render as "n/a"', () => {
  assert.equal(orNa(78), 78);
  assert.equal(orNa(0), 0);
  assert.equal(orNa(null), NA_DISPLAY);
  assert.equal(orNa(NaN), NA_DISPLAY);
  assert.equal(orNa(Infinity), NA_DISPLAY);
  assert.equal(orNa(undefined), NA_DISPLAY);
});

test('formatPercent: null/non-finite ⇒ "n/a"; otherwise a fixed-decimal percent', () => {
  assert.equal(formatPercent(null), NA_DISPLAY);
  assert.equal(formatPercent(percentOf(4, 0)), NA_DISPLAY); // guarded → null → "n/a"
  assert.equal(formatPercent(25), '25.0%');
  assert.equal(formatPercent(12.34, 2), '12.34%');
});

test('formatHealthScore: null ⇒ "n/a"; otherwise "N/100"', () => {
  assert.equal(formatHealthScore(overallHealthScore([])), NA_DISPLAY); // empty dataset → null → "n/a"
  assert.equal(formatHealthScore(null), NA_DISPLAY);
  assert.equal(formatHealthScore(78), '78/100');
  assert.equal(formatHealthScore(0), '0/100');
});

// --- constants: the canonical strings other surfaces depend on ------------------
test('canonical constants carry the exact strings the skill and snapshot assert', () => {
  assert.equal(EMPTY_STATE_MESSAGES.NO_TRANSACTIONS, 'No transactions in this window');
  assert.equal(EMPTY_STATE_MESSAGES.NO_FINDINGS, 'No findings this period');
  assert.equal(NO_BUSINESS_ENTITY_NOTE, 'No business entity configured — tax sections skipped');
  assert.equal(NA_DISPLAY, 'n/a');
});
