// tests/unit/monitor-detectors.test.mjs — unit tests for the four between-run
// alert detectors + ledger reconciliation (lib/monitor/detectors.mjs, issue #81
// / M6-3).
//
// Runs under the built-in node:test runner with NO node_modules present (only
// node: built-ins and repo-local files are imported), per docs/testing.md. The
// detectors are pure — they take already-fetched YNAB data + the loaded alerts
// config and return findings — so every case is a fixture, no IO, no MCP.
//
// Covers the AC test matrix per detector: the fire boundary and the NON-fire
// just past it (so a `>=`→`>` or `||`→`&&` regression goes red), the exclusions
// (off-budget / closed / hidden / no-budget / config-off), the exact dedupe_key
// shape, milliunit→dollar display, the 🔴 hard-ceiling upgrade, and the ledger
// reconcile (dispatch-once, expire-on-clear, point-event persistence) — plus the
// stdout discipline.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

import { ACTION, ATTENTION, sanitizeAlertsConfig } from '../../lib/monitor/alerts.mjs';
import { defaultState } from '../../lib/monitor/state.mjs';
import {
  TRAILING_WINDOW,
  HARD_CEILING_MULTIPLE,
  EXPIRING_TYPES,
  detectOverdrawn,
  detectLargeUnusualTransactions,
  detectBudgetOverrun,
  detectBillsDue,
  reconcileFindings,
} from '../../lib/monitor/detectors.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const MODULE_PATH = join(ROOT, 'lib', 'monitor', 'detectors.mjs');

// The zero-config defaults, in the loaded (milliunits) shape the detectors read:
// large=500000 mu ($500), unusual×3, overrun 100%, lookahead 3 days, overdrawn on.
const CONFIG = sanitizeAlertsConfig({});

// Every finding must carry exactly the M6-2 contract fields.
const CONTRACT_FIELDS = ['severity', 'title', 'detail', 'suggested_action', 'dedupe_key'];
const assertContract = (f) => assert.deepEqual(Object.keys(f).sort(), [...CONTRACT_FIELDS].sort());

// --- Detector 1: overdrawn ----------------------------------------------------

test('overdrawn: an on-budget account below the floor fires 🔴 with overdrawn:{id}', () => {
  const findings = detectOverdrawn([
    { id: 'a1', name: 'Checking', balance: -50000, on_budget: true, closed: false, deleted: false },
  ], CONFIG);
  assert.equal(findings.length, 1);
  assertContract(findings[0]);
  assert.equal(findings[0].severity, ACTION);
  assert.equal(findings[0].dedupe_key, 'overdrawn:a1');
  assert.match(findings[0].title, /Checking/);
  assert.match(findings[0].title, /\$50\.00/, 'milliunits are converted to whole dollars in the finding');
});

test('overdrawn: a balance AT the floor (0) and above does NOT fire', () => {
  const at = detectOverdrawn([{ id: 'a1', balance: 0, on_budget: true }], CONFIG);
  const above = detectOverdrawn([{ id: 'a2', balance: 100000, on_budget: true }], CONFIG);
  assert.deepEqual([at.length, above.length], [0, 0], 'the floor is exclusive of 0 — only a NEGATIVE balance is overdrawn');
});

test('overdrawn: off-budget, closed, and deleted accounts are excluded', () => {
  const findings = detectOverdrawn([
    { id: 'off', balance: -1, on_budget: false },
    { id: 'closed', balance: -1, on_budget: true, closed: true },
    { id: 'deleted', balance: -1, on_budget: true, deleted: true },
  ], CONFIG);
  assert.deepEqual(findings, [], 'only on-budget, open, live accounts are eligible');
});

test('overdrawn: config.overdrawn=false disables the detector entirely', () => {
  const off = sanitizeAlertsConfig({ overdrawn: false });
  assert.deepEqual(detectOverdrawn([{ id: 'a1', balance: -1, on_budget: true }], off), []);
});

test('overdrawn: a malformed account (no id / non-numeric balance) is skipped, never thrown', () => {
  const findings = detectOverdrawn([
    null,
    { balance: -1, on_budget: true }, // no id
    { id: 'a1', balance: 'lots', on_budget: true }, // non-numeric balance
    { id: 'a2', balance: -5000, on_budget: true }, // the one real hit
  ], CONFIG);
  assert.deepEqual(findings.map((f) => f.dedupe_key), ['overdrawn:a2']);
});

// --- Detector 2: large / unusual transaction ----------------------------------

test('large txn: an amount at/over the threshold fires 🟡 with large_txn:{id}', () => {
  const findings = detectLargeUnusualTransactions(
    [{ id: 't1', amount: -600000, payee_name: 'Big Store', category_id: 'c1' }], {}, CONFIG,
  );
  assert.equal(findings.length, 1);
  assertContract(findings[0]);
  assert.equal(findings[0].severity, ATTENTION);
  assert.equal(findings[0].dedupe_key, 'large_txn:t1');
  assert.match(findings[0].title, /\$600\.00/);
});

test('large txn: below the threshold and not unusual does NOT fire', () => {
  const findings = detectLargeUnusualTransactions(
    [{ id: 't1', amount: -50000, category_id: 'c1' }], { c1: [40000, 60000] }, CONFIG,
  );
  assert.deepEqual(findings, [], '$50 < $500 large threshold and 50000 < 3×50000 mean → nothing');
});

test('large txn: exactly AT the base threshold fires; one milliunit under is silent (base check is >=)', () => {
  // Pins the base "large" boundary directly (== threshold and == threshold-1),
  // so a >=→> regression on the base magnitude check goes red. The base check is
  // INCLUSIVE: the user-facing config docs (docs/alerts-config.md,
  // docs/config-schema.md) both define it as "at or above". No history → not
  // "unusual", so only the base magnitude check is in play. CONFIG large = 500000 mu.
  const at = detectLargeUnusualTransactions([{ id: 't1', amount: -500000, category_id: 'c1' }], {}, CONFIG);
  const under = detectLargeUnusualTransactions([{ id: 't2', amount: -499999, category_id: 'c1' }], {}, CONFIG);
  assert.deepEqual([at.length, under.length], [1, 0], '500000 == threshold fires; 499999 == threshold-1 stays silent');
});

test('unusual txn: over unusual_multiplier × the trailing mean fires even when small', () => {
  // $90, well under the $500 large threshold, but 4.5× the $20 category mean.
  const findings = detectLargeUnusualTransactions(
    [{ id: 't1', amount: -90000, payee_name: 'Corner', category_id: 'c1', category_name: 'Coffee' }],
    { c1: [20000, 20000, 20000] }, CONFIG,
  );
  assert.equal(findings.length, 1);
  assert.equal(findings[0].severity, ATTENTION);
  assert.match(findings[0].title, /Unusual/);
  assert.match(findings[0].title, /4\.5×/, 'the multiple over typical is shown');
});

test('unusual txn: exactly AT the multiplier does not fire (strictly greater)', () => {
  // 60000 == 3 × 20000 — the boundary is exclusive, so this must stay silent.
  const findings = detectLargeUnusualTransactions(
    [{ id: 't1', amount: -60000, category_id: 'c1' }], { c1: [20000] }, CONFIG,
  );
  assert.deepEqual(findings, [], 'amount == multiplier × mean is not "unusual"');
});

test('unusual txn: a category with no history (or zero mean) gets the large check only', () => {
  const noHistory = detectLargeUnusualTransactions([{ id: 't1', amount: -90000, category_id: 'c1' }], {}, CONFIG);
  const zeroMean = detectLargeUnusualTransactions([{ id: 't2', amount: -90000, category_id: 'c1' }], { c1: [0, 0] }, CONFIG);
  assert.deepEqual([noHistory, zeroMean], [[], []], 'no trailing mean → no unusual signal, and $90 is not large');
});

test('large txn: a transaction with no category_id still gets the large check', () => {
  const findings = detectLargeUnusualTransactions([{ id: 't1', amount: -700000 }], {}, CONFIG);
  assert.equal(findings.length, 1, 'no category is fine for the amount-based large check');
  assert.equal(findings[0].dedupe_key, 'large_txn:t1');
});

test(`large txn: at ${HARD_CEILING_MULTIPLE}× the threshold the severity upgrades to 🔴`, () => {
  const below = detectLargeUnusualTransactions([{ id: 't1', amount: -(HARD_CEILING_MULTIPLE * 500000 - 1), category_id: 'c1' }], {}, CONFIG);
  const at = detectLargeUnusualTransactions([{ id: 't2', amount: -(HARD_CEILING_MULTIPLE * 500000), category_id: 'c1' }], {}, CONFIG);
  assert.equal(below[0].severity, ATTENTION, 'just under the ceiling stays 🟡');
  assert.equal(at[0].severity, ACTION, 'at/over the ceiling is 🔴');
});

test('large txn: magnitude is compared, so a large OUTFLOW (negative) fires', () => {
  // Guards against dropping Math.abs — a -600000 outflow must not read as "< threshold".
  const findings = detectLargeUnusualTransactions([{ id: 't1', amount: -600000, category_id: 'c1' }], {}, CONFIG);
  assert.equal(findings.length, 1);
});

test('large txn: a malformed transaction (null / no id / non-numeric amount) is skipped, never thrown', () => {
  const findings = detectLargeUnusualTransactions([
    null,
    { amount: -600000 }, // no id
    { id: 't1', amount: 'lots' }, // non-numeric amount
    { id: 't2', amount: -600000 }, // the one real hit
  ], {}, CONFIG);
  assert.deepEqual(findings.map((f) => f.dedupe_key), ['large_txn:t2']);
});

// --- Detector 3: budget overrun -----------------------------------------------

test('budget overrun: a category at/over the pct fires 🟡 with budget_overrun:{id}:{YYYY-MM}', () => {
  const findings = detectBudgetOverrun(
    [{ id: 'c1', name: 'Groceries', budgeted: 100000, activity: -100000 }], CONFIG, { month: '2026-07' },
  );
  assert.equal(findings.length, 1);
  assertContract(findings[0]);
  assert.equal(findings[0].severity, ATTENTION);
  assert.equal(findings[0].dedupe_key, 'budget_overrun:c1:2026-07');
  assert.match(findings[0].title, /100%/);
});

test('budget overrun: below the pct does NOT fire (boundary is inclusive of pct)', () => {
  const below = detectBudgetOverrun([{ id: 'c1', budgeted: 100000, activity: -99999 }], CONFIG, { month: '2026-07' });
  const at = detectBudgetOverrun([{ id: 'c1', budgeted: 100000, activity: -100000 }], CONFIG, { month: '2026-07' });
  assert.deepEqual([below.length, at.length], [0, 1], '99.999% stays silent; exactly 100% fires');
});

test('budget overrun: a category with no positive budget is skipped (no divide-by-zero ratio)', () => {
  const findings = detectBudgetOverrun([
    { id: 'z', budgeted: 0, activity: -5000 },
    { id: 'n', budgeted: -100, activity: -5000 },
  ], CONFIG, { month: '2026-07' });
  assert.deepEqual(findings, [], 'an overrun percentage is undefined without a budget to divide by');
});

test('budget overrun: hidden/deleted categories and pure inflow are excluded', () => {
  const findings = detectBudgetOverrun([
    { id: 'h', budgeted: 100000, activity: -200000, hidden: true },
    { id: 'd', budgeted: 100000, activity: -200000, deleted: true },
    { id: 'in', budgeted: 100000, activity: 50000 }, // inflow, no spend
  ], CONFIG, { month: '2026-07' });
  assert.deepEqual(findings, []);
});

test('budget overrun: without a month the detector returns nothing (the dedupe period is required)', () => {
  assert.deepEqual(detectBudgetOverrun([{ id: 'c1', budgeted: 100000, activity: -200000 }], CONFIG, {}), []);
});

test('budget overrun: a malformed category (null / no id) is skipped, never thrown', () => {
  const findings = detectBudgetOverrun([
    null,
    { budgeted: 100000, activity: -200000 }, // no id
    { id: 'c1', budgeted: 100000, activity: -200000 }, // the one real hit
  ], CONFIG, { month: '2026-07' });
  assert.deepEqual(findings.map((f) => f.dedupe_key), ['budget_overrun:c1:2026-07']);
});

// --- Detector 4: bill due -----------------------------------------------------

const NOW = '2026-07-22T09:00:00Z';

test('bill due: a bill within the lookahead fires 🟡 with bill_due:{id}:{due_date}', () => {
  const findings = detectBillsDue(
    [{ id: 'b1', name: 'Rent', date: '2026-07-24', amount: -1500000 }], CONFIG, { now: NOW },
  );
  assert.equal(findings.length, 1);
  assertContract(findings[0]);
  assert.equal(findings[0].severity, ATTENTION);
  assert.equal(findings[0].dedupe_key, 'bill_due:b1:2026-07-24');
  assert.match(findings[0].title, /Rent/);
});

test('bill due: the lookahead boundary fires, one day past it does not', () => {
  // Default lookahead is 3 days from 2026-07-22 → 07-25 inclusive, 07-26 excluded.
  const atEdge = detectBillsDue([{ id: 'b1', date: '2026-07-25' }], CONFIG, { now: NOW });
  const past = detectBillsDue([{ id: 'b2', date: '2026-07-26' }], CONFIG, { now: NOW });
  assert.deepEqual([atEdge.length, past.length], [1, 0], 'day == lookahead fires; day > lookahead is silent');
});

test('bill due: an already-past bill is not "upcoming" and does not fire', () => {
  assert.deepEqual(detectBillsDue([{ id: 'b1', date: '2026-07-21' }], CONFIG, { now: NOW }), []);
});

test('bill due: lookahead 0 flags only bills due today', () => {
  const cfg = sanitizeAlertsConfig({ bill_due_lookahead_days: 0 });
  const today = detectBillsDue([{ id: 'b1', date: '2026-07-22' }], cfg, { now: NOW });
  const tomorrow = detectBillsDue([{ id: 'b2', date: '2026-07-23' }], cfg, { now: NOW });
  assert.deepEqual([today.length, tomorrow.length], [1, 0]);
});

test('bill due: a malformed date is skipped, never treated as due-now', () => {
  const findings = detectBillsDue([
    { id: 'bad', date: 'not-a-date' },
    { id: 'ok', date: '2026-07-22' },
  ], CONFIG, { now: NOW });
  assert.deepEqual(findings.map((f) => f.dedupe_key), ['bill_due:ok:2026-07-22']);
});

test('bill due: a calendar-invalid or truncated date is skipped, never rolled over into a false fire', () => {
  // Date.parse silently ROLLS OVER a day-overflow (2026-02-30 → 03-02) and a
  // truncated string (2026-03 → 03-01) — exactly the GAP-3 "30th/31st" bills
  // derived in a short month. `now` is anchored to 2026-03-01 so BOTH rolled dates
  // land INSIDE the 3-day lookahead: without the round-trip guard each would fire
  // on an impossible/wrong day and bake it into the dedupe key (a 02-30 key vs a
  // later 03-02 key = double-alert). Only daysUntil's round-trip check stops them,
  // so this discriminates that guard (not the lookahead window).
  const findings = detectBillsDue([
    { id: 'rollover', name: 'Rent', date: '2026-02-30' }, // no February 30th → rolls to 03-02 (1 day out)
    { id: 'truncated', name: 'Rent', date: '2026-03' }, // truncated YYYY-MM → rolls to 03-01 (0 days out)
    { id: 'ok', date: '2026-03-02' }, // the one real hit (1 day out)
  ], CONFIG, { now: '2026-03-01T09:00:00Z' });
  assert.deepEqual(findings.map((f) => f.dedupe_key), ['bill_due:ok:2026-03-02']);
});

test('bill due: a malformed bill (null / no id / non-string date) is skipped, never thrown', () => {
  const findings = detectBillsDue([
    null,
    { date: '2026-07-24' }, // no id
    { id: 'b1', date: 12345 }, // non-string date
    { id: 'b2', date: '2026-07-24' }, // the one real hit
  ], CONFIG, { now: NOW });
  assert.deepEqual(findings.map((f) => f.dedupe_key), ['bill_due:b2:2026-07-24']);
});

// --- Ledger reconciliation ----------------------------------------------------

test('reconcileFindings: dispatch a NEW condition once, expire a CLEARED one, keep point-events', () => {
  const prior = {
    ...defaultState(),
    firedAlerts: {
      'overdrawn:a1': { at: 'old' }, // still active this pass
      'large_txn:t1': { at: 'old' }, // point event, not in this pass's window
      'budget_overrun:c1:2026-07': { at: 'old' }, // CLEARED this pass
    },
  };
  const findings = [
    { severity: ACTION, title: '', detail: '', suggested_action: '', dedupe_key: 'overdrawn:a1' }, // already announced
    { severity: ACTION, title: '', detail: '', suggested_action: '', dedupe_key: 'overdrawn:a2' }, // NEW
  ];
  const { state, toDispatch, expired } = reconcileFindings(prior, findings, { now: 'NOW' });

  assert.deepEqual(toDispatch.map((f) => f.dedupe_key), ['overdrawn:a2'],
    'a still-true condition already in the ledger is NOT re-dispatched; only the new one is');
  assert.deepEqual(expired, ['budget_overrun:c1:2026-07'], 'the cleared expiring-type key is dropped');
  assert.deepEqual(state.firedAlerts, {
    'overdrawn:a1': { at: 'old' }, // preserved with its ORIGINAL payload (skip-existing)
    'large_txn:t1': { at: 'old' }, // point event survives even though absent from the active set
    'overdrawn:a2': { at: 'NOW' }, // newly recorded with the pass timestamp
  });
  assert.equal(prior.firedAlerts['overdrawn:a2'], undefined, 'the input ledger is never mutated');
});

test('reconcileFindings: an empty pass expires nothing that stays active and dispatches nothing new', () => {
  const prior = { ...defaultState(), firedAlerts: { 'overdrawn:a1': { at: 'old' } } };
  // a1 still overdrawn this pass → active, so it must NOT be expired.
  const { state, toDispatch } = reconcileFindings(prior, [
    { severity: ACTION, title: '', detail: '', suggested_action: '', dedupe_key: 'overdrawn:a1' },
  ], { now: 'NOW' });
  assert.deepEqual(toDispatch, [], 'nothing new to announce');
  assert.deepEqual(state.firedAlerts, { 'overdrawn:a1': { at: 'old' } }, 'the still-active key is retained untouched');
});

test('EXPIRING_TYPES excludes large_txn (point events never auto-expire)', () => {
  assert.ok(!EXPIRING_TYPES.includes('large_txn'));
  assert.deepEqual([...EXPIRING_TYPES].sort(), ['bill_due', 'budget_overrun', 'overdrawn']);
});

test('reconcileFindings: options.expiringTypes narrows expiry so a skipped detector keeps its keys', () => {
  // The documented partial-failure seam: a caller that skipped a full-domain
  // detector (e.g. the accounts fetch failed) narrows expiringTypes to only the
  // domains it re-evaluated, so it never expires a domain it couldn't attest as
  // cleared. Both keys are absent from this (empty) pass, so only the difference
  // in expiringTypes decides which survives.
  const prior = {
    ...defaultState(),
    firedAlerts: {
      'overdrawn:a1': { at: 'old' }, // NOT re-evaluated this pass
      'budget_overrun:c1:2026-07': { at: 'old' }, // WAS re-evaluated this pass
    },
  };
  const { state, expired } = reconcileFindings(prior, [], {
    now: 'NOW', expiringTypes: ['budget_overrun', 'bill_due'],
  });
  assert.deepEqual(expired, ['budget_overrun:c1:2026-07'], 'only a domain listed in expiringTypes may expire');
  assert.deepEqual(state.firedAlerts, { 'overdrawn:a1': { at: 'old' } },
    'the un-re-evaluated overdrawn key survives because overdrawn is outside expiringTypes');
});

test('TRAILING_WINDOW caps the unusual mean at the last N same-category transactions', () => {
  // 11 priors: ten 10000s then one huge 10_000_000. With N=10 the huge one is
  // OUTSIDE the window, so the mean is 10000 and a 40000 txn (4× mean) is unusual.
  // If the window were unbounded, the huge prior would swamp the mean and hide it.
  const priors = [...Array(TRAILING_WINDOW).fill(10000), 10_000_000];
  const findings = detectLargeUnusualTransactions([{ id: 't1', amount: -40000, category_id: 'c1' }], { c1: priors }, CONFIG);
  assert.equal(findings.length, 1, 'only the last N priors define "typical"');
});

// --- stdout discipline (safe on an MCP / JSON-RPC path) -----------------------

test('the module writes nothing to stdout', () => {
  const url = pathToFileURL(MODULE_PATH).href;
  const script = `
    import(${JSON.stringify(url)}).then((m) => {
      m.detectOverdrawn([{ id: 'a', balance: -1, on_budget: true }], { overdrawn: true });
      m.detectLargeUnusualTransactions([{ id: 't', amount: -999999, category_id: 'c' }], { c: [1] }, { largeTransactionMilliunits: 1, unusualMultiplier: 3 });
      m.detectBudgetOverrun([{ id: 'c', budgeted: 1, activity: -2 }], { budgetOverrunPct: 100 }, { month: '2026-07' });
      m.detectBillsDue([{ id: 'b', date: '2026-07-22' }], { billDueLookaheadDays: 3 }, { now: '2026-07-22T00:00:00Z' });
      m.reconcileFindings({ firedAlerts: {} }, [], { now: 't' });
      process.stderr.write('ok');
    });
  `;
  const res = spawnSync(process.execPath, ['-e', script], { encoding: 'utf8' });
  assert.equal(res.status, 0, res.stderr);
  assert.equal(res.stdout, '', `expected empty stdout, got: ${JSON.stringify(res.stdout)}`);
  assert.equal(res.stderr, 'ok');
});
