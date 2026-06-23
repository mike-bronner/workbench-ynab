// lib/tax/estimatedTax.mjs — the workbench-ynab quarterly estimated-tax tracker
// (issue #82, M6-4).
//
// WHAT THIS IS
//   The stateful backbone that promotes the prototype's regenerated "quarterly
//   estimated tax" paragraph into a first-class, persisted tracker. It holds two
//   concerns behind one cohesive module (mirroring loadProfile.mjs's "everything
//   for this concern, well-documented, in one file" shape):
//
//   1. PURE TAX MATH — Schedule C net, self-employment tax, the half-SE-tax
//      deduction, and marginal-bracket income tax — all driven entirely by the
//      resolved tax profile (lib/tax/loadProfile.mjs). NOTHING about rates,
//      brackets, thresholds, or due dates is hardcoded here; every number comes
//      from the profile/config so the engine stays generic and shareable.
//   2. TRACKER STATE — read/write of the out-of-repo state file
//      ~/.claude/plugins/data/workbench-ynab-claude-workbench/tax-tracker.json,
//      idempotent per-quarter estimate upserts that PRESERVE recorded payments,
//      reconciliation of estimated-tax payments already in YNAB, and a
//      read-only "## YTD Tax Summary" render the weekly review skill can embed
//      WITHOUT re-running any YNAB query or tax math.
//
// WHO CALLS THIS — AND THE YNAB NAMESPACING REMINDER
//   The /ynab-tax skill (skills/estimated-tax/SKILL.md), never the vendored YNAB
//   MCP. The transactions passed to summarizeBusinessActivity / detectPayments
//   are ALREADY fetched by the skill with the namespaced tools
//   mcp__plugin_workbench-ynab_ynab__* (e.g. ynab_list_transactions) — NOT
//   mcp__ynab__*. The math functions are MCP-agnostic: they read plain objects.
//
// MONEY UNITS
//   YNAB transaction amounts are MILLIUNITS (1000 milliunits = $1); every
//   amount this module reads off a transaction is divided by 1000 to DOLLARS
//   before any arithmetic. Every figure stored in the tracker and every figure
//   in the profile is already in DOLLARS. See assets/tax/README.md.
//
// PURITY
//   The compute functions (scheduleCNet, selfEmploymentTax, incomeTax,
//   computeEstimate, quarterlyEstimate, quarterForDate, quarterForPaymentDate,
//   isEstimatedTaxPayment,
//   detectPayments, summarizeBusinessActivity, upsertQuarterEstimate,
//   reconcilePayments, renderYtdSummary) are PURE — no I/O, no globals. Only
//   loadTracker / saveTracker touch the filesystem, both behind explicit path
//   seams (options.trackerPath / options.dataDir / env) exactly like loadProfile.
//
// NOT TAX ADVICE
//   This estimates side-hustle estimated taxes from your own YNAB data and your
//   own config. It is not a substitute for professional tax advice.

import { readFileSync, existsSync, mkdirSync, writeFileSync, renameSync, rmSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';

import classify from './classifyTransaction.mjs';

// Out-of-repo data dir, mirroring loadProfile.mjs / workbench-core. Overridable
// for tests via YNAB_DATA_DIR / YNAB_TAX_TRACKER_FILE, same seam style as the
// loader's YNAB_TAX_PROFILE_FILE.
const DATA_DIR_REL = join('.claude', 'plugins', 'data', 'workbench-ynab-claude-workbench');
const TRACKER_FILENAME = 'tax-tracker.json';

// Bump only on a breaking change to the on-disk tracker shape, so a future
// migration can detect and upgrade older files (same intent as the profile's
// schemaVersion).
export const TRACKER_SCHEMA_VERSION = 1;

// --- Money helpers ----------------------------------------------------------

// Round to whole cents. All stored/returned dollar figures pass through this so
// floating-point dust never accumulates in the persisted tracker.
function cents(n) {
  return Math.round((Number(n) || 0) * 100) / 100;
}

// YNAB milliunits → dollars. A non-numeric amount becomes 0 (never NaN).
function milliToDollars(milli) {
  return typeof milli === 'number' && Number.isFinite(milli) ? milli / 1000 : 0;
}

// --- Transaction normalization ----------------------------------------------

// Read a YNAB transaction tolerantly (snake_case or camelCase), returning the
// fields the tracker needs. Mirrors classifyTransaction.mjs's normalizer so the
// two stay consistent. `amountDollars` is signed (YNAB: outflow negative).
function normalizeTransaction(tx) {
  const t = tx && typeof tx === 'object' ? tx : {};
  const milli = typeof t.amount === 'number' ? t.amount
    : typeof t.amount_milliunits === 'number' ? t.amount_milliunits
      : null;
  return {
    id: t.id ?? t.transaction_id ?? t.transactionId ?? null,
    date: t.date ?? t.dateISO ?? null,
    payee: t.payee_name ?? t.payeeName ?? t.payee ?? null,
    categoryName: t.category_name ?? t.categoryName ?? null,
    categoryGroup: t.category_group_name ?? t.categoryGroupName ?? t.categoryGroup ?? null,
    accountName: t.account_name ?? t.accountName ?? null,
    amountDollars: milli === null ? null : milliToDollars(milli),
  };
}

// --- Pure tax math ----------------------------------------------------------

/**
 * Schedule C net profit: gross business income minus deductible business
 * expenses (both in dollars). Can be negative (a loss); downstream tax
 * functions clamp at zero where the IRS would.
 */
export function scheduleCNet({ grossIncome = 0, deductibleExpenses = 0 } = {}) {
  return cents(grossIncome - deductibleExpenses);
}

/**
 * Self-employment tax. Per the issue AC this is `Schedule C net × SE_rate`,
 * where SE_rate comes from the profile (thresholds.seTaxRate, default 0.153). A
 * net at or below zero owes no SE tax.
 *
 * @param {number} net    Schedule C net (dollars).
 * @param {number} seRate combined SE rate as a fraction (e.g. 0.153).
 */
export function selfEmploymentTax(net, seRate) {
  const base = Math.max(0, Number(net) || 0);
  return cents(base * (Number(seRate) || 0));
}

/**
 * Marginal-bracket income tax on a taxable base (dollars). Brackets are the
 * ascending [{ upTo?, rate }] array from the profile; the top bracket omits
 * `upTo` (unbounded). A base at or below zero owes no income tax.
 *
 * @param {number} taxableIncome taxable base in dollars.
 * @param {Array<{upTo?:number,rate:number}>} brackets ascending marginal brackets.
 */
export function incomeTax(taxableIncome, brackets) {
  const income = Math.max(0, Number(taxableIncome) || 0);
  if (income === 0 || !Array.isArray(brackets) || brackets.length === 0) return 0;
  let tax = 0;
  let lower = 0;
  for (const b of brackets) {
    if (income <= lower) break;
    const upper = typeof b.upTo === 'number' ? b.upTo : Infinity;
    const sliceTop = Math.min(income, upper);
    tax += (sliceTop - lower) * (Number(b.rate) || 0);
    lower = upper;
  }
  return cents(tax);
}

/**
 * Compute a CUMULATIVE estimated-tax snapshot for one income level. Every input
 * that produced the number is returned alongside it (the `computed_inputs` the
 * issue requires) so the estimate is explainable from the stored data alone —
 * no recomputation needed to show the work.
 *
 * Model (documented; all data-driven, none hardcoded):
 *   scheduleCNet   = grossIncome − deductibleExpenses
 *   seTax          = max(0, scheduleCNet) × seTaxRate
 *   halfSeDeduction= seTax ÷ 2                       (applied BEFORE income tax)
 *   incomeTaxBase  = max(0, scheduleCNet − halfSeDeduction)
 *   incomeTax      = marginal brackets applied to incomeTaxBase
 *   totalLiability = seTax + incomeTax
 *
 * The standard deduction is intentionally NOT subtracted here: this estimates
 * the tax on side-hustle earnings stacked on top of other (already
 * deduction-absorbing) household income, so the brackets apply from the first
 * dollar of net. The figure is a conservative working estimate, not a return.
 *
 * @param {object} args
 * @param {number} args.grossIncome        gross business income YTD (dollars).
 * @param {number} args.deductibleExpenses deductible business expenses YTD (dollars).
 * @param {number} args.seRate             SE rate fraction (profile thresholds.seTaxRate).
 * @param {Array}  args.brackets           ascending marginal income-tax brackets.
 * @param {object} [args.meta]             extra context to fold into computed inputs
 *   (e.g. { taxYear, filingStatus, throughDate }).
 * @returns {object} the cumulative estimate + its inputs.
 */
export function computeEstimate({ grossIncome = 0, deductibleExpenses = 0, seRate = 0, brackets = [], meta = {} } = {}) {
  const net = scheduleCNet({ grossIncome, deductibleExpenses });
  const seTax = selfEmploymentTax(net, seRate);
  const halfSeDeduction = cents(seTax / 2);
  const incomeTaxBase = cents(Math.max(0, net - halfSeDeduction));
  const tax = incomeTax(incomeTaxBase, brackets);
  return {
    grossIncome: cents(grossIncome),
    deductibleExpenses: cents(deductibleExpenses),
    scheduleCNet: net,
    seTaxRate: Number(seRate) || 0,
    seTax,
    halfSeDeduction,
    incomeTaxBase,
    incomeTax: tax,
    totalLiability: cents(seTax + tax),
    ...meta,
  };
}

/**
 * Derive one quarter's INCREMENTAL estimate from the cumulative estimate through
 * that quarter's income-period end and the cumulative estimate through the prior
 * quarter's period end. The quarter's `quarterLiability` is the marginal tax on
 * the income earned in that quarter alone — exactly what a quarterly estimated
 * payment covers — while the full cumulative snapshot rides along in
 * `computed_inputs` so the math stays auditable.
 *
 * @param {object}      cumulative      computeEstimate() through this quarter's period end.
 * @param {object|null} priorCumulative computeEstimate() through the prior quarter's
 *   period end, or null for Q1 (nothing precedes it).
 * @returns {object} cumulative snapshot augmented with priorCumulativeLiability +
 *   quarterLiability.
 */
export function quarterlyEstimate(cumulative, priorCumulative = null) {
  const priorLiability = priorCumulative ? cents(priorCumulative.totalLiability) : 0;
  return {
    ...cumulative,
    priorCumulativeLiability: priorLiability,
    quarterLiability: cents(Math.max(0, cumulative.totalLiability - priorLiability)),
  };
}

// --- Quarter attribution ----------------------------------------------------

// month*100 + day, a comparable integer for an in-year date window.
function md(month, day) {
  return month * 100 + day;
}

/**
 * Which estimated-tax quarter (1–4) an in-year date falls in, using the UNEVEN
 * income-attribution boundaries stored in the profile's quarterlyEstimatedDueDates
 * (periodStartMonth/Day…periodEndMonth/Day). Falls back to the standard month
 * mapping (Q1 Jan–Mar, Q2 Apr–May, Q3 Jun–Aug, Q4 Sep–Dec) for entries that omit
 * the boundaries. Returns null when no quarter contains the date.
 *
 * @param {string} dateISO  YYYY-MM-DD.
 * @param {Array}  dueDates profile.quarterlyEstimatedDueDates (raw or resolved).
 */
export function quarterForDate(dateISO, dueDates) {
  if (typeof dateISO !== 'string') return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(dateISO);
  if (!m) return null;
  const point = md(Number(m[2]), Number(m[3]));
  for (const d of Array.isArray(dueDates) ? dueDates : []) {
    const hasPeriod = d.periodStartMonth != null && d.periodEndMonth != null;
    if (!hasPeriod) continue;
    const start = md(d.periodStartMonth, d.periodStartDay ?? 1);
    const end = md(d.periodEndMonth, d.periodEndDay ?? 31);
    if (point >= start && point <= end) return d.quarter;
  }
  // Fallback for boundary-less data: standard federal quarter months.
  const month = Number(m[2]);
  if (month <= 3) return 1;
  if (month <= 5) return 2;
  if (month <= 8) return 3;
  return 4;
}

/**
 * Which estimated-tax quarter (1–4) a PAYMENT date attributes to, by the IRS
 * DUE-DATE schedule (each quarter's `month`/`day` in the profile's
 * quarterlyEstimatedDueDates) — NOT the income-earning window. A payment belongs
 * to the quarter whose due date is the first due date on or after the payment
 * date — i.e. the quarter it is *paying toward* — INCLUDING the year-end rollover
 * where a payment on or before Q4's due date (Jan 15 of the next year) attributes
 * to that prior tax year's Q4. This is the case quarterForDate's income windows
 * miss: Jan 15 falls in no Q1–Q4 income period and would wrongly fall back to Q1.
 *
 * Distinct from quarterForDate, which attributes INCOME by its earning period.
 * The two are deliberately separate: the quarter an income transaction belongs to
 * is governed by when it was earned; the quarter a payment belongs to is governed
 * by when it was due. Returns null when the schedule carries no usable due dates.
 *
 * @param {string} dateISO  YYYY-MM-DD payment date.
 * @param {Array}  dueDates profile.quarterlyEstimatedDueDates (month/day per quarter).
 */
export function quarterForPaymentDate(dateISO, dueDates) {
  if (typeof dateISO !== 'string') return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(dateISO);
  if (!m) return null;
  const point = md(Number(m[2]), Number(m[3]));
  // Quarters are labelled 1–4 in chronological cycle order (Apr→Jun→Sep→Jan-next),
  // so sorting by quarter gives the cycle. Each quarter owns the window that ENDS
  // at its due date: (prevDue, thisDue]. The Q4→Q1 step wraps the calendar year.
  const schedule = (Array.isArray(dueDates) ? dueDates : [])
    .filter((d) => d && d.month != null && d.day != null && d.quarter != null)
    .map((d) => ({ quarter: d.quarter, dueMd: md(d.month, d.day) }))
    .sort((a, b) => a.quarter - b.quarter);
  if (schedule.length === 0) return null;
  for (let i = 0; i < schedule.length; i += 1) {
    const prev = schedule[(i - 1 + schedule.length) % schedule.length];
    const cur = schedule[i];
    const wraps = prev.dueMd > cur.dueMd; // window crosses the year end
    const inWindow = wraps
      ? (point > prev.dueMd || point <= cur.dueMd)
      : (point > prev.dueMd && point <= cur.dueMd);
    if (inWindow) return cur.quarter;
  }
  return null;
}

// --- Business-activity summarization (reuses the mapping engine) -------------

// Build a taxLineId → catalog-line lookup from the resolved profile's `lines`
// (merged in from us-tax-lines.json). Lets us read a classified line's schedule
// and income/expense category without duplicating the catalog here.
function lineIndex(profile) {
  const idx = new Map();
  for (const line of profile && Array.isArray(profile.lines) ? profile.lines : []) {
    if (line && typeof line.id === 'string') idx.set(line.id, line);
  }
  return idx;
}

function inWindow(dateISO, sinceISO, throughISO) {
  if (typeof dateISO !== 'string') return false;
  if (sinceISO && dateISO < sinceISO) return false;
  if (throughISO && dateISO > throughISO) return false;
  return true;
}

/**
 * Summarize Schedule C gross income and deductible expenses from already-fetched
 * YNAB transactions, REUSING the mapping engine (lib/tax/classifyTransaction.mjs)
 * to decide which transactions are business income vs deductible expense — so no
 * income/expense heuristic is duplicated or hardcoded here. A transaction counts
 * only when the classifier maps it to a Schedule C line in the profile's catalog
 * and its date is within [sinceISO, throughISO] (inclusive).
 *
 * @param {Array}  transactions already-fetched YNAB transactions (milliunits).
 * @param {object} profile      resolved tax profile (loadProfile().profile).
 * @param {object} [options]
 * @param {string} [options.sinceISO]   inclusive lower date bound (YYYY-MM-DD).
 * @param {string} [options.throughISO] inclusive upper date bound (YYYY-MM-DD).
 * @param {number} [options.minConfidence=0] passed through to classify().
 * @returns {{ grossIncome:number, deductibleExpenses:number, incomeCount:number,
 *   expenseCount:number, skipped:number }} dollar totals + counts.
 */
export function summarizeBusinessActivity(transactions, profile, options = {}) {
  const { sinceISO, throughISO, minConfidence = 0 } = options;
  const lines = lineIndex(profile);
  let grossIncome = 0;
  let deductibleExpenses = 0;
  let incomeCount = 0;
  let expenseCount = 0;
  let skipped = 0;

  for (const raw of Array.isArray(transactions) ? transactions : []) {
    const tx = normalizeTransaction(raw);
    if (!inWindow(tx.date, sinceISO, throughISO)) { skipped += 1; continue; }
    const result = classify(raw, profile, { minConfidence });
    const line = lines.get(result.taxLineId);
    if (!line || line.schedule !== 'C') { skipped += 1; continue; }
    const magnitude = Math.abs(tx.amountDollars ?? 0);
    if (line.category === 'income') { grossIncome += magnitude; incomeCount += 1; }
    else if (line.category === 'expense') { deductibleExpenses += magnitude; expenseCount += 1; }
    else skipped += 1;
  }

  return {
    grossIncome: cents(grossIncome),
    deductibleExpenses: cents(deductibleExpenses),
    incomeCount,
    expenseCount,
    skipped,
  };
}

// --- Estimated-tax payment detection ----------------------------------------

function ciIncludes(haystack, needle) {
  return typeof haystack === 'string' && typeof needle === 'string'
    && haystack.toLowerCase().includes(needle.toLowerCase());
}
function ciEquals(a, b) {
  return typeof a === 'string' && typeof b === 'string'
    && a.trim().toLowerCase() === b.trim().toLowerCase();
}

/**
 * Whether an already-fetched YNAB transaction is an estimated-tax PAYMENT, per
 * the profile's estimatedTaxPayments matchers. A payment is an OUTFLOW (negative
 * amount) whose payee contains any payeeKeywords entry (case-insensitive
 * substring) OR whose category / category-group / account matches any configured
 * name (case-insensitive exact). Inflows are never payments.
 *
 * @param {object} transaction already-fetched YNAB transaction.
 * @param {object} matchers    loadProfile().getEstimatedTaxPaymentMatchers().
 */
export function isEstimatedTaxPayment(transaction, matchers) {
  const tx = normalizeTransaction(transaction);
  if (!(typeof tx.amountDollars === 'number' && tx.amountDollars < 0)) return false;
  const m = matchers || {};
  const payeeHit = (m.payeeKeywords ?? []).some((kw) => ciIncludes(tx.payee, kw));
  const categoryHit = (m.categoryNames ?? []).some((c) => ciEquals(tx.categoryName, c));
  const groupHit = (m.categoryGroups ?? []).some((g) => ciEquals(tx.categoryGroup, g));
  const accountHit = (m.accounts ?? []).some((a) => ciEquals(tx.accountName, a));
  return payeeHit || categoryHit || groupHit || accountHit;
}

/**
 * Detect estimated-tax payments among already-fetched transactions and shape
 * each into the tracker's payment record, attributed to the quarter it pays
 * toward by the DUE-DATE schedule (quarterForPaymentDate, not the income window).
 * Skips transactions with no usable id or date (they cannot be deduped or
 * attributed).
 *
 * @param {Array}  transactions already-fetched YNAB transactions.
 * @param {object} matchers     estimatedTaxPayments matchers.
 * @param {Array}  dueDates     profile.quarterlyEstimatedDueDates (for attribution).
 * @returns {Array<{date:string, amount_usd:number, ynab_transaction_id:string, quarter:number}>}
 */
export function detectPayments(transactions, matchers, dueDates) {
  const out = [];
  for (const raw of Array.isArray(transactions) ? transactions : []) {
    if (!isEstimatedTaxPayment(raw, matchers)) continue;
    const tx = normalizeTransaction(raw);
    if (!tx.id || !tx.date) continue;
    const quarter = quarterForPaymentDate(tx.date, dueDates);
    if (!quarter) continue;
    out.push({
      date: tx.date,
      amount_usd: cents(Math.abs(tx.amountDollars ?? 0)),
      ynab_transaction_id: tx.id,
      quarter,
    });
  }
  return out;
}

// --- Tracker state ----------------------------------------------------------

/** Resolve the tracker file path from options/env, mirroring loadProfile. */
export function trackerPathFor(options = {}) {
  const env = options.env ?? process.env;
  if (options.trackerPath) return options.trackerPath;
  if (env.YNAB_TAX_TRACKER_FILE) return env.YNAB_TAX_TRACKER_FILE;
  const dataDir = options.dataDir ?? env.YNAB_DATA_DIR ?? join(homedir(), DATA_DIR_REL);
  return join(dataDir, TRACKER_FILENAME);
}

/** A fresh, empty tracker. */
export function emptyTracker() {
  return { schemaVersion: TRACKER_SCHEMA_VERSION, years: {} };
}

/** A fresh, empty quarter entry. */
function emptyQuarter() {
  return { estimated_liability: 0, payments: [], remaining_due: 0, computed_inputs: null };
}

// Ensure state.years[year][quarter] exists and return the quarter entry.
function ensureQuarter(state, year, quarter) {
  const y = String(year);
  const q = String(quarter);
  if (!state.years) state.years = {};
  if (!state.years[y]) state.years[y] = {};
  if (!state.years[y][q]) state.years[y][q] = emptyQuarter();
  return state.years[y][q];
}

function sumPayments(entry) {
  return cents((entry.payments ?? []).reduce((s, p) => s + (Number(p.amount_usd) || 0), 0));
}

// remaining_due = estimated_liability − payments recorded against the quarter
// (never below zero — an over-payment is a $0 remaining balance, not a credit).
function recomputeRemaining(entry) {
  entry.remaining_due = cents(Math.max(0, (Number(entry.estimated_liability) || 0) - sumPayments(entry)));
  return entry;
}

/**
 * Load the tracker from disk, or return a fresh empty tracker when the file does
 * not exist yet (the normal first-run path — the file is CREATED on first save).
 * A present-but-corrupt file THROWS rather than silently discarding a user's
 * recorded payment history.
 */
export function loadTracker(options = {}) {
  const path = trackerPathFor(options);
  if (!existsSync(path)) return emptyTracker();
  let text;
  try {
    text = readFileSync(path, 'utf8');
  } catch (err) {
    throw new Error(`tax tracker: cannot read ${path}: ${err.message}`);
  }
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch (err) {
    throw new Error(`tax tracker: invalid JSON in ${path}: ${err.message} (refusing to overwrite — fix or remove the file)`);
  }
  if (!parsed || typeof parsed !== 'object' || typeof parsed.years !== 'object') {
    throw new Error(`tax tracker: unexpected shape in ${path} (refusing to overwrite — fix or remove the file)`);
  }
  return parsed;
}

/**
 * Persist the tracker, creating the out-of-repo data dir on first run. Writes to
 * a sibling temp file then renames, so a crash mid-write can never leave a
 * truncated tracker. Returns the path written.
 *
 * This file holds personal financial data (income, payments, the full
 * computed_inputs snapshot), so it is written owner-only: the dir is created
 * 0700 and the file 0600, never world-readable on a shared box. On a failed
 * rename the orphaned temp file is removed so a half-written copy of that data
 * is never left lying around.
 */
export function saveTracker(state, options = {}) {
  const path = trackerPathFor(options);
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, `${JSON.stringify(state, null, 2)}\n`, { encoding: 'utf8', mode: 0o600 });
  try {
    renameSync(tmp, path);
  } catch (err) {
    rmSync(tmp, { force: true });
    throw err;
  }
  return path;
}

/**
 * Idempotently set a quarter's estimate. Re-running for the same year+quarter
 * OVERWRITES estimated_liability and computed_inputs (no duplicate entry) while
 * PRESERVING the recorded payments array, then recomputes remaining_due. Mutates
 * and returns `state`.
 *
 * @param {object} state    tracker state.
 * @param {object} args
 * @param {number|string} args.year
 * @param {number}        args.quarter  1–4.
 * @param {object}        args.estimate quarterlyEstimate() result (quarterLiability + inputs).
 */
export function upsertQuarterEstimate(state, { year, quarter, estimate } = {}) {
  const entry = ensureQuarter(state, year, quarter);
  // A quarter stores its MARGINAL liability (quarterLiability). Reject a raw
  // computeEstimate() result — it carries totalLiability (full YTD), not
  // quarterLiability, and silently storing that would quietly overstate the
  // quarter. Fail loudly so the misuse surfaces instead of producing a
  // wrong-but-plausible number.
  if (estimate != null && typeof estimate.quarterLiability !== 'number') {
    throw new Error('upsertQuarterEstimate: estimate must be a quarterlyEstimate() result with a numeric quarterLiability (pass a raw computeEstimate() through quarterlyEstimate() first)');
  }
  entry.estimated_liability = cents(estimate?.quarterLiability ?? 0);
  entry.computed_inputs = estimate ?? null;
  recomputeRemaining(entry);
  return state;
}

/**
 * Reconcile detected estimated-tax payments into the tracker. Each payment lands
 * in the quarter its date attributes to; a payment whose ynab_transaction_id is
 * already recorded for that quarter is skipped (idempotent — re-running never
 * double-counts). Affected quarters' remaining_due is recomputed. Mutates and
 * returns { state, added } where `added` is the count newly recorded.
 *
 * @param {object} state    tracker state.
 * @param {object} args
 * @param {number|string} args.year
 * @param {Array}  args.payments detectPayments() output ({…, quarter}).
 */
export function reconcilePayments(state, { year, payments = [] } = {}) {
  let added = 0;
  const touched = new Set();
  for (const p of Array.isArray(payments) ? payments : []) {
    if (!p || !p.ynab_transaction_id || !p.quarter) continue;
    const entry = ensureQuarter(state, year, p.quarter);
    if ((entry.payments ?? []).some((x) => x.ynab_transaction_id === p.ynab_transaction_id)) continue;
    entry.payments.push({
      date: p.date,
      amount_usd: cents(p.amount_usd),
      ynab_transaction_id: p.ynab_transaction_id,
    });
    touched.add(String(p.quarter));
    added += 1;
  }
  for (const q of touched) recomputeRemaining(state.years[String(year)][q]);
  return { state, added };
}

// --- YTD summary render (read-only, state-only) -----------------------------

function fmtUsd(n) {
  return `$${(Number(n) || 0).toFixed(2)}`;
}

/**
 * Render the "## YTD Tax Summary" markdown block for a tax year, read PURELY from
 * the tracker state — no YNAB query, no tax math. This is the export the weekly
 * review skill embeds by reference so it never recomputes the estimate. Returns
 * a friendly "no data yet" block when the year is absent.
 *
 * @param {object} state tracker state.
 * @param {object} args
 * @param {number|string} args.year
 * @returns {string} markdown.
 */
export function renderYtdSummary(state, { year } = {}) {
  const y = String(year);
  const yearData = state && state.years ? state.years[y] : undefined;
  const header = `## YTD Tax Summary (${y})`;
  if (!yearData) {
    return `${header}\n\n_No estimated-tax data recorded yet for ${y}. Run \`/ynab-tax\` to build it._\n`;
  }
  const lines = [header, '', '| Quarter | Estimated liability | Payments | Remaining due |', '| --- | --- | --- | --- |'];
  let totalLiability = 0;
  let totalPaid = 0;
  let totalRemaining = 0;
  for (const q of ['1', '2', '3', '4']) {
    const e = yearData[q];
    if (!e) {
      lines.push(`| Q${q} | — | — | — |`);
      continue;
    }
    const paid = (e.payments ?? []).reduce((s, p) => s + (Number(p.amount_usd) || 0), 0);
    totalLiability += Number(e.estimated_liability) || 0;
    totalPaid += paid;
    totalRemaining += Number(e.remaining_due) || 0;
    lines.push(`| Q${q} | ${fmtUsd(e.estimated_liability)} | ${fmtUsd(paid)} | ${fmtUsd(e.remaining_due)} |`);
  }
  lines.push(`| **YTD** | **${fmtUsd(totalLiability)}** | **${fmtUsd(totalPaid)}** | **${fmtUsd(totalRemaining)}** |`);
  lines.push('');
  lines.push('_Estimate from your YNAB data and tax profile — not tax advice._');
  lines.push('');
  return lines.join('\n');
}

export default {
  TRACKER_SCHEMA_VERSION,
  scheduleCNet,
  selfEmploymentTax,
  incomeTax,
  computeEstimate,
  quarterlyEstimate,
  quarterForDate,
  quarterForPaymentDate,
  summarizeBusinessActivity,
  isEstimatedTaxPayment,
  detectPayments,
  trackerPathFor,
  emptyTracker,
  loadTracker,
  saveTracker,
  upsertQuarterEstimate,
  reconcilePayments,
  renderYtdSummary,
};
