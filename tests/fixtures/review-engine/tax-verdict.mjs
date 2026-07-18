// tests/fixtures/review-engine/tax-verdict.mjs — the deterministic tax-verdict
// driver for the review-engine golden-snapshot test (issue #39).
//
// It feeds the committed synthetic fixtures through the REAL tax engine
// (lib/tax/index.mjs) — no mock, no re-implemented math — and prints the
// Section-12 itemize-vs-standard result as JSON. The snapshot test runs it once
// per tax-profile fixture (low- and high-standard-deduction) and asserts the
// verdict flips, proving the recommendation reads the configured standard
// deduction rather than a hardcoded constant (M2-2). It also emits the verdict
// text the test injects into the section-12 fragment, so the flip is visible in
// the assembled report output, not just in the engine return value.
//
// USAGE
//   node tax-verdict.mjs --profile <profile.json> --transactions <txns.json> \
//        --itemized <dollars> --as-of <YYYY-MM-DD>
//
// OUTPUT (stdout, one JSON line)
//   { "recommendation": "itemize"|"standard", "standardDeduction": <n>,
//     "itemizedTotal": <n>, "netProfit": <n>, "advantage": <n> }
//
// Exits non-zero (and prints the reason to stderr) on a bad profile load or a
// missing/unreadable fixture — fail closed, never emit a plausible-but-bogus
// verdict.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { loadEffectiveProfile, computeTaxSummary } from '../../../lib/tax/index.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && i + 1 < process.argv.length ? process.argv[i + 1] : fallback;
}

function die(msg) {
  process.stderr.write(`tax-verdict: ${msg}\n`);
  process.exit(1);
}

const profilePath = arg('profile');
const txnsPath = arg('transactions');
const itemizedTotal = Number(arg('itemized', 'NaN'));
const asOfDate = arg('as-of', '2025-05-01');

if (!profilePath) die('missing --profile');
if (!Number.isFinite(itemizedTotal)) die('missing or non-numeric --itemized');

// Aggregate the fixture transactions into Schedule-C lines (dollars). YNAB
// amounts are milliunits; positive = income, negative = expense magnitude.
let scheduleCLines = [];
if (txnsPath) {
  let raw;
  try {
    raw = JSON.parse(readFileSync(resolve(HERE, txnsPath), 'utf8'));
  } catch (e) {
    die(`cannot read transactions fixture ${txnsPath}: ${e.message}`);
  }
  const txns = (raw && raw.data && raw.data.transactions) || [];
  let income = 0;
  let expense = 0;
  for (const t of txns) {
    const dollars = (Number(t.amount) || 0) / 1000;
    if (dollars >= 0) income += dollars;
    else expense += -dollars;
  }
  scheduleCLines = [
    { taxLineId: 'schedC.1', label: 'Gross receipts', category: 'income', amount: income },
    { taxLineId: 'schedC.28', label: 'Total expenses', category: 'expense', amount: expense },
  ];
}

// dataDir is the fixture directory so the committed profile canonicalizes inside
// an allowed containment root (issue #169) — both variants live here.
const loaded = loadEffectiveProfile({ profilePath: resolve(HERE, profilePath), dataDir: HERE });
if (!loaded.ok) {
  die(`profile load failed: ${loaded.error && loaded.error.message}`);
}

let summary;
try {
  summary = computeTaxSummary(loaded, {
    asOfDate,
    scheduleCLines,
    itemizedDeductionsTotal: itemizedTotal,
    agi: 90000,
    medicalExpenses: 3000,
  });
} catch (e) {
  die(`computeTaxSummary threw: ${e.message}`);
}

const { itemizedTotal: it, standardDeduction, recommendation, advantage } = summary.scheduleA;
process.stdout.write(
  `${JSON.stringify({
    recommendation,
    standardDeduction,
    itemizedTotal: it,
    netProfit: summary.scheduleC.netProfit,
    advantage,
  })}\n`,
);
