// tests/unit/confidence.test.mjs — unit tests for the confidence-band /
// human-review routing policy (lib/tax/confidence.mjs, issue #19 / GAP-20) and
// its wiring through the mapping engine (lib/tax/classifyTransaction.mjs).
//
// Runs under the built-in node:test runner with NO node_modules present (only
// node: built-ins and repo-local files), per docs/testing.md.
//
// Covers the issue #19 AC matrix: the exported band constants and default
// thresholds as public API; band assignment at and around each threshold
// boundary; the configurable override path (config.json →
// classification.highThreshold / classification.mediumThreshold, via the
// loadThresholds file/env seams) with safe fallback on missing, malformed,
// out-of-range, and contradictory values; every classify() result carrying
// { confidence, band } in one object; the hard-coded splits/transfers →
// 'unclassified' band rule (no exception path); and the verbatim
// approval-gate JSDoc statement. These tests deliberately pin the band
// contract — they fail if it changes accidentally.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  HIGH,
  MEDIUM,
  LOW,
  UNCLASSIFIED as UNCLASSIFIED_BAND,
  HIGH_THRESHOLD,
  MEDIUM_THRESHOLD,
  DEFAULT_THRESHOLDS,
  loadThresholds,
  assignBand,
} from '../../lib/tax/confidence.mjs';
import { classify, UNCLASSIFIED } from '../../lib/tax/classifyTransaction.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

// A YNAB transaction is in MILLIUNITS; outflow (expense) is negative. -$9.00.
const tx = (over = {}) => ({ payee_name: 'Anon', amount: -9000, ...over });

// A single injected rule (zero-I/O purity, as classify-transaction.test.mjs
// does) with a chosen confidence, so band wiring is tested deterministically.
const rulesWith = (confidence) => [{
  id: 'test-rule',
  match: { payeeKeywords: ['anon'] },
  taxLineId: 'schedC.27a',
  priority: 1,
  reason: 'test',
  confidence,
}];

// Write a throwaway config.json and return its path (cleaned per test).
function tempConfig(t, contents) {
  const dir = mkdtempSync(join(tmpdir(), 'confidence-test-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const file = join(dir, 'config.json');
  writeFileSync(file, typeof contents === 'string' ? contents : JSON.stringify(contents));
  return file;
}

// --- Public API: band constants + default thresholds -------------------------

test('band constants are the documented public API values', () => {
  assert.equal(HIGH, 'high');
  assert.equal(MEDIUM, 'medium');
  assert.equal(LOW, 'low');
  assert.equal(UNCLASSIFIED_BAND, 'unclassified');
});

test('default thresholds are the documented conservative values', () => {
  assert.equal(HIGH_THRESHOLD, 0.85);
  assert.equal(MEDIUM_THRESHOLD, 0.6);
  assert.deepEqual(DEFAULT_THRESHOLDS, { highThreshold: 0.85, mediumThreshold: 0.6 });
  assert.ok(Object.isFrozen(DEFAULT_THRESHOLDS));
});

// --- assignBand: semantics at and around each boundary ------------------------

test('assignBand: at and around the HIGH boundary', () => {
  assert.equal(assignBand(1), HIGH);
  assert.equal(assignBand(HIGH_THRESHOLD), HIGH); // ≥ is inclusive
  assert.equal(assignBand(HIGH_THRESHOLD - 0.0001), MEDIUM);
});

test('assignBand: at and around the MEDIUM boundary', () => {
  assert.equal(assignBand(MEDIUM_THRESHOLD), MEDIUM); // ≥ is inclusive
  assert.equal(assignBand(MEDIUM_THRESHOLD - 0.0001), LOW);
});

test('assignBand: low band covers 0 < confidence < MEDIUM_THRESHOLD', () => {
  assert.equal(assignBand(0.0001), LOW);
  assert.equal(assignBand(0.5), LOW);
});

test('assignBand: zero and junk confidences → unclassified', () => {
  assert.equal(assignBand(0), UNCLASSIFIED_BAND);
  assert.equal(assignBand(-0.5), UNCLASSIFIED_BAND);
  assert.equal(assignBand(NaN), UNCLASSIFIED_BAND);
  assert.equal(assignBand(Infinity), UNCLASSIFIED_BAND);
  assert.equal(assignBand('0.9'), UNCLASSIFIED_BAND);
  assert.equal(assignBand(undefined), UNCLASSIFIED_BAND);
});

test('assignBand: honours custom thresholds', () => {
  const t = { highThreshold: 0.9, mediumThreshold: 0.3 };
  assert.equal(assignBand(0.85, t), MEDIUM); // below the raised high bar
  assert.equal(assignBand(0.95, t), HIGH);
  assert.equal(assignBand(0.29, t), LOW);
  assert.equal(assignBand(0.3, t), MEDIUM);
});

test('assignBand: invalid or contradictory thresholds fall back to defaults', () => {
  // medium ≥ high would make the medium band unreachable → defaults win.
  assert.equal(assignBand(0.7, { highThreshold: 0.5, mediumThreshold: 0.5 }), MEDIUM);
  // junk values per key → that key falls back.
  assert.equal(assignBand(0.86, { highThreshold: 'nope', mediumThreshold: -3 }), HIGH);
  assert.equal(assignBand(0.86, null), HIGH);
});

// --- loadThresholds: config override path + safe fallbacks --------------------

test('loadThresholds: reads classification overrides from config.json', (t) => {
  const configFile = tempConfig(t, { classification: { highThreshold: 0.9, mediumThreshold: 0.4 } });
  assert.deepEqual(loadThresholds({ configFile }), { highThreshold: 0.9, mediumThreshold: 0.4 });
});

test('loadThresholds: honours the YNAB_CONFIG_FILE env seam', (t) => {
  const configFile = tempConfig(t, { classification: { highThreshold: 0.7, mediumThreshold: 0.2 } });
  const got = loadThresholds({}, { YNAB_CONFIG_FILE: configFile });
  assert.deepEqual(got, { highThreshold: 0.7, mediumThreshold: 0.2 });
});

test('loadThresholds: options.configFile wins over the env seam', (t) => {
  const fromOptions = tempConfig(t, { classification: { highThreshold: 0.9, mediumThreshold: 0.1 } });
  const fromEnv = tempConfig(t, { classification: { highThreshold: 0.8, mediumThreshold: 0.2 } });
  const got = loadThresholds({ configFile: fromOptions }, { YNAB_CONFIG_FILE: fromEnv });
  assert.equal(got.highThreshold, 0.9);
});

test('loadThresholds: missing file → defaults', () => {
  const got = loadThresholds({ configFile: join(tmpdir(), 'confidence-test-definitely-absent.json') });
  assert.deepEqual(got, DEFAULT_THRESHOLDS);
});

test('loadThresholds: malformed JSON → defaults, never a throw', (t) => {
  const configFile = tempConfig(t, '{ not json');
  assert.deepEqual(loadThresholds({ configFile }), DEFAULT_THRESHOLDS);
});

test('loadThresholds: absent classification block → defaults', (t) => {
  const configFile = tempConfig(t, { schema_version: 1 });
  assert.deepEqual(loadThresholds({ configFile }), DEFAULT_THRESHOLDS);
});

test('loadThresholds: partial override keeps the other default', (t) => {
  const configFile = tempConfig(t, { classification: { highThreshold: 0.95 } });
  assert.deepEqual(loadThresholds({ configFile }), { highThreshold: 0.95, mediumThreshold: MEDIUM_THRESHOLD });
});

test('loadThresholds: out-of-range values fall back per key', (t) => {
  const configFile = tempConfig(t, { classification: { highThreshold: 1.5, mediumThreshold: 0.4 } });
  assert.deepEqual(loadThresholds({ configFile }), { highThreshold: HIGH_THRESHOLD, mediumThreshold: 0.4 });
});

test('loadThresholds: contradictory pair (medium ≥ high) → defaults wholesale', (t) => {
  const configFile = tempConfig(t, { classification: { highThreshold: 0.3, mediumThreshold: 0.7 } });
  assert.deepEqual(loadThresholds({ configFile }), DEFAULT_THRESHOLDS);
});

// --- classify() wiring: every result carries { confidence, band } -------------

test('classify: a match carries confidence and band in one object', () => {
  const r = classify(tx(), null, { rules: rulesWith(0.9) });
  assert.equal(r.taxLineId, 'schedC.27a');
  assert.equal(r.confidence, 0.9);
  assert.equal(r.band, HIGH);
});

test('classify: bands follow the default thresholds', () => {
  assert.equal(classify(tx(), null, { rules: rulesWith(0.85) }).band, HIGH);
  assert.equal(classify(tx(), null, { rules: rulesWith(0.6) }).band, MEDIUM);
  assert.equal(classify(tx(), null, { rules: rulesWith(0.59) }).band, LOW);
});

test('classify: options.thresholds overrides the band cutoffs', () => {
  const thresholds = { highThreshold: 0.95, mediumThreshold: 0.5 };
  assert.equal(classify(tx(), null, { rules: rulesWith(0.9), thresholds }).band, MEDIUM);
  assert.equal(classify(tx(), null, { rules: rulesWith(0.96), thresholds }).band, HIGH);
});

test('classify: the UNCLASSIFIED sentinel carries band unclassified', () => {
  assert.equal(UNCLASSIFIED.band, UNCLASSIFIED_BAND);
  const r = classify(tx({ payee_name: 'zzz-no-rule-matches-this' }), null, { rules: rulesWith(0.9) });
  assert.equal(r.band, UNCLASSIFIED_BAND);
  assert.equal(r.confidence, 0);
});

// --- Splits and transfer legs: hard-coded human-only band ---------------------

test('classify: a split (non-empty subtransactions) is band unclassified despite high confidence', () => {
  const r = classify(tx({ subtransactions: [{ amount: -4000 }, { amount: -5000 }] }), null, { rules: rulesWith(0.99) });
  assert.equal(r.band, UNCLASSIFIED_BAND);
  assert.equal(r.taxLineId, 'schedC.27a'); // the assignment still surfaces; only routing is forced
});

test("classify: YNAB's literal 'Split' category is band unclassified", () => {
  const r = classify(tx({ category_name: 'Split' }), null, { rules: rulesWith(0.99) });
  assert.equal(r.band, UNCLASSIFIED_BAND);
});

test('classify: a transfer leg (transfer_account_id) is band unclassified despite high confidence', () => {
  const r = classify(tx({ transfer_account_id: 'acct-savings' }), null, { rules: rulesWith(0.99) });
  assert.equal(r.band, UNCLASSIFIED_BAND);
});

test('classify: no exception path — custom thresholds cannot re-band a transfer leg', () => {
  const r = classify(
    tx({ transfer_account_id: 'acct-savings' }),
    null,
    { rules: rulesWith(0.99), thresholds: { highThreshold: 0.01, mediumThreshold: 0.005 } },
  );
  assert.equal(r.band, UNCLASSIFIED_BAND);
});

test('classify: an ordinary transaction (null transfer_account_id, empty subtransactions) bands normally', () => {
  const r = classify(tx({ transfer_account_id: null, subtransactions: [] }), null, { rules: rulesWith(0.9) });
  assert.equal(r.band, HIGH);
});

// --- The approval-gate statement is pinned verbatim ---------------------------

test('confidence.mjs states the approval-gate contract verbatim in its JSDoc', () => {
  const src = readFileSync(join(ROOT, 'lib', 'tax', 'confidence.mjs'), 'utf8');
  const verbatim = 'Confidence governs proposal composition only — whether an op is pre-filled\n'
    + ' * in the proposal. The human approval gate is mandatory and independent of\n'
    + ' * confidence; nothing bypasses it.';
  assert.ok(src.includes(verbatim), 'the verbatim approval-gate JSDoc statement must not be reworded');
});
