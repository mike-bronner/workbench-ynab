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
//     • lib/tax/taxYear.mjs            (#17, GAP-15) — the active-tax-year rule
//   The math primitives it composes are unit-tested in those modules; only the
//   composition-level contract is tested here (tests/unit/tax-engine.test.mjs).
//   It also imports lib/tax/civilDate.mjs (#240) — the shared strict civil-date
//   parser — purely to VALIDATE its own inputs, never to compute anything.
//
//   Exactly six named exports, and nothing else, so the M2 report template can
//   bind report fragments to a small, stable surface:
//     loadEffectiveProfile · classifyTransaction · classifyBatch · computeTaxSummary
//     resolveTaxYear · resolveYearBoundary
//
// THE ACTIVE TAX YEAR (#17)
//   `resolveTaxYear(reviewDate, timezone, taxYearOverride?)` is the ONLY sanctioned
//   way to decide which tax year a review is about: the calendar year of the review
//   date in the configured timezone, or the user's explicit `config.tax_year`. The
//   budget's display name (e.g. 'Personal 2024') is never read or parsed for a year
//   — it is a renameable label, not a tax fact. `resolveYearBoundary` adds the early
//   January rule: while the prior year's wrapping quarterly payment has not come due,
//   both tax years are live, and `computeTaxSummary` returns the prior year's
//   close-out alongside the new year's opening figures.
//
//   `computeTaxSummary` DERIVES its own year through `resolveTaxYear` — it does not
//   accept one. Before #17 it read `ytdData.taxYear ?? profile.taxYear`: a
//   hand-maintained field that keeps answering last year forever once the calendar
//   rolls over, which is the same staleness bug as parsing 'Personal 2024', only
//   relocated from the budget name to tax-profile.json. Both are now REFUSED as
//   sources of the active year:
//     • `ytdData.taxYear` THROWS — a caller still passing it is on the stale path and
//       must be told, not silently corrected.
//     • `profile.taxYear` is ignored for this purpose. It stays valid profile
//       metadata (which year the rates/brackets were authored for); if it disagrees
//       with the resolved year the profile accessors fail loud on the missing year,
//       which is the correct signal to update the profile.
//   The only accepted pin is `ytdData.taxYearOverride` — the caller's `config.tax_year`
//   (AC #6), passed through to `resolveTaxYear` verbatim.
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
//     //   → each: { taxLineId, businessEntityId?, confidence, band, reason, matchedRuleId }
//     //   The engine only SUGGESTS. It NEVER writes. `confidence` lets M2 decide
//     //   which suggestions to surface for the human-gated approval flow.
//
//     // 3. Aggregate the YTD figures M2 already has and render the Section-12 summary.
//     //    computeTaxSummary REQUIRES a resolvable filingStatus (non-empty string —
//     //    from the resolved profile or ytdData), an explicit ytdData.asOfDate
//     //    ('YYYY-MM-DD', the review window's end in the configured zone) and an
//     //    explicit ytdData.timezone (config.timezone). It THROWS when any is
//     //    missing, rather than emitting a silently-wrong summary (e.g. a
//     //    'NaN-01-15' quarterly due date) or anchoring on the host clock. The tax
//     //    YEAR is not passed — the engine resolves it from asOfDate + timezone.
//     const summary = computeTaxSummary(profile, {
//       filingStatus: 'single',
//       asOfDate: '2025-05-01',
//       timezone: 'America/Phoenix',        // config.timezone — never the host zone
//       // taxYearOverride: 2024,           // only when config.tax_year is set
//       scheduleCLines: [ { taxLineId: 'schedC.1', category: 'income', amount: 42000 }, /* … */ ],
//       itemizedDeductionsTotal: 21000,
//       medicalExpenses: 9000,
//       agi: 120000,
//     });
//     summary.meta.taxYear;       // 2025 — from resolveTaxYear, never a stored field
//     summary.meta.taxYearLabel;  // 'Tax Year 2025' — the report header, verbatim
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
import { epochDay } from './civilDate.mjs';
import { resolveTaxYear, resolveYearBoundary, yearBoundaryForCivilDate } from './taxYear.mjs';

// The active-tax-year rule (#17) is part of the facade's public surface: M2 resolves
// the year and the January changeover through these, never by parsing a budget name.
export { resolveTaxYear, resolveYearBoundary };

// --- Documented return types (JSDoc @typedef; this repo ships no TypeScript) --
//
// The M2 report template binds report fragments to these shapes, so they are the
// stable contract — changing them later is costly. Keep them minimal.

/**
 * @typedef {object} EffectiveProfileResult The frozen loadProfile() result that
 *   loadEffectiveProfile returns verbatim (lib/tax/loadProfile.mjs, #22). Callers
 *   MUST check `ok` first — the classify/summary exports refuse a failed load.
 * @property {boolean} ok                whether the load succeeded.
 * @property {object} [error]            { kind, message, errors } — present only
 *   when `ok` is false.
 * @property {object} sources            { defaults, profile, schema } paths actually consulted.
 * @property {Readonly<object>|null} profile    the resolved, frozen profile, or null on failure.
 * @property {Readonly<object>|null} provenance per-leaf 'defaults'/'user'/'overrides'
 *   map, or null on failure.
 * @property {boolean} [defaultsOnly]    present on success; true when no user
 *   profile file was found.
 * @property {Function} [getStandardDeduction] success-only accessor: standard
 *   deduction (dollars) for a year + filing status, or undefined.
 * @property {Function} [getThreshold]   success-only accessor: a tunable
 *   threshold/rate by name (e.g. 'seTaxRate'), or undefined.
 * @property {Function} [getBusinessEntities] success-only accessor: the resolved
 *   business entities (always an array, possibly empty).
 * @property {Function} [getScheduleLineMap] success-only accessor: the
 *   scheduleLineMap for one entity by id, or undefined if no such entity.
 * @property {Function} [getQuarterlyDueDates] success-only accessor: quarterly
 *   estimated-tax due dates resolved to calendar dates for a year.
 * @property {Function} [getIncomeTaxBrackets] success-only accessor: marginal
 *   income-tax brackets (ascending) for a year + filing status, or undefined.
 * @property {Function} [getEstimatedTaxPaymentMatchers] success-only accessor:
 *   the four estimated-tax-payment match arrays (possibly empty).
 */

/**
 * @typedef {object} TaxSuggestion A single classification suggestion. The
 *   fields the contract guarantees are `taxLineId`, `confidence`, `band`,
 *   `reason`, and the OPTIONAL `businessEntityId`; `matchedRuleId` rides along
 *   for traceability.
 * @property {string} taxLineId          suggested tax-line id (e.g. 'schedC.27a'),
 *   or the reserved sentinel 'unclassified' when nothing matched.
 * @property {string} [businessEntityId] owning Schedule-C entity id, when resolved.
 * @property {number} confidence         match confidence in [0, 1]; 0 when unclassified.
 * @property {('high'|'medium'|'low'|'unclassified')} band routing band (issue #19,
 *   lib/tax/confidence.mjs): governs proposal composition only — the human
 *   approval gate is mandatory and independent of confidence. Splits and
 *   transfer legs are always 'unclassified'.
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
 * @property {string} asOfDate           REQUIRED 'YYYY-MM-DD' anchor for "next quarterly
 *   due date". No default: computeTaxSummary THROWS when it is missing, misshapen, or
 *   an impossible calendar date ('2025-13-45'), rather than reading the host clock
 *   (which would anchor the summary on the wrong day, or the wrong tax year, near
 *   midnight or outside UTC).
 * @property {string} timezone           REQUIRED IANA zone (`config.timezone`). The active
 *   tax year is the calendar year of `asOfDate` IN THIS ZONE, resolved through
 *   {@link resolveTaxYear}. No default: computeTaxSummary THROWS when it is missing or
 *   not a selectable zone, rather than letting the host zone answer (issue #31).
 * @property {number} [taxYearOverride]  the user's explicit `config.tax_year` (AC #6).
 *   When set it pins the active year; when absent the year is derived from `asOfDate`.
 * @property {never} [taxYear]           REMOVED (#17). Passing it THROWS. The active tax
 *   year is derived, never supplied — a stored year is the staleness bug this rule exists
 *   to kill. Use `taxYearOverride` for a deliberate `config.tax_year` pin.
 * @property {string} [filingStatus]     overrides profile.filingStatus for the summary.
 * @property {ScheduleCLineInput[]} [scheduleCLines] YTD Schedule-C activity by line (dollars).
 * @property {number} [itemizedDeductionsTotal] YTD sum of Schedule-A itemizable deductions (dollars).
 * @property {number} [medicalExpenses]  YTD unreimbursed medical expenses (dollars).
 * @property {number} [agi]              adjusted gross income (dollars) for the 7.5% medical floor.
 * @property {object} [priorCumulative]  a computeEstimate() snapshot through the PRIOR
 *   quarter's period end; when supplied, the next quarter's estimate is the exact
 *   incremental liability, otherwise the conservative full cumulative liability.
 * @property {YtdData} [priorYearClose]  the PRIOR tax year's YTD figures, carrying their
 *   own `asOfDate` (where that year's books were cut). REQUIRED only during the year
 *   changeover — a review dated on or after Jan 1 but before the prior year's wrapping
 *   quarterly due date, when both tax years are live (issue #17). Its `filingStatus`,
 *   `timezone` and `taxYearOverride` are ignored: the prior year and the filing status
 *   both come from the active review's already-resolved boundary.
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
 * @property {object} meta               { taxYear, filingStatus, asOfDate, taxYearLabel } —
 *   `taxYear` is the RESOLVED active year ({@link resolveTaxYear}), not an echo of an
 *   input; `taxYearLabel` is the report-header string (e.g. 'Tax Year 2025') built from
 *   it, naming BOTH years during the changeover (issue #17). These two are the report
 *   header's only sanctioned source.
 * @property {object} yearBoundary       the {@link YearBoundary} state plus `priorYearClose`
 *   — the prior tax year's close-out summary (same shape, minus its own `yearBoundary`)
 *   while that year is still open, otherwise null. The summary's own figures are the
 *   NEW year's opening state.
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
// a caller bug — fail loud, never guess). This keeps the profile-taking exports consistent:
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

// --- Public facade surface (exactly six named exports) -----------------------

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
 * @returns {EffectiveProfileResult} the loadProfile result.
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
 * @param {object} [options] forwarded to classify (minConfidence, rules,
 *   userRules, thresholds — pass loadThresholds() from lib/tax/confidence.mjs
 *   to honour the user's configured confidence bands).
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
 * @param {object} [options] forwarded to classify (minConfidence, rules,
 *   userRules, thresholds — pass loadThresholds() from lib/tax/confidence.mjs
 *   to honour the user's configured confidence bands).
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
 * getQuarterlyDueDates). `ytdData` carries the pre-aggregated YTD figures and MUST
 * supply `asOfDate` and `timezone` — the engine never reads the host clock or the
 * host zone for either.
 *
 * THE ACTIVE TAX YEAR (#17). The year is DERIVED here, through
 * {@link resolveTaxYear}, from `ytdData.asOfDate` + `ytdData.timezone` (with
 * `ytdData.taxYearOverride` — the user's `config.tax_year` — pinning it when set).
 * It is never read off a stored field: `ytdData.taxYear` now THROWS, and
 * `profile.taxYear` is not consulted. `meta.taxYear` is therefore the resolution's
 * output, and `meta.taxYearLabel` is the report header built from it.
 *
 * THE YEAR BOUNDARY (#17). Every summary carries `yearBoundary` and a
 * `meta.taxYearLabel` header string, both derived from the active tax year and the
 * profile's own quarterly schedule — never from the budget's display name. While
 * the prior tax year's wrapping quarterly payment has not yet come due (early
 * January), BOTH years are live: this summary body is the new year's OPENING state,
 * and `yearBoundary.priorYearClose` carries the prior year's close-out figures in
 * the same shape. In that window `ytdData.priorYearClose` is REQUIRED — a summary
 * that quietly dropped the close-out would look complete while hiding a whole tax
 * year of unfinished figures.
 *
 * @param {object} profile loadEffectiveProfile() result.
 * @param {YtdData} [ytdData] pre-aggregated YTD figures (all dollars); must carry
 *   a 'YYYY-MM-DD' `asOfDate` and an IANA `timezone`.
 * @returns {TaxSummary} the Section-12 summary.
 * @throws {Error} when `asOfDate` is missing, is not a 'YYYY-MM-DD' string, or names
 *   a date the calendar does not have (e.g. '2025-02-30'); when `timezone` is missing
 *   or not a selectable IANA zone; when `taxYearOverride` is not a four-digit integer;
 *   when the removed `ytdData.taxYear` is passed; when neither the profile nor `ytdData`
 *   resolves a filingStatus; or when the review falls in the year-changeover window
 *   without `ytdData.priorYearClose`.
 */
export function computeTaxSummary(profile, ytdData = {}) {
  const p = rawProfile(profile);
  const filingStatus = ytdData.filingStatus ?? (p && p.filingStatus);
  const asOfDate = ytdData.asOfDate;

  // Refuse a SUPPLIED tax year outright (#17). Accepting one — from ytdData or from
  // profile.taxYear — is what let a stale stored year drive the whole summary: come
  // January the field still says last year, every figure is labelled with it, and
  // nothing in the output distinguishes that from a correct answer. A caller still
  // passing it is on the old path and gets told, not silently corrected; a deliberate
  // pin goes through `taxYearOverride`, which is the documented `config.tax_year` seam.
  if (ytdData.taxYear !== undefined) {
    throw new Error(
      `computeTaxSummary no longer accepts ytdData.taxYear (got ${JSON.stringify(ytdData.taxYear)}). ` +
        'The active tax year is DERIVED from ytdData.asOfDate + ytdData.timezone via resolveTaxYear, ' +
        'never supplied — a stored year silently keeps answering last year once the calendar rolls ' +
        "over. To pin a year deliberately, pass the user's config.tax_year as ytdData.taxYearOverride.",
    );
  }

  // Fail loud when the summary lacks a resolvable filing status: it drives the
  // standard deduction and the income-tax brackets, so without it the composed
  // figures are silently wrong. It comes from the resolved profile or ytdData —
  // the engine never guesses it.
  if (typeof filingStatus !== 'string' || filingStatus.length === 0) {
    throw new Error(
      'computeTaxSummary requires a resolvable filingStatus (non-empty string); got ' +
        `${JSON.stringify(filingStatus)}. Supply it via the resolved profile or ytdData — ` +
        'the engine must never guess it.',
    );
  }

  // Fail loud when the caller omits the 'as of' anchor. This USED to fall back to
  // the host clock in UTC (`new Date()`), which silently anchored the tax year and
  // the next quarterly due date on whatever day/timezone the process happened to
  // run in — exactly the near-midnight / wrong-tax-year class of bug the review
  // date path exists to kill (#31). The anchor is a caller input, never an ambient
  // read. The anchor must be a REAL calendar date in the exact 'YYYY-MM-DD' shape,
  // and both halves of that are load-bearing, not cosmetic — the due-date search
  // below (`d.date >= asOfDate`) is a LEXICOGRAPHIC string compare against the
  // profile's own bare 'YYYY-MM-DD' due dates:
  //   * a different shape ('5/1/2025', a Date, a number, or a full ISO timestamp)
  //     is not comparable with them, and
  //   * an impossible-but-well-shaped date is worse, because it compares happily:
  //     '2025-13-45' sorts after every real 2025 due date ('1' > '0' in the month
  //     position), so the search skips Q1–Q3 and answers Q4 — a wrong next payment
  //     indistinguishable from a right one at the call site.
  // So the exact-shape check is paired with epochDay() (./civilDate.mjs), the shared
  // strict parser that round-trips through Date.UTC and rejects dates the calendar
  // does not have ('2025-13-45', '2025-02-30', '2025-02-29' in a non-leap year).
  if (typeof asOfDate !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(asOfDate) || epochDay(asOfDate) === null) {
    throw new Error(
      'computeTaxSummary requires an explicit ytdData.asOfDate — a real calendar date ' +
        `in 'YYYY-MM-DD' form; got ${JSON.stringify(asOfDate)}. Supply the caller's own ` +
        'resolved date — the engine never reads the host clock, which would anchor the ' +
        'summary on the wrong day (or wrong tax year) near midnight or outside UTC.',
    );
  }

  // --- The active tax year: DERIVED, never supplied (#17) ---------------------
  // The one call that makes "the report header is sourced exclusively from
  // resolveTaxYear" true rather than aspirational — every figure below, the
  // due-date schedule, and meta.taxYearLabel all hang off this single resolution.
  //
  // Why the timezone is required even though asOfDate is ALREADY a civil date in
  // the configured zone (so the conversion inside resolveTaxYear is the identity):
  // it is the caller's proof that it resolved that date in a configured zone rather
  // than off the host clock. resolveTaxYear applies the same zone gate at every
  // entry point, with no per-caller carve-out — a carve-out here is exactly how the
  // host zone leaks back in and answers the wrong year on Dec 31 / Jan 1.
  const taxYear = resolveTaxYear(asOfDate, ytdData.timezone, ytdData.taxYearOverride);

  const summary = summarize(profile, ytdData, taxYear, filingStatus, asOfDate);

  // --- Year boundary: is the PRIOR tax year still open? (#17) -----------------
  // The window is derived from the profile's own quarterly schedule (the quarter
  // whose due date wraps past the calendar year end), so no tax deadline is
  // hardcoded here. asOfDate is a civil date already resolved in the configured
  // timezone by contract, so it needs no second conversion.
  const boundary = yearBoundaryForCivilDate(asOfDate, taxYear, p && p.quarterlyEstimatedDueDates);
  let priorYearClose = null;
  if (boundary.inChangeover) {
    const close = ytdData.priorYearClose;
    if (close === null || typeof close !== 'object' || Array.isArray(close)) {
      throw new Error(
        `computeTaxSummary requires ytdData.priorYearClose for a review on ${asOfDate}: tax year ` +
          `${boundary.priorTaxYear} is still open (its final estimated payment is not due until ` +
          `${boundary.changeoverThrough}), so the report must show that year's close-out alongside ` +
          `tax year ${taxYear}'s opening figures. Supply the prior year's YTD figures + its own ` +
          'asOfDate — omitting them would render a complete-looking report that hides a whole tax year.',
      );
    }
    if (
      typeof close.asOfDate !== 'string' ||
      !/^\d{4}-\d{2}-\d{2}$/.test(close.asOfDate) ||
      epochDay(close.asOfDate) === null
    ) {
      throw new Error(
        'computeTaxSummary requires ytdData.priorYearClose.asOfDate — a real calendar date in ' +
          `'YYYY-MM-DD' form marking where the prior tax year's figures were cut; got ` +
          `${JSON.stringify(close.asOfDate)}. The engine never invents that anchor.`,
      );
    }
    // Same refusal as the active year's, applied to the sibling site: the close-out's
    // year is the boundary's `priorTaxYear`, so a `taxYear` here expresses an intent
    // that would be silently ignored. Reject it rather than let the caller believe a
    // stale field steered the close-out.
    if (close.taxYear !== undefined) {
      throw new Error(
        `computeTaxSummary no longer accepts a tax year on ytdData.priorYearClose (got ` +
          `${JSON.stringify(close.taxYear)}). The close-out year is derived from the boundary — it is ` +
          `tax year ${boundary.priorTaxYear} for a review on ${asOfDate} — never read off a stored field.`,
      );
    }
    // Straight to the shared core, never back through computeTaxSummary: the close-out
    // gets the identical Schedule C/A/medical/SE shape with no chance of re-entering
    // the boundary branch.
    priorYearClose = summarize(profile, close, boundary.priorTaxYear, filingStatus, close.asOfDate);
  }

  return {
    ...summary,
    yearBoundary: { ...boundary, priorYearClose },
    meta: { ...summary.meta, taxYearLabel: boundary.headerLabel },
  };
}

// The Section-12 figures for ONE tax year, with the tax year, filing status and
// 'as of' anchor already resolved and validated by computeTaxSummary. Shared by the
// active year and — during the January changeover — the prior year's close-out, so
// both are guaranteed to carry the same shape.
function summarize(profile, ytdData, taxYear, filingStatus, asOfDate) {
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
