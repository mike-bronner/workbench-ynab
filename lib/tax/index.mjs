// lib/tax/index.mjs — the workbench-ynab tax-engine FACADE (issue #27, M3-8).
//
// WHAT THIS IS
//   A single, thin, stable entry point that the M2 weekly/quarterly REVIEW SKILL
//   imports instead of reaching into the engine's internals. It is a FACADE over
//   three already-built, already-tested modules — it adds NO new tax logic, only
//   composition:
//     • lib/tax/loadProfile.mjs        (#22, M3-3) — the effective-profile loader
//     • lib/tax/classifyTransaction.mjs(#23, M3-4) — the payee→tax-line mapper
//     • lib/tax/estimatedTax.mjs       (#25/#82, M3-6) — the threshold/quarterly math
//   The math primitives it composes are unit-tested in those modules; only the
//   composition-level contract is tested here (tests/unit/tax-engine.test.mjs).
//
//   Exactly four named exports, and nothing else, so the M2 report template can
//   bind report fragments to a small, stable surface:
//     loadEffectiveProfile · classifyTransaction · classifyBatch · computeTaxSummary
//
// HOW M2 CALLS THIS
//   The review skill fetches transactions itself via the namespaced vendored MCP
//   tools (`mcp__plugin_workbench-ynab_ynab__*`, e.g. `ynab_list_transactions`,
//   `ynab_get_month`) and then hands the already-fetched objects to this engine.
//   This module is MCP-AGNOSTIC: it performs no fetch, no MCP call, no network —
//   transactions come in as plain objects.
//
//     import {
//       loadEffectiveProfile,
//       classifyTransaction,
//       classifyBatch,
//       computeTaxSummary,
//     } from '../../lib/tax/index.mjs';
//
//     // 1. Resolve the effective profile once (defaults ⊕ user ⊕ overrides).
//     const profile = loadEffectiveProfile();
//     if (!profile.ok) throw new Error(profile.error.message); // never guess on a bad profile
//
//     // 2. Fetch YNAB transactions via the MCP (in M2, not here), then classify.
//     const txns = await ynabListTransactions(/* … */);  // amounts in MILLIUNITS
//     const suggestions = classifyBatch(txns, profile);   // one suggestion per txn, same order
//     //   → each: { taxLineId, businessEntityId?, confidence, reason, matchedRuleId }
//     //   The engine only SUGGESTS. It NEVER writes. `confidence` lets M2 decide
//     //   which suggestions to surface for the human-gated approval flow.
//
//     // 3. Aggregate the YTD figures M2 already has and render the Section-12 summary.
//     //    computeTaxSummary REQUIRES a resolvable taxYear (integer) + filingStatus
//     //    (non-empty string) — from the resolved profile or, as shown here, from
//     //    ytdData. It THROWS when neither supplies them, rather than emitting a
//     //    silently-wrong summary (e.g. a 'NaN-01-15' quarterly due date).
//     const summary = computeTaxSummary(profile, {
//       taxYear: 2025,
//       filingStatus: 'single',
//       asOfDate: '2025-05-01',
//       scheduleCLines: [ { taxLineId: 'schedC.1', category: 'income', amount: 42000 }, /* … */ ],
//       itemizedDeductionsTotal: 21000,
//       medicalExpenses: 9000,
//       agi: 120000,
//     });
//
// TRANSACTION SHAPE (what the classifier reads)
//   A transaction is a plain object already fetched by M2. The engine reads these
//   fields, accepting BOTH YNAB-native snake_case and normalized camelCase:
//     payee_name / payeeName, category_name / categoryName,
//     category_group_name / categoryGroupName, account_name / accountName,
//     amount (or amount_milliunits), date.
//   MONEY UNITS: `amount` arrives in YNAB MILLIUNITS — divide by 1000 to get
//   dollars. The engine does this conversion internally; every DOLLAR figure it
//   returns (and every dollar figure in `ytdData` you pass to computeTaxSummary)
//   is in whole dollars, not milliunits.
//
// SUGGEST-ONLY — NEVER WRITE
//   Suggestions feed a HUMAN-GATED, ledger-only write-back flow (a locked
//   decision: every change batch needs explicit human approval; the plugin never
//   moves real money). This engine only PRODUCES suggestions — it must never
//   trigger a write itself. `confidence` (0..1) is surfaced precisely so M2 can
//   decide what to present for human approval versus what to hold back.
//
// STDOUT / STDERR DISCIPLINE
//   This module writes NOTHING to stdout. It is pure composition that returns
//   structured results; it never logs on the happy path. A single stray stdout
//   byte corrupts a JSON-RPC / MCP handshake, so any diagnostic output ever added
//   must go to stderr only.

import { loadProfile } from './loadProfile.mjs';
import { classify } from './classifyTransaction.mjs';
import { scheduleCNet, selfEmploymentTax, computeEstimate, quarterlyEstimate } from './estimatedTax.mjs';

// --- Documented return types (JSDoc @typedef; this repo ships no TypeScript) --
//
// The M2 report template binds report fragments to these shapes, so they are the
// stable contract — changing them later is costly. Keep them minimal.

/**
 * @typedef {object} TaxSuggestion A single classification suggestion. The four
 *   fields the contract guarantees are `taxLineId`, `confidence`, `reason`, and
 *   the OPTIONAL `businessEntityId`; `matchedRuleId` rides along for traceability.
 * @property {string} taxLineId          suggested tax-line id (e.g. 'schedC.27a'),
 *   or the reserved sentinel 'unclassified' when nothing matched.
 * @property {string} [businessEntityId] owning Schedule-C entity id, when resolved.
 * @property {number} confidence         match confidence in [0, 1]; 0 when unclassified.
 * @property {string} reason             human-readable why-this-line explanation.
 * @property {string|null} matchedRuleId id of the matched mapping rule, or null.
 */

/**
 * @typedef {object} ScheduleCLineInput One aggregated YTD Schedule-C line M2 passes in.
 * @property {string} taxLineId          the Schedule-C line id (e.g. 'schedC.1').
 * @property {string} [label]            optional human label for the report row.
 * @property {'income'|'expense'} category whether this line is income or expense.
 * @property {number} amount             YTD dollar total for the line (positive magnitude).
 */

/**
 * @typedef {object} YtdData The pre-aggregated YTD figures computeTaxSummary composes.
 *   M2 assembles these (classifying/aggregating transactions with this engine's
 *   classifier); computeTaxSummary does NO fetching and NO re-classification.
 * @property {string} [asOfDate]         'YYYY-MM-DD' anchor for "next quarterly due
 *   date"; defaults to today (UTC).
 * @property {number} [taxYear]          overrides profile.taxYear for the summary.
 * @property {string} [filingStatus]     overrides profile.filingStatus for the summary.
 * @property {ScheduleCLineInput[]} [scheduleCLines] YTD Schedule-C activity by line (dollars).
 * @property {number} [itemizedDeductionsTotal] YTD sum of Schedule-A itemizable deductions (dollars).
 * @property {number} [medicalExpenses]  YTD unreimbursed medical expenses (dollars).
 * @property {number} [agi]              adjusted gross income (dollars) for the 7.5% medical floor.
 * @property {object} [priorCumulative]  a computeEstimate() snapshot through the PRIOR
 *   quarter's period end; when supplied, the next quarter's estimate is the exact
 *   incremental liability, otherwise the conservative full cumulative liability.
 */

/**
 * @typedef {object} TaxSummary The Section-12 running YTD numbers for the M2 report.
 * @property {object} scheduleC          { lines: ScheduleCLineInput[], grossIncome,
 *   deductibleExpenses, netProfit } — Schedule-C P&L by line + totals (dollars).
 * @property {object} scheduleA          { itemizedTotal, standardDeduction,
 *   recommendation: 'itemize'|'standard', advantage } — itemized-vs-standard (dollars).
 * @property {object} medical            { agi, thresholdPercent, thresholdAmount,
 *   medicalExpenses, deductiblePortion, exceedsThreshold } — the 7.5%-AGI deep-dive.
 * @property {object} seTax              { scheduleCNet, seTaxRate, amount } — SE tax estimate.
 * @property {?object} nextQuarterlyPayment { quarter, dueDate, estimatedAmount } — the
 *   next estimated-tax due date + estimated payment (dollars), or null when none remains.
 * @property {object} meta               { taxYear, filingStatus, asOfDate }.
 */

// --- Internal helpers (module-private — not part of the public surface) ------

// Round to whole cents, matching the estimatedTax module's internal rounding so
// composed dollar figures stay consistent. This is arithmetic hygiene, not tax logic.
function round2(n) {
  return Math.round((Number(n) || 0) * 100) / 100;
}

// Accept either the loadEffectiveProfile() RESULT or a bare resolved profile
// object and return the bare resolved profile the M3-4 classifier expects. A
// RESULT envelope is identified by its `ok` flag: a SUCCESSFUL load is unwrapped
// to its `.profile`; a FAILED load THROWS rather than letting the failure
// envelope masquerade as a real profile and yield a plausible-looking-but-bogus
// suggestion (M2 is told to check `.ok` first, so a failed load reaching here is
// a caller bug — fail loud, never guess). This keeps all four exports consistent:
// a bad profile is refused everywhere, not silently classified in some paths and
// a raw TypeError in others. A bare resolved profile carries no `ok` flag and is
// used as-is; null/undefined passes through unchanged.
function rawProfile(profile) {
  if (profile && typeof profile === 'object' && 'ok' in profile) {
    if (!profile.ok) {
      const detail = profile.error && profile.error.message ? ` (${profile.error.message})` : '';
      throw new Error(
        `tax engine: refusing to operate on a failed profile load${detail}. ` +
          'Check loadEffectiveProfile().ok before classifying or computing a summary.',
      );
    }
    return profile.profile;
  }
  return profile;
}

// Today as 'YYYY-MM-DD' (UTC), the default "as of" anchor for the next due date.
function todayISO() {
  return new Date().toISOString().slice(0, 10);
}

// Read a required tax rate/threshold from the RESOLVED profile, failing loud when
// it is missing. The facade never hardcodes tax-law constants (see the module
// docstring): every rate must come from the profile, so an override that drops
// one is a broken config — not a silent-default opportunity that would go live
// and stale the moment tax law shifts.
function requireRate(profile, name) {
  const value = profile.getThreshold(name);
  if (!Number.isFinite(value)) {
    throw new Error(
      `computeTaxSummary: the resolved profile is missing a usable '${name}' rate ` +
        `(got ${JSON.stringify(value)}); it must come from the profile — the facade ` +
        'never hardcodes tax-law constants.',
    );
  }
  return value;
}

// --- Public facade surface (exactly four named exports) ----------------------

/**
 * Resolve the effective tax profile. Delegates ENTIRELY to the M3-3 loader
 * (lib/tax/loadProfile.mjs, #22): the bundled US defaults deep-merged with the
 * user's profile and any overrides, validated against the canonical schema. The
 * returned object carries the resolved `profile`, a per-leaf `provenance` map
 * (which tier — defaults/user/overrides — supplied each value), the `sources`
 * paths actually consulted, and the profile accessors. On a bad profile it
 * returns `{ ok: false, error, … }` — callers must check `ok` and never guess.
 *
 * @param {object} [options] forwarded verbatim to loadProfile (profilePath,
 *   dataDir, defaultsPath, schemaPath, env — all test/override seams).
 * @returns {Readonly<object>} the loadProfile result (see lib/tax/loadProfile.mjs).
 */
export function loadEffectiveProfile(options = {}) {
  return loadProfile(options);
}

/**
 * Classify one already-fetched YNAB transaction to a suggested tax line.
 * Delegates ENTIRELY to the M3-4 mapping engine (lib/tax/classifyTransaction.mjs,
 * #23) — this facade adds no classification logic. Accepts either the
 * loadEffectiveProfile() result or a bare resolved profile for `profile`.
 *
 * @param {object} txn     already-fetched YNAB transaction (amounts in milliunits).
 * @param {object} profile loadEffectiveProfile() result, or its `.profile`.
 * @param {object} [options] forwarded to classify (minConfidence, rules, userRules).
 * @returns {TaxSuggestion} the suggestion, or the 'unclassified' sentinel.
 */
export function classifyTransaction(txn, profile, options = {}) {
  return classify(txn, rawProfile(profile), options);
}

/**
 * Classify a batch of already-fetched transactions — the weekly-review pass.
 * Returns one suggestion per input transaction, in the IDENTICAL shape as
 * classifyTransaction and in the SAME order as the input.
 *
 * @param {object[]} txns    already-fetched YNAB transactions (amounts in milliunits).
 * @param {object}   profile loadEffectiveProfile() result, or its `.profile`.
 * @param {object} [options] forwarded to classify (minConfidence, rules, userRules).
 * @returns {TaxSuggestion[]} one suggestion per input, same order.
 */
export function classifyBatch(txns, profile, options = {}) {
  const resolved = rawProfile(profile);
  return (Array.isArray(txns) ? txns : []).map((txn) => classify(txn, resolved, options));
}

/**
 * Compose the Section-12 running YTD tax summary the M2 report renders. This
 * COMPOSES the M3-6 primitives (scheduleCNet, selfEmploymentTax, computeEstimate,
 * quarterlyEstimate) plus profile-supplied rates/thresholds — it writes NO new
 * tax logic. Every rate (SE rate, medical AGI %, standard deduction, brackets,
 * due dates) comes from the resolved profile, never hardcoded here.
 *
 * `profile` MUST be the loadEffectiveProfile() result (it uses the result's
 * accessors: getThreshold, getStandardDeduction, getIncomeTaxBrackets,
 * getQuarterlyDueDates). `ytdData` carries the pre-aggregated YTD figures.
 *
 * @param {object} profile loadEffectiveProfile() result.
 * @param {YtdData} [ytdData] pre-aggregated YTD figures (all dollars).
 * @returns {TaxSummary} the Section-12 summary.
 */
export function computeTaxSummary(profile, ytdData = {}) {
  const p = rawProfile(profile);
  const taxYear = ytdData.taxYear ?? (p && p.taxYear);
  const filingStatus = ytdData.filingStatus ?? (p && p.filingStatus);
  const asOfDate = ytdData.asOfDate ?? todayISO();

  // Fail loud when the summary lacks a resolvable tax year + filing status. Both
  // drive the standard deduction, income-tax brackets, and quarterly due dates;
  // without them the composed figures are silently wrong — e.g. a defaults-only
  // first-run profile (which carries no taxYear) would sort 'undefined'/'NaN'
  // date strings and surface a 'NaN-01-15' due date straight into the M2 report.
  // These come from the resolved profile or ytdData — the engine never guesses.
  if (!Number.isInteger(taxYear) || typeof filingStatus !== 'string' || filingStatus.length === 0) {
    throw new Error(
      'computeTaxSummary requires a resolvable taxYear (integer) and filingStatus ' +
        `(non-empty string); got taxYear=${JSON.stringify(taxYear)}, ` +
        `filingStatus=${JSON.stringify(filingStatus)}. Supply them via the resolved ` +
        'profile or ytdData — the engine must never guess these.',
    );
  }

  // --- Schedule C P&L by line -------------------------------------------------
  const inputLines = Array.isArray(ytdData.scheduleCLines) ? ytdData.scheduleCLines : [];
  let grossIncome = 0;
  let deductibleExpenses = 0;
  const lines = inputLines.map((l) => {
    const amount = round2(l && l.amount);
    if (l && l.category === 'income') grossIncome += amount;
    else if (l && l.category === 'expense') deductibleExpenses += amount;
    return { taxLineId: l && l.taxLineId, label: l && l.label, category: l && l.category, amount };
  });
  grossIncome = round2(grossIncome);
  deductibleExpenses = round2(deductibleExpenses);
  const netProfit = scheduleCNet({ grossIncome, deductibleExpenses });
  const scheduleC = { lines, grossIncome, deductibleExpenses, netProfit };

  // --- Schedule A: itemized vs standard ---------------------------------------
  const itemizedTotal = round2(ytdData.itemizedDeductionsTotal);
  const standardDeduction = round2(profile.getStandardDeduction(taxYear, filingStatus) ?? 0);
  const scheduleA = {
    itemizedTotal,
    standardDeduction,
    recommendation: itemizedTotal > standardDeduction ? 'itemize' : 'standard',
    advantage: round2(Math.abs(itemizedTotal - standardDeduction)),
  };

  // --- Medical 7.5%-AGI deep-dive ---------------------------------------------
  const agi = round2(ytdData.agi);
  const medicalExpenses = round2(ytdData.medicalExpenses);
  const thresholdPercent = requireRate(profile, 'medicalAgiPercent');
  const thresholdAmount = round2(agi * thresholdPercent);
  const medical = {
    agi,
    thresholdPercent,
    thresholdAmount,
    medicalExpenses,
    deductiblePortion: round2(Math.max(0, medicalExpenses - thresholdAmount)),
    exceedsThreshold: medicalExpenses > thresholdAmount,
  };

  // --- SE tax estimate (M3-6 primitive) ---------------------------------------
  const seTaxRate = requireRate(profile, 'seTaxRate');
  const seTax = {
    scheduleCNet: netProfit,
    seTaxRate,
    amount: selfEmploymentTax(netProfit, seTaxRate),
  };

  // --- Next quarterly estimated-tax due date + amount (M3-6 primitives) -------
  const brackets = profile.getIncomeTaxBrackets(taxYear, filingStatus) ?? [];
  const cumulative = computeEstimate({
    grossIncome,
    deductibleExpenses,
    seRate: seTaxRate,
    brackets,
    meta: { taxYear, filingStatus, asOfDate },
  });
  const quarterly = quarterlyEstimate(cumulative, ytdData.priorCumulative ?? null);
  const dueDates = [...(profile.getQuarterlyDueDates(taxYear) ?? [])].sort((a, b) =>
    a.date < b.date ? -1 : a.date > b.date ? 1 : 0,
  );
  const upcoming = dueDates.find((d) => d.date >= asOfDate) ?? null;
  const nextQuarterlyPayment = upcoming
    ? { quarter: upcoming.quarter, dueDate: upcoming.date, estimatedAmount: quarterly.quarterLiability }
    : null;

  return {
    scheduleC,
    scheduleA,
    medical,
    seTax,
    nextQuarterlyPayment,
    meta: { taxYear, filingStatus, asOfDate },
  };
}
