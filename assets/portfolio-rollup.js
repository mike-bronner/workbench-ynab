'use strict';

/**
 * portfolio-rollup.js — the cross-budget portfolio rollup math (M6-7, issue #85).
 *
 * WHAT THIS IS
 *   The dependency-free compute half of the portfolio rollup. The rollup skill
 *   (skills/review/portfolio-ynab-review.md) is the orchestration half: it reads
 *   the multi-budget config, pulls (or reuses) each budget's per-budget review
 *   output, and renders fragments. Every number it aggregates is computed HERE,
 *   so the cross-budget arithmetic is unit-testable instead of prose.
 *
 * MILLIUNITS ARE CONVERTED EXACTLY ONCE, AT INTAKE (AC#5).
 *   YNAB hands every amount in milliunits (1000 milliunits = 1 currency unit).
 *   `milliToCurrency` is the ONLY division in this module and every per-budget
 *   amount passes through it before it reaches a sum. No caller ever sums raw
 *   milliunits across budgets, and no total is ever re-divided downstream — the
 *   values this module returns are already in currency units.
 *
 * …WHICH IS WHY RENDERING GOES THROUGH `formatRollupMoney`, NOT `formatMoney`.
 *   The tree-wide money helper (assets/format-money.js) takes RAW MILLIUNITS and
 *   divides internally — "only DISPLAY divides" is its contract, and every other
 *   caller in the repo still holds milliunits at render time. This module's
 *   outputs do not: they were already converted at intake. Handing one to
 *   `formatMoney` divides a second time and renders every figure 1000× too small.
 *   `formatRollupMoney` IS that boundary — the single place the two conventions
 *   meet — so the skill never has to remember a ×1000 and no `* 1000` literal
 *   ever appears in prose. Call it for every rendered rollup amount.
 *
 * NEVER SUM ACROSS CURRENCIES.
 *   skills/review/ynab-review.md §5 is binding: mixed-currency budgets are
 *   reported in their own currency, never merged into one figure. Totals are
 *   therefore keyed by ISO code. When budgets disagree on currency the rollup
 *   reports per-currency subtotals plus a `mixed_currency` note and refuses to
 *   emit a single combined figure — a fabricated cross-currency total is worse
 *   than an honest "reported per currency".
 *
 * FAIL CLOSED.
 *   A malformed budgets entry is EXCLUDED with a named reason, never silently
 *   folded into a total. A non-finite amount becomes the `null` sentinel, never
 *   `NaN`/`Infinity` (the review-guards convention). An unrecognized severity
 *   throws rather than sorting a finding into invisibility.
 *
 * NOT A TAX ENGINE. `aggregateScheduleC` only SUMS per-budget Schedule C
 * figures. Every rate, bracket, and threshold stays in the tax-profile loader,
 * and the estimate itself is computed by lib/tax/estimatedTax.mjs — this module
 * holds zero tax constants.
 *
 * CommonJS + zero dependencies, matching assets/review-guards.js: it must run
 * under the plain `node --test` suite with NO node_modules present.
 */

const { overallHealthScore, NA_DISPLAY } = require('./review-guards.js');
const { formatMoney } = require('./format-money.js');

/** YNAB's fixed milliunit scale: 1000 milliunits = 1 currency unit. */
const MILLIUNITS_PER_UNIT = 1000;

/** The role (case-insensitive) whose budgets carry Schedule C activity. */
const BUSINESS_ROLE = 'business';

/**
 * The three dispatch severities, most severe first. The order of these keys IS
 * the ranking `orderFindings` applies, and the emoji match the frozen dispatch
 * contract in docs/dispatch-format.md (which the report badges mirror).
 * @type {Readonly<Record<string, string>>}
 */
const SEVERITY = Object.freeze({
  ACTION_REQUIRED: 'action-required',
  ATTENTION: 'attention',
  GOOD: 'good',
});

/** Severity → the dispatch emoji prefix (docs/dispatch-format.md). */
const SEVERITY_EMOJI = Object.freeze({
  [SEVERITY.ACTION_REQUIRED]: '🔴',
  [SEVERITY.ATTENTION]: '🟡',
  [SEVERITY.GOOD]: '🟢',
});

/** Most-severe-first rank. Lower sorts earlier. */
const SEVERITY_RANK = Object.freeze({
  [SEVERITY.ACTION_REQUIRED]: 0,
  [SEVERITY.ATTENTION]: 1,
  [SEVERITY.GOOD]: 2,
});

/**
 * The named reasons a configured budget is excluded from the rollup. Surfaced
 * to the user as a dispatch note so an excluded budget is always visible — a
 * silently dropped budget would understate net worth.
 * @type {Readonly<Record<string, string>>}
 */
const EXCLUSION_REASONS = Object.freeze({
  NOT_AN_OBJECT: 'not_an_object',
  MISSING_LABEL: 'missing_label',
  MISSING_ROLE: 'missing_role',
  MISSING_BUDGET_REF: 'missing_budget_ref',
});

/** Rollup-level notes the skill carries into the dispatch summary. */
const ROLLUP_NOTES = Object.freeze({
  MIXED_CURRENCY: 'mixed_currency',
  NO_READY_TO_ASSIGN: 'no_ready_to_assign',
  NO_BUDGETS: 'no_budgets',
  NO_BUSINESS_BUDGET: 'no_business_budget',
});

const isNonEmptyString = (v) => typeof v === 'string' && v.trim() !== '';
const asArray = (v) => (Array.isArray(v) ? v : []);

/**
 * The module's ONE milliunits → currency-units conversion (AC#5). Non-finite
 * input yields the `null` sentinel rather than `NaN`, so a missing field can
 * never poison a total.
 * @param {number} milliunits raw YNAB milliunits.
 * @returns {number|null} the amount in currency units, or `null`.
 */
function milliToCurrency(milliunits) {
  if (!Number.isFinite(milliunits)) return null;
  return milliunits / MILLIUNITS_PER_UNIT;
}

/**
 * THE DISPLAY BOUNDARY — render any amount this module returns.
 *
 * Takes an amount in CURRENCY UNITS (what `aggregatePortfolio` /
 * `aggregateScheduleC` return) and produces the display string, converting back
 * to the milliunits `formatMoney` expects. It is the inverse of the intake
 * conversion, applied once, in code rather than in prose: renderers never write
 * a `* 1000`, and `formatMoney` is never called directly with a rollup total
 * (which would divide a second time and render every figure 1000× too small).
 *
 * FAILS CLOSED ON THE SENTINEL. `null` — the module's "no data" value — renders
 * as `"n/a"`, NOT as `formatMoney`'s non-finite fallback of `$0.00`. A masking
 * zero would read as "this budget has nothing" when the truth is "nothing was
 * measured"; the `n/a` string keeps that distinction visible and matches the
 * review-guards display convention.
 *
 * Rounds to whole milliunits before formatting, honouring `formatMoney`'s
 * "raw integer milliunits" contract: the float produced by ÷1000 then ×1000 can
 * land a hair off an integer, and `formatMoney` documents integer input.
 *
 * @param {number|null} amount an amount in currency units, or the `null` sentinel.
 * @param {object} [currencyFormat] that currency's YNAB `currency_format`
 *   (`currencyFormats[iso]`); USD default when omitted.
 * @returns {string} the formatted amount, or `"n/a"`.
 */
function formatRollupMoney(amount, currencyFormat) {
  if (!Number.isFinite(amount)) return NA_DISPLAY;
  return formatMoney(Math.round(amount * MILLIUNITS_PER_UNIT), currencyFormat);
}

/**
 * Normalize a role for comparison. Roles are free-form in the config schema, so
 * they are matched case-insensitively and whitespace-trimmed.
 * @param {*} role
 * @returns {string} the normalized role, or `''` when absent/not a string.
 */
function normalizeRole(role) {
  return isNonEmptyString(role) ? role.trim().toLowerCase() : '';
}

/**
 * AC#2 — split the configured `budgets` array into the entries the rollup will
 * read and the malformed entries it refuses to read.
 *
 * The `budgets` array IS the enabled set: the config schema defines it as "the
 * YNAB budgets this plugin operates on", and the two per-budget booleans it
 * carries (`monitoring_enabled`, `write_back_enabled`) gate the monitor and the
 * write-back path — NOT this read-only report. No budget id or label is
 * hardcoded here; every value comes from the caller's config.
 *
 * An entry is included only when it carries a non-empty `label`, a non-empty
 * `role`, and at least one of `budget_id` / `budget_name` (the schema's own
 * requirements). Anything else is excluded with a named reason so the skill can
 * surface it — excluding a real budget silently would understate every total.
 *
 * @param {Array} budgets the `budgets` array from bin/config.sh `_cfg_budgets`.
 * @returns {{included: Array<object>, excluded: Array<{entry: *, reason: string}>}}
 */
function selectBudgets(budgets) {
  const included = [];
  const excluded = [];
  for (const entry of asArray(budgets)) {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) {
      excluded.push({ entry, reason: EXCLUSION_REASONS.NOT_AN_OBJECT });
    } else if (!isNonEmptyString(entry.label)) {
      excluded.push({ entry, reason: EXCLUSION_REASONS.MISSING_LABEL });
    } else if (!isNonEmptyString(entry.role)) {
      excluded.push({ entry, reason: EXCLUSION_REASONS.MISSING_ROLE });
    } else if (!isNonEmptyString(entry.budget_id) && !isNonEmptyString(entry.budget_name)) {
      excluded.push({ entry, reason: EXCLUSION_REASONS.MISSING_BUDGET_REF });
    } else {
      included.push(entry);
    }
  }
  return { included, excluded };
}

/**
 * AC#6 — the `business`-tagged subset of already-selected budgets, matched on
 * the normalized `role`. These are the budgets whose Schedule C activity the
 * consolidated tax view aggregates.
 * @param {Array<object>} selected entries from `selectBudgets().included`.
 * @returns {Array<object>}
 */
function businessBudgets(selected) {
  return asArray(selected).filter((b) => b && normalizeRole(b.role) === BUSINESS_ROLE);
}

/**
 * Resolve a per-budget snapshot's ISO currency code. Absent/blank falls back to
 * the sentinel `'UNKNOWN'` so it groups separately and trips the mixed-currency
 * guard instead of silently joining the USD pile.
 * @param {object} snapshot
 * @returns {string}
 */
function isoCodeOf(snapshot) {
  const cf = snapshot && typeof snapshot.currency_format === 'object' ? snapshot.currency_format : null;
  return cf && isNonEmptyString(cf.iso_code) ? cf.iso_code.trim().toUpperCase() : 'UNKNOWN';
}

/**
 * Add a converted amount into an accumulator, ignoring the `null` sentinel — an
 * absent amount leaves the accumulator untouched, so a bucket that received no
 * data at all stays at `null` (its "n/a") rather than falling to a masking `0`.
 * That surviving `null` is what makes each bucket its own per-currency
 * data-presence flag; no caller needs a separate accumulator to track it.
 */
function accumulate(bucket, key, milliunits) {
  const value = milliToCurrency(milliunits);
  if (value === null) return;
  bucket[key] = (bucket[key] === null ? 0 : bucket[key]) + value;
}

/**
 * AC#4/#5 — roll per-budget snapshots into the portfolio summary: combined
 * account balances / net worth, aggregate income vs spending (and the resulting
 * net cash flow), cross-budget Ready-to-Assign, and one unified health score.
 *
 * Every amount arrives in MILLIUNITS and is converted once, here, before it is
 * summed. Totals are keyed by ISO currency code and are NEVER merged across
 * currencies; `mixedCurrency` tells the renderer to show per-currency subtotals
 * and carry the `mixed_currency` note.
 *
 * The unified health score is the mean of each budget's own 0–100 overall score
 * (each budget counts once, regardless of how many sections it could measure).
 * A budget whose sub-scores are all `null` — nothing measurable — is excluded;
 * when no budget is measurable the score is `null`, which renders as `n/a` with
 * no `role="meter"` gauge (the review-guards sentinel convention).
 *
 * @param {Array<object>} snapshots per-budget snapshots, each:
 *   `{label, role, currency_format, netWorthMilli, incomeMilli, spendingMilli,
 *     readyToAssignMilli, healthSubScores}` — amounts in milliunits,
 *   `healthSubScores` an array of 1–10 sub-scores (or `null`s).
 * @returns {{budgetCount:number, currencies:string[], mixedCurrency:boolean,
 *   currencyFormats:Object, totals:Object, healthScore:number|null,
 *   perBudget:Array<object>, notes:string[]}}
 */
function aggregatePortfolio(snapshots) {
  const list = asArray(snapshots).filter((s) => s && typeof s === 'object');
  // NULL-PROTOTYPE, deliberately: these are data maps keyed by `iso_code`, which
  // is off-the-wire YNAB data. `isoCodeOf` already upper-cases every key, so no
  // key can currently collide with `__proto__` (whose setter would swallow the
  // bucket instead of creating an own property). The null prototype makes that
  // safety a property of the map rather than of the normalization: a future
  // change to how ISO codes are normalized cannot reopen the hole, and no
  // inherited key (`constructor`, `toString`, …) can ever masquerade as a
  // currency bucket. The trade is nil — both are written and read by key only.
  const totals = Object.create(null);
  const currencyFormats = Object.create(null);
  const perBudget = [];
  const notes = [];

  for (const snapshot of list) {
    const iso = isoCodeOf(snapshot);
    if (!totals[iso]) {
      // `readyToAssign` starts at the `null` sentinel: a currency whose budgets
      // all lack Ready-to-Assign data must render `n/a`, not a masking 0.
      totals[iso] = { netWorth: 0, income: 0, spending: 0, netCashFlow: 0, readyToAssign: null };
      currencyFormats[iso] = snapshot.currency_format || null;
    }
    const bucket = totals[iso];
    accumulate(bucket, 'netWorth', snapshot.netWorthMilli);
    accumulate(bucket, 'income', snapshot.incomeMilli);
    accumulate(bucket, 'spending', snapshot.spendingMilli);
    accumulate(bucket, 'readyToAssign', snapshot.readyToAssignMilli);

    perBudget.push({
      label: snapshot.label,
      role: normalizeRole(snapshot.role),
      isoCode: iso,
      netWorth: milliToCurrency(snapshot.netWorthMilli),
      income: milliToCurrency(snapshot.incomeMilli),
      spending: milliToCurrency(snapshot.spendingMilli),
      readyToAssign: milliToCurrency(snapshot.readyToAssignMilli),
      healthScore: overallHealthScore(asArray(snapshot.healthSubScores)),
    });
  }

  // Net cash flow is derived from the already-converted totals — never a second
  // pass over raw milliunits.
  for (const iso of Object.keys(totals)) {
    totals[iso].netCashFlow = totals[iso].income - totals[iso].spending;
  }

  const currencies = Object.keys(totals).sort();
  const mixedCurrency = currencies.length > 1;
  if (mixedCurrency) notes.push(ROLLUP_NOTES.MIXED_CURRENCY);

  // Ready-to-Assign absence is judged PER CURRENCY, not globally. Each bucket's
  // `readyToAssign` sits at the `null` sentinel exactly when no budget in THAT
  // currency contributed the data, so the bucket IS the per-currency flag — no
  // separate accumulator can drift from it. A global "did any budget anywhere
  // report RTA" would leave one currency's `n/a` column unexplained whenever
  // another currency happened to have data. The note fires when ANY currency
  // lacks it; the renderer reads `totals[iso].readyToAssign === null` per column
  // to say which.
  const someCurrencyLacksReadyToAssign = currencies.some((iso) => totals[iso].readyToAssign === null);
  if (list.length === 0) notes.push(ROLLUP_NOTES.NO_BUDGETS);
  else if (someCurrencyLacksReadyToAssign) notes.push(ROLLUP_NOTES.NO_READY_TO_ASSIGN);

  const budgetScores = perBudget.map((b) => b.healthScore).filter((v) => Number.isFinite(v));
  const healthScore = budgetScores.length === 0
    ? null
    : Math.round(budgetScores.reduce((a, b) => a + b, 0) / budgetScores.length);

  return {
    budgetCount: list.length,
    currencies,
    mixedCurrency,
    currencyFormats,
    totals,
    healthScore,
    perBudget,
    notes,
  };
}

/**
 * AC#6 — aggregate Schedule C activity across the `business`-tagged budgets into
 * ONE set of figures for the M6-4 quarterly-tax tracker, rather than a per-budget
 * fragment each.
 *
 * Amounts arrive in milliunits and are converted once, here. The result feeds
 * `computeEstimate({grossIncome, deductibleExpenses, …})` from
 * lib/tax/estimatedTax.mjs — this function performs no tax math and holds no tax
 * constants.
 *
 * MIXED CURRENCY IS REFUSED, NOT SUMMED. The tax engine is US-only and
 * dollar-denominated; adding a EUR business budget onto a USD one would corrupt
 * every downstream figure. When the business budgets disagree on currency,
 * `grossIncome` / `deductibleExpenses` / `net` are all `null` and
 * `mixedCurrency` is set — the skill then renders the tax view unavailable
 * instead of publishing a wrong number.
 *
 * @param {Array<object>} snapshots business-budget snapshots, each
 *   `{label, currency_format, scheduleCIncomeMilli, scheduleCExpensesMilli}`.
 * @returns {{budgetCount:number, currencies:string[], mixedCurrency:boolean,
 *   grossIncome:number|null, deductibleExpenses:number|null, net:number|null,
 *   perBudget:Array<object>, notes:string[]}}
 */
function aggregateScheduleC(snapshots) {
  const list = asArray(snapshots).filter((s) => s && typeof s === 'object');
  const notes = [];
  const perBudget = list.map((s) => ({
    label: s.label,
    isoCode: isoCodeOf(s),
    grossIncome: milliToCurrency(s.scheduleCIncomeMilli),
    deductibleExpenses: milliToCurrency(s.scheduleCExpensesMilli),
  }));
  const currencies = [...new Set(perBudget.map((b) => b.isoCode))].sort();
  const mixedCurrency = currencies.length > 1;

  if (list.length === 0) notes.push(ROLLUP_NOTES.NO_BUSINESS_BUDGET);
  if (mixedCurrency) notes.push(ROLLUP_NOTES.MIXED_CURRENCY);

  if (list.length === 0 || mixedCurrency) {
    return {
      budgetCount: list.length,
      currencies,
      mixedCurrency,
      grossIncome: null,
      deductibleExpenses: null,
      net: null,
      perBudget,
      notes,
    };
  }

  const sum = (key) => perBudget.reduce((acc, b) => acc + (b[key] === null ? 0 : b[key]), 0);
  const grossIncome = sum('grossIncome');
  const deductibleExpenses = sum('deductibleExpenses');
  return {
    budgetCount: list.length,
    currencies,
    mixedCurrency,
    grossIncome,
    deductibleExpenses,
    net: grossIncome - deductibleExpenses,
    perBudget,
    notes,
  };
}

/**
 * AC#9 — order cross-budget findings most-severe first, preserving the caller's
 * order within a severity (a stable sort, so the skill's own impact ranking
 * survives inside each band).
 *
 * An unrecognized severity THROWS rather than being sorted to the end: a finding
 * the ranker cannot place would be silently buried below the healthy ones, which
 * is exactly the fail-open behaviour a severity ranking must not have.
 *
 * @param {Array<{severity: string}>} findings findings from every budget.
 * @returns {Array<object>} a new array, most-severe first.
 * @throws {TypeError} when a finding carries a severity outside `SEVERITY`.
 */
function orderFindings(findings) {
  const list = asArray(findings);
  for (const finding of list) {
    const severity = finding && finding.severity;
    if (!Object.prototype.hasOwnProperty.call(SEVERITY_RANK, severity)) {
      throw new TypeError(
        `orderFindings: unrecognized severity ${JSON.stringify(severity)} — expected one of: ${Object.values(SEVERITY).join(', ')}`,
      );
    }
  }
  return [...list].sort((a, b) => SEVERITY_RANK[a.severity] - SEVERITY_RANK[b.severity]);
}

module.exports = {
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
};
