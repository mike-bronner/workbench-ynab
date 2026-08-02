// tests/unit/tax-year.test.mjs — the ACTIVE TAX YEAR resolution rule
// (lib/tax/taxYear.mjs, issue #17 / GAP-15).
//
// Runs under the built-in node:test runner with NO node_modules present (only
// node: built-ins and repo-local files), per docs/testing.md.
//
// Covers the issue AC end to end:
//   AC#1 resolveTaxYear(reviewDate, timezone, taxYearOverride?) exists, is exported
//        from the engine facade, and returns the integer calendar year in that zone
//   AC#2 the budget display name is never an input and never parsed
//   AC#3 a Jan-15-of-year-N+1 estimated payment attributes to tax year N
//   AC#4 all four due dates derive generically from a tax-year integer — no year
//        literal anywhere in the engine
//   AC#5 the Jan 1 → prior-year-Q4-due window surfaces BOTH years
//   AC#6 config.tax_year overrides; absent → calendar derivation
//   AC#7 the resolved year reaches the report header as meta.taxYearLabel
//   AC#8 timezone-aware derivation, the Jan-15 cross-year case, the Dec 31 / Jan 1
//        midnight boundary, and the override are each pinned by their own case
//
// Every assertion here is written to FAIL if the behaviour it names regresses —
// the fail-closed paths are asserted by forcing them, not by describing them.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import * as engine from '../../lib/tax/index.mjs';
import { loadEffectiveProfile, computeTaxSummary, resolveTaxYear, resolveYearBoundary } from '../../lib/tax/index.mjs';
import { yearBoundaryForCivilDate } from '../../lib/tax/taxYear.mjs';
import { quarterForPaymentDate, wrappingQuarterDue, detectPayments } from '../../lib/tax/estimatedTax.mjs';

const LIB_TAX = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'lib', 'tax');

// An ABSENT user profile → the bundled US defaults: real thresholds, brackets and
// the four federal due dates (Apr 15 / Jun 15 / Sep 15, and Q4 wrapping to Jan 15),
// fully anonymized.
const TMP = mkdtempSync(join(tmpdir(), 'ynab-tax-year-'));

function loadFixtureProfile() {
  const profile = loadEffectiveProfile({ dataDir: TMP, profilePath: join(TMP, 'no-such-profile.json') });
  assert.equal(profile.ok, true, 'fixture profile should load cleanly from defaults');
  return profile;
}

function dueDatesOf(profile) {
  return profile.profile.quarterlyEstimatedDueDates;
}

// --- AC #1: the export exists on the facade ---------------------------------

test('AC#1 resolveTaxYear and resolveYearBoundary are exported from the tax engine', () => {
  assert.equal(typeof engine.resolveTaxYear, 'function');
  assert.equal(typeof engine.resolveYearBoundary, 'function');
});

// --- AC #1 / #8: timezone-aware date → year ---------------------------------

test('AC#1 a civil review date resolves to its own calendar year', () => {
  assert.equal(resolveTaxYear('2025-06-15', 'America/Phoenix'), 2025);
  assert.equal(resolveTaxYear('2031-02-28', 'America/Phoenix'), 2031);
});

test('AC#8 an instant is converted to the CONFIGURED zone before the year is read', () => {
  // 2026-01-01T02:30Z is still Dec 31 2025 in Phoenix (UTC-7) but already Jan 1 2026
  // in UTC — one instant, two calendar years. This is the exact near-midnight
  // Dec 31 / Jan 1 crossing the rule exists for: if the conversion were dropped (or
  // read the host zone), one of these two answers would be wrong.
  const instant = '2026-01-01T02:30:00Z';
  assert.equal(resolveTaxYear(instant, 'America/Phoenix'), 2025);
  assert.equal(resolveTaxYear(instant, 'UTC'), 2026);

  // The mirror crossing, in the other direction: 2025-12-31T20:00Z is already
  // Jan 1 2026 in Asia/Tokyo (UTC+9) while still Dec 2025 in UTC.
  const eve = '2025-12-31T20:00:00Z';
  assert.equal(resolveTaxYear(eve, 'Asia/Tokyo'), 2026);
  assert.equal(resolveTaxYear(eve, 'UTC'), 2025);

  // A Date carries the same instant and must resolve identically to its ISO string.
  assert.equal(resolveTaxYear(new Date(instant), 'America/Phoenix'), 2025);
});

test('AC#8 a date-time with no offset is refused, not guessed at', () => {
  // '2025-12-31T23:30:00' names no instant. Placing it in a zone would invent an
  // answer — and the two plausible guesses differ by a whole tax year.
  assert.throws(() => resolveTaxYear('2025-12-31T23:30:00', 'UTC'), /explicit UTC offset/);
});

test('resolveTaxYear fails closed on an unusable timezone', () => {
  const cases = [
    [undefined, /requires an IANA timezone/],
    ['', /requires an IANA timezone/],
    [42, /requires an IANA timezone/],
    ['/etc/localtime', /not a selectable IANA zone/],
    ['America/../UTC', /not a selectable IANA zone/],
    ['America/', /not a selectable IANA zone/],
    ['America/Phoenix;rm', /not a selectable IANA zone/],
    // The zoneinfo build artifacts and mirror subtrees resolve to a UTC-equivalent
    // date — accepting one would silently re-leak the host-clock answer the
    // configured zone exists to prevent (issue #31, review round 3). Case-folded,
    // because a case-insensitive filesystem resolves `factory` to `Factory`.
    ['Factory', /not a selectable IANA zone/],
    ['factory', /not a selectable IANA zone/],
    ['posixrules', /not a selectable IANA zone/],
    ['right/UTC', /not a selectable IANA zone/],
    ['POSIX/UTC', /not a selectable IANA zone/],
    ['America/Nowhere', /does not know this zone/],
  ];
  for (const [tz, re] of cases) {
    assert.throws(() => resolveTaxYear('2025-06-15', tz), re, `expected a throw for timezone ${JSON.stringify(tz)}`);
  }
});

test('resolveTaxYear fails closed on a review date the calendar does not have', () => {
  // Well-shaped but impossible. These are the dangerous ones: they compare happily
  // against real 'YYYY-MM-DD' due dates, so a silent accept answers plausibly.
  for (const bad of ['2025-13-45', '2025-02-30', '2025-02-29']) {
    assert.throws(() => resolveTaxYear(bad, 'UTC'), /not a date the calendar has/, `expected a throw for ${bad}`);
  }
  for (const bad of ['5/1/2025', '2025', null, 20250601, {}]) {
    assert.throws(() => resolveTaxYear(bad, 'UTC'), /requires a review date/, `expected a throw for ${JSON.stringify(bad)}`);
  }
});

// --- AC #6: the config.tax_year override ------------------------------------

test('AC#6 config.tax_year overrides calendar derivation; absent falls back to it', () => {
  // Same review date, two answers — the override is what changes it.
  assert.equal(resolveTaxYear('2026-03-01', 'America/Phoenix'), 2026);
  assert.equal(resolveTaxYear('2026-03-01', 'America/Phoenix', 2024), 2024);
  // Absent in both spellings a caller can produce from a missing config key.
  assert.equal(resolveTaxYear('2026-03-01', 'America/Phoenix', undefined), 2026);
  assert.equal(resolveTaxYear('2026-03-01', 'America/Phoenix', null), 2026);
});

test('AC#6 a malformed tax_year override is refused, never silently ignored', () => {
  // Ignoring it would report a different year than the user asked for, with no
  // signal. Includes the shapes a hand-edited config actually produces.
  for (const bad of ['2025', 2025.5, 999, 10000, NaN, true, [2025]]) {
    assert.throws(
      () => resolveTaxYear('2026-03-01', 'UTC', bad),
      /four-digit integer year/,
      `expected a throw for tax_year=${JSON.stringify(bad)}`,
    );
  }
});

test('AC#6 the timezone gate runs BEFORE the override — a valid pin does not excuse a bad zone', () => {
  // The ordering inside resolveTaxYear is load-bearing, not incidental: it validates
  // `timezone` first, so a caller holding a perfectly good `config.tax_year` STILL
  // fails closed when `config.timezone` is missing or bogus. Short-circuiting on the
  // override instead would let a config with a valid pin and a broken zone through,
  // and every OTHER date that config drives (window ends, due-date compares) would
  // then be resolved against the host zone with nothing having complained.
  //
  // Pinned per unusable-zone shape, not just one representative, because each takes a
  // different branch of requireTimezone (absent / denied-structure / unknown-to-runtime)
  // and the override check could be hoisted above any one of them independently.
  const validOverride = 2024;
  const zones = [
    [undefined, /requires an IANA timezone/],
    ['', /requires an IANA timezone/],
    ['/etc/localtime', /not a selectable IANA zone/],
    ['Factory', /not a selectable IANA zone/],
    ['America/Nowhere', /does not know this zone/],
  ];
  for (const [tz, re] of zones) {
    assert.throws(
      () => resolveTaxYear('2026-03-01', tz, validOverride),
      re,
      `a valid tax_year override must not rescue timezone ${JSON.stringify(tz)}`,
    );
  }
  // Both bad: the ZONE error is the one reported, confirming the order rather than
  // just that something threw — an override-first implementation would surface the
  // 'four-digit integer year' message here instead.
  assert.throws(
    () => resolveTaxYear('2026-03-01', 'America/Nowhere', 'not-a-year'),
    /does not know this zone/,
    'with both inputs bad, the timezone must be the reported failure',
  );
  // Control: the same override on a good zone is honored, so the throws above are
  // provably the zone gate and not a rejection of the override itself.
  assert.equal(resolveTaxYear('2026-03-01', 'America/Phoenix', validOverride), 2024);
});

// --- AC #2: the budget display name is never a source -----------------------

test('AC#2 no module in lib/tax reads or parses a budget name', () => {
  // The prototype budget is named 'Personal 2024'. A year parsed out of a budget
  // name keeps answering 2024 forever and breaks on rename, so the name must not
  // reach the engine at all — asserted at the source, because there is no input to
  // pass it through behaviourally.
  const budgetNameReads = /budget[_ ]?name|budgetName|Personal 20\d\d/i;
  for (const file of readdirSync(LIB_TAX).filter((f) => f.endsWith('.mjs'))) {
    const src = readFileSync(join(LIB_TAX, file), 'utf8');
    // Strip comments first: taxYear.mjs *documents* the rule by naming the very
    // thing it refuses, and a whole-file grep would be satisfied by that prose
    // instead of by real code.
    const code = src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
    assert.equal(
      budgetNameReads.test(code),
      false,
      `${file} references a budget name in executable code — the tax year must never come from one`,
    );
  }
});

// --- AC #4: due dates derive generically from a tax-year integer -------------

test('AC#4 the four due dates derive from the tax-year integer, wrapping Q4 to N+1', () => {
  const profile = loadFixtureProfile();
  // An arbitrary far-future year no fixture mentions: any hardcoded year would show
  // up here immediately.
  const dates = profile.getQuarterlyDueDates(2031).slice().sort((a, b) => a.quarter - b.quarter);
  assert.deepEqual(
    dates.map((d) => [d.quarter, d.date]),
    [[1, '2031-04-15'], [2, '2031-06-15'], [3, '2031-09-15'], [4, '2032-01-15']],
  );
  // And the same schedule re-derives cleanly for a different year — proving the
  // year is a parameter, not a constant baked into the data path.
  const other = profile.getQuarterlyDueDates(1999).find((d) => d.quarter === 4);
  assert.equal(other.date, '2000-01-15');
});

test('AC#4 no tax-year literal is hardcoded in the engine source', () => {
  // Guards the "generic/data-driven per the brief" rule: a four-digit year in
  // executable engine code would mean some path stopped deriving it. Comments and
  // JSDoc are stripped first — they legitimately cite example years.
  for (const file of readdirSync(LIB_TAX).filter((f) => f.endsWith('.mjs'))) {
    const src = readFileSync(join(LIB_TAX, file), 'utf8');
    const code = src
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .replace(/^\s*\/\/.*$/gm, '')
      .replace(/MIN_YEAR = \d+|MAX_YEAR = \d+/g, ''); // the four-digit RANGE bound, not a tax year
    const literal = code.match(/(?<![.\d])(19|20)\d\d(?![.\d])/);
    assert.equal(literal, null, `${file} hardcodes the year ${literal && literal[0]} — tax years must be derived`);
  }
});

// --- AC #3: Q4 due Jan 15 of N+1 attributes to tax year N -------------------

test('AC#3 a payment on Jan 15 of year N+1 attributes to tax year N Q4', () => {
  const profile = loadFixtureProfile();
  const dueDates = dueDatesOf(profile);

  // The quarter half of the attribution.
  assert.equal(quarterForPaymentDate('2026-01-15', dueDates), 4);
  assert.equal(quarterForPaymentDate('2026-01-02', dueDates), 4);
  // …and the day AFTER the wrapping due date has moved on to the new year's Q1.
  assert.equal(quarterForPaymentDate('2026-01-16', dueDates), 1);

  // The tax-YEAR half: detectPayments tags each payment with the year it pays
  // toward, so a Jan 1–15 payment lands on the PRIOR year and never contaminates
  // the new one.
  const matchers = { payeeKeywords: ['IRS'], categoryNames: [], categoryGroups: [], accounts: [] };
  const payments = detectPayments(
    [
      { id: 'a', payee_name: 'IRS', amount: -100000, date: '2026-01-15' },
      { id: 'b', payee_name: 'IRS', amount: -100000, date: '2026-01-16' },
      { id: 'c', payee_name: 'IRS', amount: -100000, date: '2025-09-15' },
    ],
    matchers,
    dueDates,
  );
  const tagged = payments.map((p) => [p.quarter, p.tax_year]);
  assert.deepEqual(tagged, [[4, 2025], [1, 2026], [3, 2025]], `unexpected attribution: ${JSON.stringify(payments)}`);

  // The attribution above is positional, so it holds only while every payment
  // carries the transaction identity reconcilePayments dedupes on
  // (`ynab_transaction_id`, not the raw `id`). Key BY that field — no `?? p.id`
  // fallback, which would let a payment that lost its identity keep passing — and
  // assert the per-id attribution, so a mis-tagged or identity-less payment fails
  // here rather than silently breaking dedupe downstream.
  const byId = Object.fromEntries(payments.map((p) => [p.ynab_transaction_id, p]));
  assert.deepEqual(Object.keys(byId).sort(), ['a', 'b', 'c']);
  assert.deepEqual(
    { a: byId.a.tax_year, b: byId.b.tax_year, c: byId.c.tax_year },
    { a: 2025, b: 2026, c: 2025 },
    `payments lost their identity or their year: ${JSON.stringify(payments)}`,
  );
});

test('AC#3 the wrapping quarter is identified structurally, not by a month literal', () => {
  const profile = loadFixtureProfile();
  assert.deepEqual(wrappingQuarterDue(dueDatesOf(profile)), { quarter: 4, month: 1, day: 15, dueMd: 115 });

  // A schedule whose quarters all fall inside their own tax year has NO wrap —
  // asserted so the detector cannot be a constant that always answers "Q4".
  const inYear = [
    { quarter: 1, month: 3, day: 31 },
    { quarter: 2, month: 6, day: 30 },
    { quarter: 3, month: 9, day: 30 },
    { quarter: 4, month: 12, day: 31 },
  ];
  assert.equal(wrappingQuarterDue(inYear), null);
  assert.equal(wrappingQuarterDue([]), null);
});

// --- AC #5: the year-boundary (changeover) window ---------------------------

test('AC#5 a review inside the Jan window reports BOTH tax years', () => {
  const profile = loadFixtureProfile();
  const dueDates = dueDatesOf(profile);
  const boundary = resolveYearBoundary('2026-01-05', 'America/Phoenix', dueDates);
  assert.equal(boundary.taxYear, 2026);
  assert.equal(boundary.priorTaxYear, 2025);
  assert.equal(boundary.inChangeover, true);
  assert.equal(boundary.changeoverThrough, '2026-01-15');
  assert.equal(boundary.headerLabel, 'Tax Year 2026 (2025 close-out through 2026-01-15)');
});

test('AC#5 the window opens on Jan 1 and closes ON the wrapping due date', () => {
  const profile = loadFixtureProfile();
  const dueDates = dueDatesOf(profile);
  const at = (d) => yearBoundaryForCivilDate(d, Number(d.slice(0, 4)), dueDates).inChangeover;
  // Boundary values on both sides of the close, plus the open — an off-by-one in
  // the comparison shows up here rather than at the extremes.
  assert.equal(at('2026-01-01'), true, 'Jan 1 is inside the window');
  assert.equal(at('2026-01-14'), true, 'the day before the due date is inside');
  assert.equal(at('2026-01-15'), false, 'the due date itself closes the window');
  assert.equal(at('2026-01-16'), false, 'the day after is outside');
  assert.equal(at('2026-06-01'), false, 'mid-year is outside');
  assert.equal(at('2025-12-31'), false, 'the last day of the old year is outside');
});

test('AC#5 an override pinning a DIFFERENT year is a single-year run, not a changeover', () => {
  const profile = loadFixtureProfile();
  const dueDates = dueDatesOf(profile);
  // Jan 5 2026 with tax_year pinned to 2025: the user asked for the prior year
  // outright, so there is nothing to run alongside it.
  const pinned = resolveYearBoundary('2026-01-05', 'UTC', dueDates, 2025);
  assert.equal(pinned.taxYear, 2025);
  assert.equal(pinned.inChangeover, false);
  assert.equal(pinned.priorTaxYear, null);
  assert.equal(pinned.changeoverThrough, null);
  assert.equal(pinned.headerLabel, 'Tax Year 2025');
});

test('AC#5 a schedule with no wrapping quarter yields no changeover', () => {
  const inYear = [
    { quarter: 1, month: 3, day: 31 },
    { quarter: 2, month: 6, day: 30 },
    { quarter: 3, month: 9, day: 30 },
    { quarter: 4, month: 12, day: 31 },
  ];
  const boundary = yearBoundaryForCivilDate('2026-01-05', 2026, inYear);
  assert.equal(boundary.inChangeover, false);
  assert.equal(boundary.headerLabel, 'Tax Year 2026');
});

test('AC#5 an EMPTY schedule fails closed instead of answering "no changeover"', () => {
  // Without a schedule the window cannot be located, and a false answer would be
  // indistinguishable from a real one.
  for (const empty of [[], undefined, null, [{ quarter: 4 }]]) {
    assert.throws(
      () => yearBoundaryForCivilDate('2026-01-05', 2026, empty),
      /requires the profile quarterly due-date schedule/,
      `expected a throw for schedule ${JSON.stringify(empty)}`,
    );
  }
});

// --- AC #5 / #7: what computeTaxSummary emits -------------------------------

const CLOSE_LINES = [{ taxLineId: 'schedC.1', label: 'Gross receipts', category: 'income', amount: 90000 }];
const OPENING_LINES = [{ taxLineId: 'schedC.1', label: 'Gross receipts', category: 'income', amount: 1000 }];

test('AC#5 a changeover review without prior-year figures is refused', () => {
  const profile = loadFixtureProfile();
  assert.throws(
    () =>
      computeTaxSummary(profile, {
        timezone: 'America/Phoenix',
        filingStatus: 'single',
        asOfDate: '2026-01-05',
        scheduleCLines: OPENING_LINES,
      }),
    /requires ytdData\.priorYearClose/,
  );
  // …and a malformed one is refused just as loudly, rather than falling through to
  // a report that looks complete while hiding a whole tax year.
  for (const bad of [null, 'last year', [], { scheduleCLines: CLOSE_LINES }, { asOfDate: '2025-13-45' }]) {
    assert.throws(
      () =>
        computeTaxSummary(profile, {
          timezone: 'America/Phoenix',
          filingStatus: 'single',
          asOfDate: '2026-01-05',
          scheduleCLines: OPENING_LINES,
          priorYearClose: bad,
        }),
      /priorYearClose/,
      `expected a throw for priorYearClose=${JSON.stringify(bad)}`,
    );
  }
});

test('AC#5 a changeover review carries the prior year close AND the new year opening', () => {
  const profile = loadFixtureProfile();
  const summary = computeTaxSummary(profile, {
    timezone: 'America/Phoenix',
    filingStatus: 'single',
    asOfDate: '2026-01-05',
    scheduleCLines: OPENING_LINES,
    priorYearClose: { asOfDate: '2025-12-31', scheduleCLines: CLOSE_LINES },
  });

  // The summary body IS the new year's opening state…
  assert.equal(summary.meta.taxYear, 2026);
  assert.equal(summary.scheduleC.grossIncome, 1000);

  // …and the prior year's close-out rides alongside it, in the same shape, with
  // its own figures and its own tax year — not a copy of the opening numbers.
  const close = summary.yearBoundary.priorYearClose;
  assert.equal(summary.yearBoundary.inChangeover, true);
  assert.equal(close.meta.taxYear, 2025);
  assert.equal(close.meta.asOfDate, '2025-12-31');
  assert.equal(close.scheduleC.grossIncome, 90000);
  assert.equal(close.scheduleC.netProfit, 90000);
  // The close carries the full Schedule C / A / SE set the AC names.
  assert.equal(typeof close.scheduleA.standardDeduction, 'number');
  assert.equal(close.seTax.scheduleCNet, 90000);
  assert.ok(close.seTax.amount > 0, 'the close-out computes SE tax on its own net profit');
  // The prior year's standard deduction is read for ITS year, not the new one.
  assert.equal(close.scheduleA.standardDeduction, profile.getStandardDeduction(2025, 'single') ?? 0);
});

test('AC#7 the resolved tax year reaches the report header, naming both years in the window', () => {
  const profile = loadFixtureProfile();
  const midYear = computeTaxSummary(profile, {
    timezone: 'America/Phoenix',
    filingStatus: 'single',
    asOfDate: '2025-05-01',
  });
  assert.equal(midYear.meta.taxYearLabel, 'Tax Year 2025');
  assert.equal(midYear.yearBoundary.inChangeover, false);
  assert.equal(midYear.yearBoundary.priorYearClose, null);

  const changeover = computeTaxSummary(profile, {
    timezone: 'America/Phoenix',
    filingStatus: 'single',
    asOfDate: '2026-01-05',
    priorYearClose: { asOfDate: '2025-12-31' },
  });
  assert.equal(changeover.meta.taxYearLabel, 'Tax Year 2026 (2025 close-out through 2026-01-15)');
  // The changeover signal names BOTH years, so a reader can never mistake which
  // set of figures they are looking at.
  assert.match(changeover.meta.taxYearLabel, /2025/);
  assert.match(changeover.meta.taxYearLabel, /2026/);
});
