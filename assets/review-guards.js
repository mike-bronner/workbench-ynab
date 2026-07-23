'use strict';

/**
 * review-guards.js — the empty-state / degenerate-budget guard module for the
 * workbench-ynab universal review (issue #33, GAP-4).
 *
 * The universal review skill (skills/review/ynab-review.md) computes health
 * scores, ratios, and percentages from an already-fetched YNAB snapshot. Those
 * computations divide — savings rate, threshold percentages, category-increase
 * comparisons, the six health sub-scores — and a brand-new / zero-transaction /
 * no-business budget makes every denominator zero. Without a guard, the first
 * run of a fresh user produces `NaN` health scores, `Infinity` percentages, and
 * empty tables where a finding should be.
 *
 * This module is the single, dependency-free source of truth for:
 *
 *   1. THE DEGENERATE-STATE ENUMERATION (AC#1). `DEGENERATE_STATES` names every
 *      empty/degenerate budget condition; `detectDegenerateStates(snapshot)`
 *      reports which are active for a given snapshot, so the skill knows exactly
 *      which empty-state paths to render.
 *   2. THE DIVIDE-BY-ZERO GUARDS (AC#3/#4). `ratio`, `percentOf`, `savingsRate`,
 *      `changePercent`, and the health-score helpers all return the sentinel
 *      `null` (never `NaN`, never `Infinity`, never a throw) on a zero/absent
 *      denominator or an empty dataset. Display helpers render `null` as the
 *      documented string `"n/a"`.
 *   3. THE BUSINESS-TAX GATE (AC#5/#6). `businessTaxSectionMode` decides whether
 *      the Schedule C/SE sections are omitted (with a one-line note), rendered as
 *      an empty-state slot, or rendered in full.
 *   4. THE DISPATCH FINDINGS PLAN (AC#7). `dispatchFindingsPlan` defines dispatch
 *      behavior for zero findings (skip, emit a "No findings this period"
 *      summary) and one-to-four findings (proceed as-is, never pad to five).
 *   5. THE CANONICAL EMPTY-STATE STRINGS (AC#2). `EMPTY_STATE_MESSAGES` and
 *      `NO_BUSINESS_ENTITY_NOTE` are the exact slot text the skill, the report
 *      fragments, and the golden-snapshot test all read — one source, no drift.
 *
 * PURE + DEPENDENCY-FREE. Every export is a pure function or a frozen constant
 * over plain data — it calls no tool, fetches nothing, mutates nothing — so the
 * module stays importable with no install step (docs/testing.md offline
 * constraint) and is exhaustively unit-tested in tests/unit/review-guards.test.mjs.
 *
 * SENTINEL CONVENTION. The math guards return `null` — the semantic "no defined
 * result". A renderer turns that into the display string `"n/a"` via `orNa` /
 * `formatPercent` / `formatHealthScore`. Both forms are the AC-approved sentinel
 * (`null` or `"n/a"`); neither is ever `NaN` or `Infinity`.
 *
 * NOT A TAX ENGINE, NOT A RANKING ALGORITHM. This module only guards arithmetic
 * and enumerates empty states. It holds zero tax constants (those live in the
 * tax-profile loader) and no finding-ranking logic (that is the review skill's).
 */

/** The display string every guarded-but-degenerate value renders as. */
const NA_DISPLAY = 'n/a';

/**
 * AC#1 — the enumerated degenerate budget states. Every empty/degenerate
 * condition the review must handle explicitly is named here, so the skill and
 * the tests reference one canonical set instead of ad-hoc string literals.
 * @type {Readonly<Record<string, string>>}
 */
const DEGENERATE_STATES = Object.freeze({
  ZERO_ACCOUNTS: 'zero_accounts',
  ZERO_TRANSACTIONS: 'zero_transactions',
  ZERO_UNCATEGORIZED: 'zero_uncategorized',
  NO_READY_TO_ASSIGN: 'no_ready_to_assign',
  NO_BUSINESS_GROUP: 'no_business_group',
  NO_PRIOR_MONTH: 'no_prior_month',
  NEW_BUDGET: 'new_budget',
});

/**
 * AC#2 — the canonical empty-state slot messages. The exact strings the skill
 * renders, the snapshot fragments carry, and the golden-snapshot test asserts —
 * kept here so all three read the same source and can never drift apart.
 * @type {Readonly<Record<string, string>>}
 */
const EMPTY_STATE_MESSAGES = Object.freeze({
  NO_TRANSACTIONS: 'No transactions in this window',
  NO_FINDINGS: 'No findings this period',
});

/** AC#5 — the one-line note that replaces the tax sections when no business entity is configured. */
const NO_BUSINESS_ENTITY_NOTE = 'No business entity configured — tax sections skipped';

/** AC#5/#6 — how the business-tax (Schedule C/SE) sections render. */
const BUSINESS_TAX_MODE = Object.freeze({
  OMIT: 'omit', // no business entity configured → omit both sections, emit the one-line note
  EMPTY_STATE: 'empty-state', // configured but zero matching transactions → empty-state slot + n/a gauge
  RENDER: 'render', // configured + matching transactions → full tax sections
});

/** AC#7 — how the dispatch summary handles a below-five (or zero) finding count. */
const DISPATCH_MODE = Object.freeze({
  NONE: 'none', // zero findings → dispatch skipped, a "No findings this period" summary emitted
  AS_IS: 'as-is', // 1–4 findings → render exactly those, never pad to five
  TOP_FIVE: 'top-five', // ≥5 findings → the fixed five-finding contract
});

const asArray = (v) => (Array.isArray(v) ? v : []);

/**
 * AC#1 — report which degenerate states are active for a normalized budget
 * snapshot. A pure classifier over plain fields, so the skill can branch on the
 * result and the tests can assert each state fires (and clears) independently.
 *
 * @param {object} [snapshot]
 * @param {Array}  [snapshot.accounts]              on/off-budget accounts
 * @param {Array}  [snapshot.transactions]          transactions in the window
 * @param {Array}  [snapshot.months]                months with history/rollup data
 * @param {number} [snapshot.uncategorizedCount]    count of uncategorized transactions
 * @param {number|null} [snapshot.readyToAssign]    Ready-to-Assign balance (null/absent ⇒ no data)
 * @param {*}      [snapshot.businessCategoryGroup] the matched business category group (falsy ⇒ none)
 * @returns {string[]} the active `DEGENERATE_STATES` values, in enumeration order.
 */
function detectDegenerateStates(snapshot) {
  const s = snapshot && typeof snapshot === 'object' ? snapshot : {};
  const accounts = asArray(s.accounts);
  const transactions = asArray(s.transactions);
  const months = asArray(s.months);
  // A count if given; otherwise fall back to the transaction list (a missing
  // count on an empty window is still zero uncategorized).
  const uncategorized = Number.isFinite(s.uncategorizedCount)
    ? s.uncategorizedCount
    : transactions.filter((t) => t && (t.category_id == null && t.category_name == null)).length;

  const active = [];
  if (accounts.length === 0) active.push(DEGENERATE_STATES.ZERO_ACCOUNTS);
  if (transactions.length === 0) active.push(DEGENERATE_STATES.ZERO_TRANSACTIONS);
  if (uncategorized === 0) active.push(DEGENERATE_STATES.ZERO_UNCATEGORIZED);
  // A finite balance (including 0 — "every dollar has a job") is data; only an
  // absent/null Ready-to-Assign is the degenerate "no data" state.
  if (!Number.isFinite(s.readyToAssign)) active.push(DEGENERATE_STATES.NO_READY_TO_ASSIGN);
  if (!s.businessCategoryGroup) active.push(DEGENERATE_STATES.NO_BUSINESS_GROUP);
  if (months.length < 2) active.push(DEGENERATE_STATES.NO_PRIOR_MONTH);
  if (months.length === 0) active.push(DEGENERATE_STATES.NEW_BUDGET);
  return active;
}

/**
 * AC#4 — the one guarded division every other ratio is built on. Returns `null`
 * (the sentinel) when the denominator is zero or either operand is non-finite;
 * otherwise the quotient. Never `NaN`, never `Infinity`, never a throw.
 * @param {number} numerator
 * @param {number} denominator
 * @returns {number|null}
 */
function ratio(numerator, denominator) {
  if (!Number.isFinite(numerator) || !Number.isFinite(denominator) || denominator === 0) return null;
  return numerator / denominator;
}

/**
 * AC#4 — a percentage (0–100 scale) guarded against a zero/absent whole.
 * @param {number} part
 * @param {number} whole
 * @returns {number|null} `part / whole * 100`, or `null` when `whole` is zero/absent.
 */
function percentOf(part, whole) {
  const r = ratio(part, whole);
  return r === null ? null : r * 100;
}

/**
 * AC#4 — savings rate = net saved / income. Zero or absent income ⇒ `null`.
 * @param {number} net
 * @param {number} income
 * @returns {number|null}
 */
function savingsRate(net, income) {
  return ratio(net, income);
}

/**
 * AC#4 — period-over-period percentage change against a prior base (e.g. a
 * category-increase comparison). A zero or absent prior base has no defined
 * percentage change ⇒ `null` (never a divide-by-zero `Infinity`).
 * @param {number} current
 * @param {number} prior
 * @returns {number|null} `((current - prior) / prior) * 100`, or `null`.
 */
function changePercent(current, prior) {
  if (!Number.isFinite(current) || !Number.isFinite(prior) || prior === 0) return null;
  return ((current - prior) / prior) * 100;
}

/**
 * AC#3 — convert a guarded 0..1 ratio (e.g. categorization completeness) into a
 * 1–10 health sub-score. A `null` ratio (degenerate/empty dataset) yields a
 * `null` sub-score — never a `0` that would masquerade as "measured and bad",
 * and never `NaN`.
 * @param {number|null} ratioValue a 0..1 ratio, or `null` when undefined.
 * @returns {number|null} an integer 1..10, or `null`.
 */
function subScore(ratioValue) {
  if (ratioValue === null || !Number.isFinite(ratioValue)) return null;
  const clamped = Math.min(Math.max(ratioValue, 0), 1);
  return Math.round(1 + clamped * 9);
}

/**
 * AC#3 — roll the six 1–10 sub-scores into one overall 0–100 health score.
 * `null` sub-scores (degenerate/absent sections) are excluded from the mean;
 * when EVERY sub-score is `null` — nothing is measurable, e.g. a brand-new
 * budget — the overall score is `null` (renders `"n/a"`), never `NaN`.
 * @param {Array<number|null>} subScores
 * @returns {number|null} an integer 0..100, or `null`.
 */
function overallHealthScore(subScores) {
  const present = asArray(subScores).filter((v) => Number.isFinite(v));
  if (present.length === 0) return null;
  const meanOfTen = present.reduce((a, b) => a + b, 0) / present.length; // 1..10
  return Math.round(meanOfTen * 10); // → 0..100
}

/**
 * AC#5/#6 — decide how the business-tax (Schedule C/SE) sections render.
 * @param {object} [opts]
 * @param {boolean} [opts.businessConfigured]        whether a business entity is configured
 * @param {number}  [opts.matchingTransactionCount]  business transactions in the window
 * @returns {'omit'|'empty-state'|'render'}
 */
function businessTaxSectionMode({ businessConfigured, matchingTransactionCount } = {}) {
  if (!businessConfigured) return BUSINESS_TAX_MODE.OMIT;
  const n = Number.isFinite(matchingTransactionCount) ? matchingTransactionCount : 0;
  return n > 0 ? BUSINESS_TAX_MODE.RENDER : BUSINESS_TAX_MODE.EMPTY_STATE;
}

/**
 * AC#7 — decide how the dispatch summary handles the finding count.
 * Zero (or a non-positive / non-finite count, fail-closed) ⇒ skip the dispatch
 * and emit a "No findings this period" summary. One-to-four ⇒ render exactly
 * those, no padding. Five or more ⇒ the fixed five-finding contract.
 * @param {number} findingCount
 * @returns {{mode: string, count: number, summary?: string}}
 */
function dispatchFindingsPlan(findingCount) {
  const n = Number.isFinite(findingCount) && findingCount > 0 ? Math.trunc(findingCount) : 0;
  if (n === 0) return { mode: DISPATCH_MODE.NONE, count: 0, summary: EMPTY_STATE_MESSAGES.NO_FINDINGS };
  if (n < 5) return { mode: DISPATCH_MODE.AS_IS, count: n };
  return { mode: DISPATCH_MODE.TOP_FIVE, count: 5 };
}

/**
 * Render a guarded numeric result for display: a finite number is returned
 * as-is; `null` / `undefined` / `NaN` / `Infinity` become the string `"n/a"`.
 * @param {number|null|undefined} value
 * @returns {number|string}
 */
function orNa(value) {
  return Number.isFinite(value) ? value : NA_DISPLAY;
}

/**
 * Render a guarded percentage for display: `null`/non-finite ⇒ `"n/a"`, else a
 * fixed-decimal string like `"12.3%"`.
 * @param {number|null} value the percentage value (already on a 0–100 scale).
 * @param {number} [digits] decimal places (default 1).
 * @returns {string}
 */
function formatPercent(value, digits = 1) {
  if (!Number.isFinite(value)) return NA_DISPLAY;
  return `${value.toFixed(digits)}%`;
}

/**
 * Render a guarded overall health score for a KPI value: `null`/non-finite ⇒
 * `"n/a"`, else `"78/100"`. A `"n/a"` health score has no numeric gauge — the
 * renderer omits the `role="meter"` progress bar rather than emit a meter with
 * a `NaN` value (see the a11y contract in assets/report/SLOTS.md).
 * @param {number|null} value an integer 0..100, or `null`.
 * @returns {string}
 */
function formatHealthScore(value) {
  return Number.isFinite(value) ? `${value}/100` : NA_DISPLAY;
}

module.exports = {
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
};
