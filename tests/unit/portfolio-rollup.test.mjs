// portfolio-rollup.test.mjs — the cross-budget portfolio rollup math (M6-7,
// issue #85).
//
// Proves the module's promises, each with a test that FAILS when that specific
// behaviour regresses: budget selection is fail-closed and reason-named (AC#2),
// the `business` role selects the Schedule C set (AC#6), every milliunit amount
// is converted BEFORE it is summed and no raw-milliunit total ever escapes
// (AC#5), the four rollup dimensions are aggregated (AC#4), mixed currencies are
// reported per currency and never merged — and are refused outright for the tax
// figures (AC#4/#6), and findings order most-severe first with an unrecognized
// severity throwing rather than being buried (AC#9).
//
// CommonJS module imported via the default binding (node:test / ESM interop),
// mirroring tests/unit/review-guards.test.mjs. Zero dependencies — node:test only.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import rollup from '../../assets/portfolio-rollup.js';

const {
  MILLIUNITS_PER_UNIT,
  BUSINESS_ROLE,
  SEVERITY,
  SEVERITY_EMOJI,
  EXCLUSION_REASONS,
  ROLLUP_NOTES,
  milliToCurrency,
  formatRollupMoney,
  normalizeRole,
  selectBudgets,
  businessBudgets,
  aggregatePortfolio,
  aggregateScheduleC,
  orderFindings,
} = rollup;

const USD = { iso_code: 'USD', currency_symbol: '$', symbol_first: true, decimal_digits: 2 };
const EUR = { iso_code: 'EUR', currency_symbol: '€', symbol_first: false, decimal_digits: 2 };

/** A well-formed per-budget snapshot; override any field per test. */
const snapshot = (over = {}) => ({
  label: 'Personal',
  role: 'personal',
  currency_format: USD,
  netWorthMilli: 0,
  incomeMilli: 0,
  spendingMilli: 0,
  readyToAssignMilli: 0,
  healthSubScores: [],
  ...over,
});

// --- milliunit conversion (AC#5) --------------------------------------------

test('milliToCurrency divides by exactly 1000', () => {
  assert.equal(MILLIUNITS_PER_UNIT, 1000);
  assert.equal(milliToCurrency(1234567), 1234.567);
  assert.equal(milliToCurrency(-12340), -12.34);
  assert.equal(milliToCurrency(0), 0);
});

test('milliToCurrency returns the null sentinel for non-finite input, never NaN', () => {
  for (const bad of [undefined, null, NaN, Infinity, -Infinity, '5000', {}]) {
    assert.equal(milliToCurrency(bad), null, `expected null for ${String(bad)}`);
  }
});

// --- the display boundary (AC#5) ---------------------------------------------
//
// These are the END-TO-END unit tests: a snapshot goes through the REAL
// `aggregatePortfolio` and the resulting total through the REAL formatter, and
// the assertion is the rendered STRING. Asserting the number alone cannot catch
// a units mismatch at the render step — a total of `3500` is correct, and
// `$3.50` is what a second ÷1000 makes of it.

test('a real aggregated total renders at full scale — not 1000× too small', () => {
  // $3,500.00 arrives as 3_500_000 milliunits, converted once at intake.
  const portfolio = aggregatePortfolio([snapshot({ netWorthMilli: 3_500_000 })]);
  assert.equal(portfolio.totals.USD.netWorth, 3500, 'intake conversion happened exactly once');
  assert.equal(
    formatRollupMoney(portfolio.totals.USD.netWorth, portfolio.currencyFormats.USD),
    '$3,500.00',
    'a rollup total must render at its real magnitude',
  );
});

test('every rendered rollup figure survives the round trip at full scale', () => {
  const portfolio = aggregatePortfolio([
    snapshot({
      netWorthMilli: 3_500_000,
      incomeMilli: 8_250_500,
      spendingMilli: 6_100_000,
      readyToAssignMilli: 425_750,
    }),
  ]);
  const usd = portfolio.totals.USD;
  const fmt = portfolio.currencyFormats.USD;
  assert.equal(formatRollupMoney(usd.netWorth, fmt), '$3,500.00');
  assert.equal(formatRollupMoney(usd.income, fmt), '$8,250.50');
  assert.equal(formatRollupMoney(usd.spending, fmt), '$6,100.00');
  assert.equal(formatRollupMoney(usd.netCashFlow, fmt), '$2,150.50');
  assert.equal(formatRollupMoney(usd.readyToAssign, fmt), '$425.75');
});

test('formatRollupMoney renders a per-budget figure and a negative in full', () => {
  const portfolio = aggregatePortfolio([snapshot({ netWorthMilli: -12_345_600 })]);
  assert.equal(
    formatRollupMoney(portfolio.perBudget[0].netWorth, portfolio.currencyFormats.USD),
    '-$12,345.60',
  );
});

test('formatRollupMoney honours the budget own currency format, not USD', () => {
  const portfolio = aggregatePortfolio([
    snapshot({ label: 'EU', currency_format: EUR, netWorthMilli: 2_000_000 }),
  ]);
  assert.equal(
    formatRollupMoney(portfolio.totals.EUR.netWorth, portfolio.currencyFormats.EUR),
    '2,000.00 €',
  );
});

test('formatRollupMoney renders the null sentinel as n/a, never a masking $0.00', () => {
  const portfolio = aggregatePortfolio([snapshot({ readyToAssignMilli: null })]);
  assert.equal(portfolio.totals.USD.readyToAssign, null);
  // "nothing was measured" must never render as "there is nothing".
  assert.equal(formatRollupMoney(portfolio.totals.USD.readyToAssign, USD), 'n/a');
  for (const bad of [undefined, NaN, Infinity, -Infinity, '3500', {}]) {
    assert.equal(formatRollupMoney(bad, USD), 'n/a', `expected n/a for ${String(bad)}`);
  }
});

test('formatRollupMoney rounds to whole milliunits before formatting', () => {
  // ÷1000 then ×1000 can land a hair off an integer; formatMoney documents
  // integer milliunits, so the boundary rounds rather than passing a float on.
  assert.equal(formatRollupMoney(0.1 + 0.2, USD), '$0.30');
  assert.equal(formatRollupMoney(1234.567, USD), '$1,234.57');
});

// --- budget selection (AC#2) -------------------------------------------------

test('selectBudgets includes every well-formed entry, by id or by name', () => {
  const { included, excluded } = selectBudgets([
    { label: 'Personal', role: 'personal', budget_name: 'My Budget' },
    { label: 'Business', role: 'business', budget_id: 'a-uuid' },
  ]);
  assert.deepEqual(included.map((b) => b.label), ['Personal', 'Business']);
  assert.deepEqual(excluded, []);
});

test('selectBudgets excludes each malformed entry with its named reason', () => {
  const { included, excluded } = selectBudgets([
    'not-an-object',
    { role: 'personal', budget_id: 'x' }, // no label
    { label: 'NoRole', budget_id: 'x' }, // no role
    { label: 'NoRef', role: 'personal' }, // neither budget_id nor budget_name
    { label: 'Good', role: 'personal', budget_id: 'x' },
  ]);
  assert.deepEqual(included.map((b) => b.label), ['Good']);
  assert.deepEqual(excluded.map((e) => e.reason), [
    EXCLUSION_REASONS.NOT_AN_OBJECT,
    EXCLUSION_REASONS.MISSING_LABEL,
    EXCLUSION_REASONS.MISSING_ROLE,
    EXCLUSION_REASONS.MISSING_BUDGET_REF,
  ]);
});

test('selectBudgets treats a blank label / role / ref as missing, not present', () => {
  const { included, excluded } = selectBudgets([
    { label: '   ', role: 'personal', budget_id: 'x' },
    { label: 'Blank ref', role: 'personal', budget_id: '  ', budget_name: '' },
  ]);
  assert.deepEqual(included, []);
  assert.deepEqual(excluded.map((e) => e.reason), [
    EXCLUSION_REASONS.MISSING_LABEL,
    EXCLUSION_REASONS.MISSING_BUDGET_REF,
  ]);
});

test('selectBudgets fails closed on a non-array config', () => {
  for (const bad of [undefined, null, {}, 'budgets']) {
    assert.deepEqual(selectBudgets(bad), { included: [], excluded: [] });
  }
});

// --- business-role selection (AC#6) -----------------------------------------

test('businessBudgets selects the business role case-insensitively', () => {
  assert.equal(BUSINESS_ROLE, 'business');
  const selected = [
    { label: 'P', role: 'personal' },
    { label: 'B1', role: 'Business' },
    { label: 'B2', role: '  BUSINESS  ' },
    { label: 'A', role: 'archive' },
  ];
  assert.deepEqual(businessBudgets(selected).map((b) => b.label), ['B1', 'B2']);
});

test('normalizeRole lowercases and trims, and maps an absent role to the empty string', () => {
  assert.equal(normalizeRole('  Business '), 'business');
  assert.equal(normalizeRole(undefined), '');
  assert.equal(normalizeRole(42), '');
});

// --- portfolio aggregation (AC#4/#5) ----------------------------------------

test('aggregatePortfolio sums CONVERTED amounts — a milliunit total never escapes', () => {
  const result = aggregatePortfolio([
    snapshot({ label: 'Personal', netWorthMilli: 1_000_000, incomeMilli: 500_000, spendingMilli: 300_000, readyToAssignMilli: 25_000 }),
    snapshot({ label: 'Business', role: 'business', netWorthMilli: 2_500_000, incomeMilli: 800_000, spendingMilli: 200_000, readyToAssignMilli: 75_000 }),
  ]);
  const usd = result.totals.USD;
  // 3,500,000 milliunits is 3,500.00 — not 3,500,000.
  assert.equal(usd.netWorth, 3500);
  assert.equal(usd.income, 1300);
  assert.equal(usd.spending, 500);
  assert.equal(usd.netCashFlow, 800);
  assert.equal(usd.readyToAssign, 100);
  assert.equal(result.budgetCount, 2);
  assert.deepEqual(result.currencies, ['USD']);
  assert.equal(result.mixedCurrency, false);
});

test('aggregatePortfolio reports per-budget figures in currency units too', () => {
  const result = aggregatePortfolio([snapshot({ netWorthMilli: 1_000_000, incomeMilli: 250_000 })]);
  assert.equal(result.perBudget[0].netWorth, 1000);
  assert.equal(result.perBudget[0].income, 250);
  assert.equal(result.perBudget[0].label, 'Personal');
  assert.equal(result.perBudget[0].isoCode, 'USD');
});

test('aggregatePortfolio keeps currencies separate and flags the mix', () => {
  const result = aggregatePortfolio([
    snapshot({ label: 'US', netWorthMilli: 1_000_000 }),
    snapshot({ label: 'EU', currency_format: EUR, netWorthMilli: 2_000_000 }),
  ]);
  assert.equal(result.mixedCurrency, true);
  assert.deepEqual(result.currencies, ['EUR', 'USD']);
  assert.equal(result.totals.USD.netWorth, 1000);
  assert.equal(result.totals.EUR.netWorth, 2000);
  assert.ok(result.notes.includes(ROLLUP_NOTES.MIXED_CURRENCY));
  // The two must never have been merged into one 3000 figure.
  assert.equal(Object.keys(result.totals).length, 2);
});

test('aggregatePortfolio carries each currency format through for rendering', () => {
  const result = aggregatePortfolio([snapshot(), snapshot({ currency_format: EUR })]);
  assert.equal(result.currencyFormats.USD.currency_symbol, '$');
  assert.equal(result.currencyFormats.EUR.currency_symbol, '€');
});

test('aggregatePortfolio groups a missing currency format under UNKNOWN rather than USD', () => {
  const result = aggregatePortfolio([
    snapshot({ label: 'US', netWorthMilli: 1_000_000 }),
    snapshot({ label: 'Mystery', currency_format: undefined, netWorthMilli: 5_000_000 }),
  ]);
  assert.deepEqual(result.currencies, ['UNKNOWN', 'USD']);
  assert.equal(result.totals.USD.netWorth, 1000);
  assert.equal(result.totals.UNKNOWN.netWorth, 5000);
  assert.equal(result.mixedCurrency, true);
});

test('the totals map is prototype-less, so no inherited key can pose as a currency', () => {
  // `iso_code` is off-the-wire YNAB data used as an object key. A prototype-less
  // map keeps that safety a property of the map rather than of the current
  // upper-casing, and keeps `constructor`/`toString` from resolving to inherited
  // junk a renderer might mistake for a currency bucket.
  const result = aggregatePortfolio([snapshot({ netWorthMilli: 1_000_000 })]);
  assert.equal(Object.getPrototypeOf(result.totals), null);
  assert.equal(Object.getPrototypeOf(result.currencyFormats), null);
  assert.equal(result.totals.constructor, undefined);
  assert.equal(result.totals.toString, undefined);
});

test('aggregatePortfolio keeps an odd iso_code as its own real bucket', () => {
  const result = aggregatePortfolio([
    snapshot({ label: 'Normal', netWorthMilli: 1_000_000 }),
    snapshot({ label: 'Odd', currency_format: { iso_code: '__proto__' }, netWorthMilli: 7_000_000 }),
  ]);
  assert.ok(result.currencies.includes('__PROTO__'), 'the odd bucket must be a real own key');
  assert.equal(result.totals.__PROTO__.netWorth, 7000);
  assert.equal(result.totals.USD.netWorth, 1000);
  assert.equal(result.budgetCount, 2);
});

test('aggregatePortfolio never produces NaN from a missing amount', () => {
  const result = aggregatePortfolio([
    snapshot({ netWorthMilli: 1_000_000 }),
    snapshot({ label: 'Partial', netWorthMilli: undefined, incomeMilli: null, spendingMilli: NaN }),
  ]);
  assert.equal(result.totals.USD.netWorth, 1000);
  assert.equal(result.totals.USD.income, 0);
  assert.equal(result.totals.USD.spending, 0);
  assert.ok(Number.isFinite(result.totals.USD.netCashFlow));
});

test('aggregatePortfolio reports absent Ready-to-Assign as the n/a sentinel, not 0', () => {
  const result = aggregatePortfolio([
    snapshot({ readyToAssignMilli: null }),
    snapshot({ label: 'Other', readyToAssignMilli: undefined }),
  ]);
  assert.equal(result.totals.USD.readyToAssign, null);
  assert.ok(result.notes.includes(ROLLUP_NOTES.NO_READY_TO_ASSIGN));
});

test('aggregatePortfolio reports a present zero Ready-to-Assign as data, not absence', () => {
  const result = aggregatePortfolio([snapshot({ readyToAssignMilli: 0 })]);
  assert.equal(result.totals.USD.readyToAssign, 0);
  assert.ok(!result.notes.includes(ROLLUP_NOTES.NO_READY_TO_ASSIGN));
});

test('the no-Ready-to-Assign note is per currency: one currency having data does not silence another', () => {
  // USD has RTA data, EUR does not. The EUR column renders `n/a`, so the note
  // that EXPLAINS an `n/a` column must fire — a global "any budget anywhere had
  // RTA" flag would suppress it and leave the EUR `n/a` unexplained.
  const result = aggregatePortfolio([
    snapshot({ label: 'US', readyToAssignMilli: 1_000_000 }),
    snapshot({ label: 'EU', currency_format: EUR, readyToAssignMilli: null }),
  ]);
  assert.equal(result.totals.USD.readyToAssign, 1000);
  assert.equal(result.totals.EUR.readyToAssign, null, 'the EUR bucket keeps the n/a sentinel');
  assert.ok(result.notes.includes(ROLLUP_NOTES.MIXED_CURRENCY));
  assert.ok(
    result.notes.includes(ROLLUP_NOTES.NO_READY_TO_ASSIGN),
    'a currency with no RTA data must carry the note even when another currency has it',
  );
});

test('the no-Ready-to-Assign note stays silent when every currency has the data', () => {
  const result = aggregatePortfolio([
    snapshot({ label: 'US', readyToAssignMilli: 1_000_000 }),
    snapshot({ label: 'EU', currency_format: EUR, readyToAssignMilli: 2_000_000 }),
  ]);
  assert.equal(result.totals.USD.readyToAssign, 1000);
  assert.equal(result.totals.EUR.readyToAssign, 2000);
  assert.ok(!result.notes.includes(ROLLUP_NOTES.NO_READY_TO_ASSIGN));
});

test('aggregatePortfolio unifies health as the mean of each budget overall score', () => {
  const result = aggregatePortfolio([
    snapshot({ healthSubScores: [10, 10, 10, 10, 10, 10] }), // → 100
    snapshot({ label: 'Other', healthSubScores: [5, 5, 5, 5, 5, 5] }), // → 50
  ]);
  assert.equal(result.perBudget[0].healthScore, 100);
  assert.equal(result.perBudget[1].healthScore, 50);
  assert.equal(result.healthScore, 75);
});

test('aggregatePortfolio excludes an unmeasurable budget from the unified score', () => {
  const result = aggregatePortfolio([
    snapshot({ healthSubScores: [10, 10, 10, 10, 10, 10] }),
    snapshot({ label: 'Brand new', healthSubScores: [null, null, null, null, null, null] }),
  ]);
  assert.equal(result.perBudget[1].healthScore, null);
  assert.equal(result.healthScore, 100);
});

test('aggregatePortfolio yields a null health score when nothing is measurable', () => {
  const result = aggregatePortfolio([snapshot({ healthSubScores: [null, null] })]);
  assert.equal(result.healthScore, null);
});

test('aggregatePortfolio fails closed on no budgets at all', () => {
  const result = aggregatePortfolio([]);
  assert.equal(result.budgetCount, 0);
  assert.deepEqual(result.currencies, []);
  assert.equal(result.healthScore, null);
  assert.ok(result.notes.includes(ROLLUP_NOTES.NO_BUDGETS));
});

test('aggregatePortfolio ignores non-object snapshots instead of throwing', () => {
  const result = aggregatePortfolio([null, 'nope', snapshot({ netWorthMilli: 1_000_000 })]);
  assert.equal(result.budgetCount, 1);
  assert.equal(result.totals.USD.netWorth, 1000);
});

// --- consolidated Schedule C (AC#6) -----------------------------------------

test('aggregateScheduleC sums converted business figures into one tax picture', () => {
  const result = aggregateScheduleC([
    { label: 'Biz A', currency_format: USD, scheduleCIncomeMilli: 40_000_000, scheduleCExpensesMilli: 15_000_000 },
    { label: 'Biz B', currency_format: USD, scheduleCIncomeMilli: 10_000_000, scheduleCExpensesMilli: 2_500_000 },
  ]);
  assert.equal(result.grossIncome, 50000);
  assert.equal(result.deductibleExpenses, 17500);
  assert.equal(result.net, 32500);
  assert.equal(result.budgetCount, 2);
  assert.equal(result.mixedCurrency, false);
  assert.deepEqual(result.notes, []);
});

test('aggregateScheduleC refuses to sum across currencies — figures are null, not wrong', () => {
  const result = aggregateScheduleC([
    { label: 'US biz', currency_format: USD, scheduleCIncomeMilli: 40_000_000, scheduleCExpensesMilli: 0 },
    { label: 'EU biz', currency_format: EUR, scheduleCIncomeMilli: 10_000_000, scheduleCExpensesMilli: 0 },
  ]);
  assert.equal(result.mixedCurrency, true);
  assert.equal(result.grossIncome, null);
  assert.equal(result.deductibleExpenses, null);
  assert.equal(result.net, null);
  assert.ok(result.notes.includes(ROLLUP_NOTES.MIXED_CURRENCY));
  // The per-budget breakdown still reports each budget in its own currency.
  assert.deepEqual(result.perBudget.map((b) => b.grossIncome), [40000, 10000]);
});

test('aggregateScheduleC fails closed when no business budget is configured', () => {
  const result = aggregateScheduleC([]);
  assert.equal(result.budgetCount, 0);
  assert.equal(result.net, null);
  assert.ok(result.notes.includes(ROLLUP_NOTES.NO_BUSINESS_BUDGET));
});

test('aggregateScheduleC treats a missing amount as zero, never NaN', () => {
  const result = aggregateScheduleC([
    { label: 'Biz', currency_format: USD, scheduleCIncomeMilli: 1_000_000 },
  ]);
  assert.equal(result.grossIncome, 1000);
  assert.equal(result.deductibleExpenses, 0);
  assert.equal(result.net, 1000);
});

// --- severity ordering (AC#9) -----------------------------------------------

test('orderFindings ranks most-severe first', () => {
  const ordered = orderFindings([
    { severity: SEVERITY.GOOD, text: 'g' },
    { severity: SEVERITY.ACTION_REQUIRED, text: 'r' },
    { severity: SEVERITY.ATTENTION, text: 'y' },
  ]);
  assert.deepEqual(ordered.map((f) => f.text), ['r', 'y', 'g']);
});

test('orderFindings is stable within a severity, preserving the caller ranking', () => {
  const ordered = orderFindings([
    { severity: SEVERITY.ACTION_REQUIRED, text: 'r1' },
    { severity: SEVERITY.GOOD, text: 'g1' },
    { severity: SEVERITY.ACTION_REQUIRED, text: 'r2' },
    { severity: SEVERITY.GOOD, text: 'g2' },
  ]);
  assert.deepEqual(ordered.map((f) => f.text), ['r1', 'r2', 'g1', 'g2']);
});

test('orderFindings does not mutate its input', () => {
  const input = [{ severity: SEVERITY.GOOD }, { severity: SEVERITY.ACTION_REQUIRED }];
  orderFindings(input);
  assert.equal(input[0].severity, SEVERITY.GOOD);
});

test('orderFindings throws on an unrecognized severity rather than burying the finding', () => {
  for (const bad of ['critical', '', undefined, null, 'GOOD']) {
    assert.throws(
      () => orderFindings([{ severity: SEVERITY.GOOD }, { severity: bad }]),
      TypeError,
      `expected a throw for severity ${JSON.stringify(bad)}`,
    );
  }
});

test('orderFindings rejects a prototype key masquerading as a severity', () => {
  assert.throws(() => orderFindings([{ severity: 'constructor' }]), TypeError);
  assert.throws(() => orderFindings([{ severity: 'toString' }]), TypeError);
});

test('the severity emoji match the frozen dispatch contract', () => {
  assert.equal(SEVERITY_EMOJI[SEVERITY.ACTION_REQUIRED], '🔴');
  assert.equal(SEVERITY_EMOJI[SEVERITY.ATTENTION], '🟡');
  assert.equal(SEVERITY_EMOJI[SEVERITY.GOOD], '🟢');
});
