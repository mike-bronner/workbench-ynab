// tests/unit/estimated-tax-reminder.test.mjs — unit tests for the quarterly
// estimated-tax reminder detector (lib/tax/estimatedTaxReminder.mjs, issue #83 /
// M6-5).
//
// Runs under the built-in node:test runner with NO node_modules present (only
// node: built-ins and repo-local files), per docs/testing.md. The detector is a
// PURE function over plain objects — no filesystem, no YNAB — so every test feeds
// it literals.
//
// Covers the AC #11 matrix — lead-time fires at T-7, NOT at T-8, due-day escalates
// to 🔴 when unpaid, suppression when a payment is recorded, and the enabled
// switch — plus the rendering contract (AC #7: quarter label, due date,
// remaining-due, recommended payment), the escalation boundary, the after-due
// no-fire, the fail-closed handling of malformed dates, the distinct lead/due
// dedupe keys, and the byte-for-byte not-tax-advice tag.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { ACTION, ATTENTION } from '../../lib/monitor/alerts.mjs';
import {
  REMINDER_TYPE,
  DISCLAIMER_TAG,
  calendarDaysBetween,
  computeQuarterlyTaxReminders,
  resolveCandidateDueDates,
} from '../../lib/tax/estimatedTaxReminder.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

// A Q3 2026 due date (Apr15/Jun15/Sep15/Jan15 come from the tax profile; here we
// hand the resolved value in exactly as the review router would).
const Q3 = { quarter: 3, date: '2026-09-15', taxYear: 2026 };

// A tracker with a Q3 2026 estimate and NO payment recorded (the firing state).
const trackerUnpaid = {
  schemaVersion: 1,
  years: { 2026: { 3: { estimated_liability: 1200, payments: [], remaining_due: 1200 } } },
};
// Same, but PAID IN FULL against Q3 (remaining_due 0) → suppression.
const trackerPaid = {
  schemaVersion: 1,
  years: {
    2026: {
      3: {
        estimated_liability: 1200,
        payments: [{ date: '2026-09-10', amount_usd: 1200, ynab_transaction_id: 't-1' }],
        remaining_due: 0,
      },
    },
  },
};
// A PARTIAL payment: ≥1 payment recorded but remaining_due > 0. Suppression must
// STILL fire — AC #8 is "at least one payment recorded", NOT "paid in full". This
// fixture pins hasRecordedPayment's `payments.length >= 1` semantics: swap the impl
// to a `remaining_due <= 0` check and this quarter would (wrongly) fire, going red.
const trackerPartiallyPaid = {
  schemaVersion: 1,
  years: {
    2026: {
      3: {
        estimated_liability: 1200,
        payments: [{ date: '2026-09-10', amount_usd: 500, ynab_transaction_id: 't-1' }],
        remaining_due: 700,
      },
    },
  },
};

const base = { dueDates: [Q3], tracker: trackerUnpaid, leadTimeDays: 7, remindersEnabled: true };

// --- AC #11: the trigger matrix ---------------------------------------------

test('lead-time reminder FIRES at T-7 (7 days before the due date) as 🟡 attention', () => {
  const findings = computeQuarterlyTaxReminders({ ...base, today: '2026-09-08' });
  assert.equal(findings.length, 1);
  assert.equal(findings[0].severity, ATTENTION);
});

test('lead-time reminder does NOT fire at T-8 (one day before the window opens)', () => {
  const findings = computeQuarterlyTaxReminders({ ...base, today: '2026-09-07' });
  assert.deepEqual(findings, []);
});

test('due-day reminder escalates to 🔴 action when no payment is recorded', () => {
  const findings = computeQuarterlyTaxReminders({ ...base, today: '2026-09-15' });
  assert.equal(findings.length, 1);
  assert.equal(findings[0].severity, ACTION);
});

test('suppression: no reminder fires for a quarter once a payment is recorded', () => {
  // In the lead-time window AND on the due date, a recorded payment suppresses.
  for (const today of ['2026-09-08', '2026-09-15']) {
    const findings = computeQuarterlyTaxReminders({ ...base, tracker: trackerPaid, today });
    assert.deepEqual(findings, [], `expected suppression on ${today}`);
  }
});

test('suppression pins "≥1 payment recorded" (AC #8), NOT "paid in full": a partial payment still suppresses', () => {
  // trackerPartiallyPaid has one payment but remaining_due > 0. AC #8 suppresses on
  // "at least one payment recorded", so this must fire nothing on both the lead-time
  // and due-day paths — locking hasRecordedPayment against a remaining_due<=0 reading
  // that the paid-in-full fixture (remaining_due 0) alone can't distinguish.
  for (const today of ['2026-09-08', '2026-09-15']) {
    const findings = computeQuarterlyTaxReminders({ ...base, tracker: trackerPartiallyPaid, today });
    assert.deepEqual(findings, [], `partial payment must still suppress on ${today}`);
  }
});

test('the enabled switch: reminders_enabled=false fires nothing, even on the due date', () => {
  for (const today of ['2026-09-08', '2026-09-15']) {
    const findings = computeQuarterlyTaxReminders({ ...base, remindersEnabled: false, today });
    assert.deepEqual(findings, []);
  }
});

// --- Window boundaries -------------------------------------------------------

test('fires across the whole lead window (T-1) and NOT the day after the due date', () => {
  assert.equal(computeQuarterlyTaxReminders({ ...base, today: '2026-09-14' }).length, 1);
  assert.deepEqual(computeQuarterlyTaxReminders({ ...base, today: '2026-09-16' }), []);
});

test('lead time is honoured: leadTimeDays=0 fires only on the due date', () => {
  assert.deepEqual(computeQuarterlyTaxReminders({ ...base, leadTimeDays: 0, today: '2026-09-14' }), []);
  assert.equal(computeQuarterlyTaxReminders({ ...base, leadTimeDays: 0, today: '2026-09-15' }).length, 1);
});

// --- AC #7: rendering content ------------------------------------------------

test('rendering includes the quarter label, due date, remaining-due, and recommended payment', () => {
  const [f] = computeQuarterlyTaxReminders({ ...base, today: '2026-09-08' });
  assert.match(f.title, /Q3 2026/);
  assert.match(f.title, /2026-09-15/);
  assert.match(f.suggested_action, /Remaining due \$1200\.00/);
  assert.match(f.suggested_action, /recommended payment \$1200\.00/i);
});

test('every finding carries the canonical not-tax-advice tag, byte-for-byte', () => {
  const [f] = computeQuarterlyTaxReminders({ ...base, today: '2026-09-08' });
  assert.ok(f.suggested_action.includes(DISCLAIMER_TAG));
  // The tag must match the single source of truth (skills/shared/disclaimer.md)
  // exactly — a doc-drift guard so a reworded disclaimer can't slip through.
  const disclaimerDoc = readFileSync(join(ROOT, 'skills', 'shared', 'disclaimer.md'), 'utf8');
  assert.ok(
    disclaimerDoc.includes(DISCLAIMER_TAG),
    'DISCLAIMER_TAG must appear verbatim in skills/shared/disclaimer.md',
  );
});

test('an unpaid firing finding reports the M6-2 contract fields on BOTH the due-day and lead-time paths', () => {
  const KEYS = ['dedupe_key', 'detail', 'severity', 'suggested_action', 'title'];
  const due = computeQuarterlyTaxReminders({ ...base, today: '2026-09-15' })[0];
  assert.equal(due.severity, ACTION);
  assert.deepEqual(Object.keys(due).sort(), KEYS);
  assert.equal(typeof due.detail, 'string');
  assert.match(due.detail, /payment_recorded=false/);
  // Same full shape on the lead-time (ATTENTION) branch — a field dropped only on
  // that path would otherwise slip past a due-day-only assertion.
  const lead = computeQuarterlyTaxReminders({ ...base, today: '2026-09-08' })[0];
  assert.equal(lead.severity, ATTENTION);
  assert.deepEqual(Object.keys(lead).sort(), KEYS);
  assert.equal(typeof lead.detail, 'string');
  assert.match(lead.detail, /payment_recorded=false/);
});

test('lead-time and due-day findings carry DISTINCT dedupe keys (both can fire)', () => {
  const lead = computeQuarterlyTaxReminders({ ...base, today: '2026-09-08' })[0];
  const due = computeQuarterlyTaxReminders({ ...base, today: '2026-09-15' })[0];
  assert.equal(lead.dedupe_key, `${REMINDER_TYPE}:Q3-lead:2026`);
  assert.equal(due.dedupe_key, `${REMINDER_TYPE}:Q3-due:2026`);
  assert.notEqual(lead.dedupe_key, due.dedupe_key);
});

// --- Ordering: most urgent first ---------------------------------------------

test('findings come out most-urgent-first (ascending days-until-due), so the cap never drops the nearer one', () => {
  // Two quarters from different tax years, both inside a wide lead window, with the
  // FAR-OFF one listed first in dueDates. The detector must reorder so the nearer
  // due date leads — otherwise dispatchAlerts' MAX_FINDINGS cap (severity sort only,
  // input order within a severity) could drop the more urgent reminder.
  const dueDates = [
    { quarter: 1, date: '2027-04-15', taxYear: 2027 }, // 95 days away
    { quarter: 4, date: '2027-01-15', taxYear: 2026 }, //  5 days away
  ];
  const findings = computeQuarterlyTaxReminders({
    today: '2027-01-10', dueDates, tracker: null, leadTimeDays: 100, remindersEnabled: true,
  });
  assert.equal(findings.length, 2);
  assert.match(findings[0].title, /Q4 2026/); // nearer (5d) first
  assert.match(findings[1].title, /Q1 2027/); // farther (95d) second
});

// --- Robustness / fail-closed ------------------------------------------------

test('fails closed: an unparseable today or due date fires nothing (never a bogus nudge)', () => {
  assert.deepEqual(computeQuarterlyTaxReminders({ ...base, today: 'not-a-date' }), []);
  assert.deepEqual(
    computeQuarterlyTaxReminders({ ...base, dueDates: [{ quarter: 3, date: '2026-13-40', taxYear: 2026 }], today: '2026-09-15' }),
    [],
  );
});

test('a missing tracker still reminds (deadline matters) but points to /ynab-tax for the amount', () => {
  const [f] = computeQuarterlyTaxReminders({ ...base, tracker: null, today: '2026-09-15' });
  assert.equal(f.severity, ACTION);
  assert.match(f.suggested_action, /\/ynab-tax/);
  assert.match(f.detail, /remaining_due=unknown/);
});

test('malformed due-date entries are skipped, valid ones still fire', () => {
  const dueDates = [null, { quarter: 9, date: '2026-09-15', taxYear: 2026 }, Q3];
  const findings = computeQuarterlyTaxReminders({ ...base, dueDates, today: '2026-09-15' });
  assert.equal(findings.length, 1);
});

// --- calendarDaysBetween -----------------------------------------------------

test('calendarDaysBetween counts civil days and returns null on bad input', () => {
  assert.equal(calendarDaysBetween('2026-09-08', '2026-09-15'), 7);
  assert.equal(calendarDaysBetween('2026-09-15', '2026-09-15'), 0);
  assert.equal(calendarDaysBetween('2026-09-16', '2026-09-15'), -1);
  // Crosses a DST boundary in most US zones — civil-day math must be unaffected.
  assert.equal(calendarDaysBetween('2026-03-01', '2026-03-31'), 30);
  assert.equal(calendarDaysBetween('nope', '2026-09-15'), null);
});

// --- resolveCandidateDueDates (the January prior-year Q4 rollover) -----------

test('resolveCandidateDueDates surfaces the prior tax year Q4 for a January today', () => {
  // A stub loadProfile accessor: Q4 of tax year Y falls on Jan 15 of Y+1.
  const getQuarterlyDueDates = (y) => [
    { quarter: 1, date: `${y}-04-15` },
    { quarter: 2, date: `${y}-06-15` },
    { quarter: 3, date: `${y}-09-15` },
    { quarter: 4, date: `${y + 1}-01-15` },
  ];
  const candidates = resolveCandidateDueDates(getQuarterlyDueDates, 2027);
  // The 2026 tax year's Q4 (due 2027-01-15) must be present with taxYear 2026.
  const priorQ4 = candidates.find((c) => c.date === '2027-01-15');
  assert.ok(priorQ4, 'prior tax year Q4 due 2027-01-15 should be a candidate');
  assert.equal(priorQ4.taxYear, 2026);
  assert.equal(priorQ4.quarter, 4);

  // Wired end-to-end: on Jan 10 2027, that Q4 reminder fires as a lead-time nudge.
  const findings = computeQuarterlyTaxReminders({
    today: '2027-01-10',
    dueDates: candidates,
    tracker: null,
    leadTimeDays: 7,
    remindersEnabled: true,
  });
  assert.equal(findings.length, 1);
  assert.match(findings[0].title, /Q4 2026/);
});

test('resolveCandidateDueDates is total over bad input', () => {
  assert.deepEqual(resolveCandidateDueDates(null, 2027), []);
  assert.deepEqual(resolveCandidateDueDates(() => [], 'nope'), []);
});
