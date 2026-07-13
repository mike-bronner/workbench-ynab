// tests/unit/tax-engine.test.mjs — CONTRACT test for the tax-engine facade
// (lib/tax/index.mjs, issue #27 / M3-8).
//
// Runs under the built-in node:test runner with NO node_modules present (only
// node: built-ins and repo-local files), per docs/testing.md. This is the
// composition-level contract test the issue asks for: it exercises ALL FOUR
// exported functions end-to-end against an anonymized fixture profile (the
// bundled US defaults — no PII) plus fixture transactions, and confirms the
// return shapes match the documented @typedefs. The underlying tax math is
// already unit-tested in load-profile / classify-transaction / estimated-tax;
// here we assert the FACADE's contract, not re-test the primitives.
//
// Covers the issue AC: exactly four named exports and no more (AC #1); each
// export delegates and returns the documented shape (AC #2–#6, #10); batch
// preserves order and shape (AC #4); computeTaxSummary composes the five
// Section-12 fragments with profile-supplied rates (AC #5); and the facade
// writes nothing to stdout (AC #11).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import * as engine from '../../lib/tax/index.mjs';
import {
  loadEffectiveProfile,
  classifyTransaction,
  classifyBatch,
  computeTaxSummary,
} from '../../lib/tax/index.mjs';
import { selfEmploymentTax, computeEstimate, quarterlyEstimate } from '../../lib/tax/estimatedTax.mjs';

// An ABSENT user profile → the loader resolves the bundled US defaults only: a
// realistic, fully-anonymized fixture profile with real thresholds/brackets/due
// dates and zero PII.
const TMP = mkdtempSync(join(tmpdir(), 'ynab-tax-engine-'));
const ABSENT = join(TMP, 'no-such-profile.json');

function loadFixtureProfile() {
  const profile = loadEffectiveProfile({ profilePath: ABSENT });
  assert.equal(profile.ok, true, 'fixture profile should load cleanly from defaults');
  return profile;
}

// A developer-tools SaaS outflow (GitHub) that the bundled mapping rules classify
// to Schedule C other expenses (schedC.27a). Amounts are YNAB MILLIUNITS.
const GITHUB_TXN = { payee_name: 'GitHub', amount: -9000, date: '2025-04-02' };
const RENT_INCOME_TXN = { payee_name: 'Freelance Client', category_group_name: 'Business Income', amount: 500000, date: '2025-04-10' };

// --- AC #1: exactly four named exports, no additional surface ----------------

test('AC#1 exports exactly the four named functions and nothing else', () => {
  assert.deepEqual(
    Object.keys(engine).sort(),
    ['classifyBatch', 'classifyTransaction', 'computeTaxSummary', 'loadEffectiveProfile'],
  );
  for (const fn of Object.values(engine)) assert.equal(typeof fn, 'function');
});

// --- AC #2: loadEffectiveProfile delegates + carries provenance --------------

test('AC#2 loadEffectiveProfile returns the resolved profile with provenance + sources', () => {
  const profile = loadFixtureProfile();
  assert.equal(typeof profile.profile, 'object');
  assert.ok(profile.profile !== null);
  assert.equal(typeof profile.provenance, 'object'); // per-leaf origin tiers
  assert.ok(profile.provenance !== null);
  assert.equal(typeof profile.sources, 'object');    // the paths actually consulted
  assert.equal(profile.sources.profile, null);       // absent user profile → defaults only
  assert.ok(profile.sources.defaults, 'defaults path is recorded');
});

// --- AC #3: classifyTransaction delegates + returns the documented shape ------

function assertSuggestionShape(s) {
  assert.equal(typeof s.taxLineId, 'string');
  assert.equal(typeof s.confidence, 'number');
  assert.ok(s.confidence >= 0 && s.confidence <= 1);
  assert.equal(typeof s.reason, 'string');
  if ('businessEntityId' in s && s.businessEntityId !== undefined) {
    assert.equal(typeof s.businessEntityId, 'string');
  }
}

test('AC#3 classifyTransaction returns { taxLineId, confidence, reason, businessEntityId? }', () => {
  const profile = loadFixtureProfile();
  const s = classifyTransaction(GITHUB_TXN, profile);
  assertSuggestionShape(s);
  assert.equal(s.taxLineId, 'schedC.27a'); // GitHub → Schedule C other expenses
  assert.ok(s.confidence > 0);
  // Defaults carry no business entities, so $profile cannot resolve one.
  assert.equal(s.businessEntityId, undefined);
});

test('AC#3 classifyTransaction resolves the sole business entity for $profile rules', () => {
  // A bare resolved profile with exactly one entity → the $profile sentinel
  // resolves to that entity id. classifyTransaction accepts a bare profile too.
  const bareProfile = { businessEntities: [{ id: 'ent-1' }] };
  const s = classifyTransaction(GITHUB_TXN, bareProfile);
  assertSuggestionShape(s);
  assert.equal(s.taxLineId, 'schedC.27a');
  assert.equal(s.businessEntityId, 'ent-1');
});

// --- AC #4: classifyBatch — one per input, same order, same shape ------------

test('AC#4 classifyBatch returns one suggestion per input, in order, same shape', () => {
  const profile = loadFixtureProfile();
  const txns = [GITHUB_TXN, RENT_INCOME_TXN];
  const out = classifyBatch(txns, profile);
  assert.ok(Array.isArray(out));
  assert.equal(out.length, txns.length);
  for (const s of out) assertSuggestionShape(s);
  // Order is preserved: index 0 is the GitHub expense line.
  assert.equal(out[0].taxLineId, 'schedC.27a');
  // A non-array input degrades to an empty array, never throws.
  assert.deepEqual(classifyBatch(null, profile), []);
});

// --- AC #5: computeTaxSummary composes the five Section-12 fragments ----------

test('AC#5 computeTaxSummary composes P&L, Schedule A, medical, SE tax, and next quarterly', () => {
  const profile = loadFixtureProfile();
  const ytdData = {
    asOfDate: '2025-05-01',
    taxYear: 2025,
    filingStatus: 'single',
    scheduleCLines: [
      { taxLineId: 'schedC.1', label: 'Gross receipts', category: 'income', amount: 42000 },
      { taxLineId: 'schedC.8', label: 'Advertising', category: 'expense', amount: 12000 },
    ],
    itemizedDeductionsTotal: 21000,
    medicalExpenses: 9000,
    agi: 100000,
  };
  const summary = computeTaxSummary(profile, ytdData);

  // Schedule C P&L by line + totals.
  assert.equal(summary.scheduleC.lines.length, 2);
  assert.equal(summary.scheduleC.grossIncome, 42000);
  assert.equal(summary.scheduleC.deductibleExpenses, 12000);
  assert.equal(summary.scheduleC.netProfit, 30000);

  // Schedule A: itemized-vs-standard, driven by the profile's standard deduction.
  const std = profile.getStandardDeduction(2025, 'single');
  assert.equal(summary.scheduleA.standardDeduction, std);
  assert.equal(summary.scheduleA.itemizedTotal, 21000);
  assert.equal(summary.scheduleA.recommendation, 21000 > std ? 'itemize' : 'standard');
  assert.equal(summary.scheduleA.advantage, Math.round(Math.abs(21000 - std) * 100) / 100);

  // Medical 7.5%-AGI deep-dive: threshold dollar amount + above/below flag.
  const pct = profile.getThreshold('medicalAgiPercent');
  assert.equal(summary.medical.thresholdPercent, pct);
  assert.equal(summary.medical.thresholdAmount, Math.round(100000 * pct * 100) / 100); // 7500
  assert.equal(summary.medical.exceedsThreshold, true);                                // 9000 > 7500
  assert.equal(summary.medical.deductiblePortion, 1500);                               // 9000 − 7500

  // SE tax estimate composes the M3-6 primitive with the profile's SE rate.
  const seRate = profile.getThreshold('seTaxRate');
  assert.equal(summary.seTax.seTaxRate, seRate);
  assert.equal(summary.seTax.scheduleCNet, 30000);
  assert.equal(summary.seTax.amount, selfEmploymentTax(30000, seRate));

  // Next quarterly due date + estimated amount, composed from M3-6 primitives.
  const brackets = profile.getIncomeTaxBrackets(2025, 'single') ?? [];
  const expectedQuarterly = quarterlyEstimate(
    computeEstimate({
      grossIncome: 42000,
      deductibleExpenses: 12000,
      seRate,
      brackets,
      meta: { taxYear: 2025, filingStatus: 'single', asOfDate: '2025-05-01' },
    }),
    null,
  ).quarterLiability;
  assert.equal(summary.nextQuarterlyPayment.quarter, 2);            // first due date ≥ May 1
  assert.equal(summary.nextQuarterlyPayment.dueDate, '2025-06-15'); // Q2 due date
  assert.equal(summary.nextQuarterlyPayment.estimatedAmount, expectedQuarterly);

  // Meta echoes the resolved year/status/anchor.
  assert.deepEqual(summary.meta, { taxYear: 2025, filingStatus: 'single', asOfDate: '2025-05-01' });
});

test('AC#5 computeTaxSummary tolerates empty ytdData without throwing', () => {
  const profile = loadFixtureProfile();
  const summary = computeTaxSummary(profile, { taxYear: 2025, filingStatus: 'single' });
  assert.equal(summary.scheduleC.grossIncome, 0);
  assert.equal(summary.scheduleC.netProfit, 0);
  assert.equal(summary.medical.exceedsThreshold, false); // 0 medical, 0 threshold
  assert.equal(summary.seTax.amount, 0);
});

// --- AC #11: the facade writes nothing to stdout -----------------------------

test('AC#11 exercising the whole facade writes zero bytes to stdout', () => {
  const profile = loadFixtureProfile();
  const original = process.stdout.write;
  let bytes = 0;
  process.stdout.write = (chunk, ...rest) => {
    bytes += Buffer.byteLength(typeof chunk === 'string' ? chunk : chunk ?? '');
    // Swallow — do not forward to the real stream during the guarded window.
    if (typeof rest[rest.length - 1] === 'function') rest[rest.length - 1]();
    return true;
  };
  try {
    classifyTransaction(GITHUB_TXN, profile);
    classifyBatch([GITHUB_TXN, RENT_INCOME_TXN], profile);
    computeTaxSummary(profile, {
      taxYear: 2025,
      filingStatus: 'single',
      scheduleCLines: [{ taxLineId: 'schedC.1', category: 'income', amount: 1000 }],
      agi: 50000,
      medicalExpenses: 5000,
      itemizedDeductionsTotal: 10000,
    });
    loadEffectiveProfile({ profilePath: ABSENT });
  } finally {
    process.stdout.write = original;
  }
  assert.equal(bytes, 0, 'the facade must never write to stdout');
});
