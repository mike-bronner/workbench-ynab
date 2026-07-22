// lib/monitor/detectors.mjs — the four between-run alert detectors (issue #81, M6-3).
//
// WHAT THIS IS
//   The substance of proactive monitoring: four focused detectors that turn a
//   monitoring pass's fresh YNAB data into structured findings, plus the ledger
//   reconciliation that decides which findings are NEW (worth dispatching) and
//   which conditions have cleared (their dedupe keys expire). Detectors decide
//   WHAT is alert-worthy; lib/monitor/alerts.mjs owns the finding contract,
//   thresholds, and delivery; lib/monitor/state.mjs owns the dedupe ledger.
//
//     overdrawn        — an on-budget account below its floor.        🔴 action
//     large / unusual  — a new transaction over the amount threshold,
//                        or over unusual_multiplier × its category's
//                        trailing mean.                    🟡 attention (🔴 huge)
//     budget overrun   — a category at/over budget_overrun_pct.       🟡 attention
//     bill due         — an upcoming bill within the lookahead window. 🟡 attention
//
// PURE BY CONTRACT
//   Like state.mjs and alerts.mjs, this module performs NO YNAB calls and NO
//   network / file IO. The monitor SKILL fetches the data through the vendored
//   MCP (tool names resolved from skills/protocol/ynab-tools.md — never inlined
//   here) and passes it in; the detectors compute findings from that data alone.
//   Keeping them pure keeps every detector unit-testable off a fixture and keeps
//   raw MCP tool names out of this file (bin/check-tool-name-sources.sh).
//
// MONEY UNITS
//   Every YNAB amount arriving here is MILLIUNITS (integers). Config thresholds
//   were already converted to milliunits at the alerts.mjs boundary
//   (largeTransactionMilliunits), so amount comparisons stay integer-exact with
//   no float drift. Milliunits are converted to whole dollars only for the
//   human-facing finding text (milliunitsToDollars) — never for a comparison.
//
// TRUST BOUNDARY
//   YNAB responses are external input: a malformed account / transaction /
//   category (missing or wrong-typed field) is SKIPPED, never dereferenced into
//   a throw — an unattended monitor pass must survive a surprising payload.
//
// STDOUT / STDERR DISCIPLINE
//   This module emits NOTHING to stdout — it returns structured results. One
//   stray stdout byte on an MCP / JSON-RPC path corrupts the handshake (same
//   note as state.mjs / alerts.mjs).

import { ACTION, ATTENTION, dedupeKey } from './alerts.mjs';
import { milliunitsToDollars, recordFiredAlert, expireFiredAlerts } from './state.mjs';

// --- Documented algorithm constants -------------------------------------------

/**
 * Trailing-average window for the "unusual" test: a transaction is compared
 * against the mean of the last N transactions in the SAME category (matched by
 * `category_id`). Kept small, fixed, and explainable per the AC — not a config
 * knob (the `alerts` block owns thresholds; N is an algorithm parameter, and
 * YAGNI says don't add a config surface nothing asked to tune).
 */
export const TRAILING_WINDOW = 10;

/**
 * Severity-upgrade ceiling for a large transaction: at or above this MULTIPLE of
 * the configured `large_transaction_amount` a transaction is 🔴 (action) rather
 * than 🟡 (attention). Derived from the configured threshold — not an independent
 * hard-coded dollar figure — so it still honours "thresholds come from config":
 * change `large_transaction_amount` and the ceiling scales with it.
 */
export const HARD_CEILING_MULTIPLE = 10;

/**
 * Condition types whose keys EXPIRE when the condition clears. These detectors
 * re-evaluate their whole domain every poll (all accounts, all current-month
 * categories, all upcoming bills), so a key absent from a pass's active set has
 * genuinely cleared. `large_txn` is deliberately absent: it names a specific
 * transaction (a point event that never un-happens), and the incremental-cursor
 * window can't attest a past one cleared — so its keys persist.
 */
export const EXPIRING_TYPES = Object.freeze(['overdrawn', 'budget_overrun', 'bill_due']);

// --- Small helpers ------------------------------------------------------------

const isFiniteNumber = (v) => typeof v === 'number' && Number.isFinite(v);
const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

/** Render milliunits as a whole-dollar display string, e.g. `$1,234.56` / `-$50.00`. */
function formatDollars(milliunits) {
  const dollars = milliunitsToDollars(milliunits);
  const sign = dollars < 0 ? '-' : '';
  return `${sign}$${Math.abs(dollars).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

// --- Detector 1: overdrawn account --------------------------------------------

/**
 * Flag any ON-BUDGET account whose balance is below the floor (default 0 — YNAB
 * has no separate floor config, so the `overdrawn` boolean is the on/off switch
 * and 0 is the floor). Closed / deleted / off-budget accounts are excluded.
 * Severity 🔴 (an overdrawn account is money already lost to fees). One finding
 * per affected account; `dedupe_key` is `overdrawn:{account_id}`.
 *
 * @param {Array<object>} accounts  YNAB accounts: { id, name, balance (milliunits),
 *   on_budget, closed, deleted }.
 * @param {object} config  the loaded alerts config (alerts.mjs loadAlertsConfig shape).
 * @returns {Array<object>} findings (empty when `config.overdrawn` is false).
 */
export function detectOverdrawn(accounts, config) {
  if (!config?.overdrawn || !Array.isArray(accounts)) return [];
  const FLOOR = 0;
  const findings = [];
  for (const a of accounts) {
    if (!isObject(a) || typeof a.id !== 'string') continue;
    if (a.on_budget !== true || a.closed === true || a.deleted === true) continue;
    if (!isFiniteNumber(a.balance) || a.balance >= FLOOR) continue;
    const name = typeof a.name === 'string' && a.name ? a.name : a.id;
    findings.push({
      severity: ACTION,
      title: `${name} is overdrawn at ${formatDollars(a.balance)}`,
      detail: `On-budget account ${a.id} balance ${a.balance} milliunits (${formatDollars(a.balance)}) is below the ${FLOOR} floor.`,
      suggested_action: `Move funds to cover ${name} or reconcile pending transactions before overdraft fees hit.`,
      dedupe_key: `overdrawn:${a.id}`,
    });
  }
  return findings;
}

// --- Detector 2: large / unusual transaction ----------------------------------

/** Mean of up to the first N finite numbers in `amounts` (most-recent-first). */
function trailingMean(amounts, n) {
  if (!Array.isArray(amounts)) return null;
  const window = amounts.filter(isFiniteNumber).slice(0, n);
  if (window.length === 0) return null;
  return window.reduce((sum, v) => sum + v, 0) / window.length;
}

/**
 * Flag each NEW transaction (the caller passes only the incremental-cursor
 * window) that is either LARGE — magnitude ≥ `largeTransactionMilliunits` — or
 * UNUSUAL — magnitude > `unusualMultiplier` × the trailing mean magnitude of the
 * last {@link TRAILING_WINDOW} same-category transactions. Outflows are negative
 * milliunits, so magnitude (`Math.abs`) is compared. Severity 🟡, upgraded to 🔴
 * at or above {@link HARD_CEILING_MULTIPLE} × the large threshold. A transaction
 * with no `category_id` gets the large check only (no category → no trailing
 * mean). `dedupe_key` is `large_txn:{transaction_id}`.
 *
 * @param {Array<object>} transactions  new YNAB transactions: { id, amount
 *   (milliunits), payee_name, category_id, category_name }.
 * @param {object} history  map of category_id → array of prior same-category
 *   amounts (milliunits, most-recent-first) for the trailing mean. `{}` when the
 *   caller has no history for a category.
 * @param {object} config  the loaded alerts config.
 * @returns {Array<object>} findings.
 */
export function detectLargeUnusualTransactions(transactions, history, config) {
  if (!Array.isArray(transactions) || !config) return [];
  const large = config.largeTransactionMilliunits;
  const multiplier = config.unusualMultiplier;
  const hist = isObject(history) ? history : {};
  const findings = [];
  for (const t of transactions) {
    if (!isObject(t) || typeof t.id !== 'string' || !isFiniteNumber(t.amount)) continue;
    const magnitude = Math.abs(t.amount);
    const isLarge = isFiniteNumber(large) && magnitude >= large;

    const mean = typeof t.category_id === 'string' ? trailingMean(hist[t.category_id], TRAILING_WINDOW) : null;
    const isUnusual = mean !== null && isFiniteNumber(multiplier) && Math.abs(mean) > 0
      && magnitude > multiplier * Math.abs(mean);

    if (!isLarge && !isUnusual) continue;

    const severity = isFiniteNumber(large) && magnitude >= HARD_CEILING_MULTIPLE * large ? ACTION : ATTENTION;
    const payee = typeof t.payee_name === 'string' && t.payee_name ? t.payee_name : 'an unknown payee';
    const category = typeof t.category_name === 'string' && t.category_name ? t.category_name : 'its category';
    const reason = isUnusual && !isLarge
      ? `Unusual transaction: ${formatDollars(t.amount)} at ${payee} (${(magnitude / Math.abs(mean)).toFixed(1)}× typical for ${category})`
      : `Large transaction: ${formatDollars(t.amount)} at ${payee}`;
    findings.push({
      severity,
      title: reason,
      detail: `Transaction ${t.id}: ${t.amount} milliunits (${formatDollars(t.amount)}) at ${payee}`
        + `${isUnusual ? `, ${(magnitude / Math.abs(mean)).toFixed(1)}× the trailing mean of the last ${TRAILING_WINDOW} ${category} transactions` : ''}.`,
      suggested_action: `Confirm you recognize this ${formatDollars(t.amount)} transaction; flag it with your bank if it wasn't you.`,
      dedupe_key: `large_txn:${t.id}`,
    });
  }
  return findings;
}

// --- Detector 3: budget overrun -----------------------------------------------

/**
 * Flag any category whose spend has crossed `budgetOverrunPct`% of its budgeted
 * amount for `month`. `activity` is spend as a negative milliunit figure, so the
 * ratio is `|activity| / budgeted`. Categories with no positive budget are
 * skipped — an overrun *percentage* is undefined without a budget to divide by
 * (fail closed on the division rather than inventing a ratio). Hidden / deleted
 * categories are skipped. Severity 🟡. `dedupe_key` is
 * `budget_overrun:{category_id}:{YYYY-MM}`.
 *
 * @param {Array<object>} categories  YNAB categories: { id, name, budgeted
 *   (milliunits), activity (milliunits), hidden, deleted }.
 * @param {object} config  the loaded alerts config.
 * @param {object} options
 * @param {string} options.month  the current month as `YYYY-MM` (the dedupe period).
 * @returns {Array<object>} findings.
 */
export function detectBudgetOverrun(categories, config, options = {}) {
  if (!Array.isArray(categories) || !config) return [];
  const pct = config.budgetOverrunPct;
  const month = typeof options.month === 'string' ? options.month : '';
  if (!isFiniteNumber(pct) || !month) return [];
  const findings = [];
  for (const c of categories) {
    if (!isObject(c) || typeof c.id !== 'string') continue;
    if (c.hidden === true || c.deleted === true) continue;
    if (!isFiniteNumber(c.budgeted) || c.budgeted <= 0 || !isFiniteNumber(c.activity)) continue;
    const spent = Math.abs(Math.min(c.activity, 0));
    const ratioPct = (spent / c.budgeted) * 100;
    if (ratioPct < pct) continue;
    const name = typeof c.name === 'string' && c.name ? c.name : c.id;
    findings.push({
      severity: ATTENTION,
      title: `${name} is at ${Math.round(ratioPct)}% of budget`,
      detail: `Category ${c.id} spent ${formatDollars(spent)} of ${formatDollars(c.budgeted)} budgeted `
        + `(${Math.round(ratioPct)}% ≥ ${pct}% threshold) for ${month}.`,
      suggested_action: `Review ${name} spending or move money to cover the overage this month.`,
      dedupe_key: dedupeKey('budget_overrun', c.id, month),
    });
  }
  return findings;
}

// --- Detector 4: bill due -----------------------------------------------------

/** Whole days from `now` (inclusive) to a `YYYY-MM-DD` date, in UTC. `null` when
 *  the date is unparseable OR calendar-invalid — a bad date is skipped, never
 *  treated as "due now". `Date.parse` silently ROLLS OVER a day-overflow or a
 *  truncated string (`2026-02-30` → `2026-03-02`, `2026-07` → `2026-07-01`), which
 *  the GAP-3 history-derived "30th/31st" bills hit in short months; that would
 *  fire on an impossible day and bake it into the dedupe key. So we require the
 *  parse to ROUND-TRIP to the exact 10-char `YYYY-MM-DD` given, rejecting rollovers
 *  (an invalid month like `2026-13-01` already yields NaN). */
function daysUntil(dateStr, now) {
  if (typeof dateStr !== 'string') return null;
  const ymd = dateStr.slice(0, 10);
  const due = Date.parse(`${ymd}T00:00:00Z`);
  if (Number.isNaN(due)) return null;
  if (new Date(due).toISOString().slice(0, 10) !== ymd) return null;
  const today = Date.parse(`${new Date(now).toISOString().slice(0, 10)}T00:00:00Z`);
  if (Number.isNaN(today)) return null;
  return Math.round((due - today) / 86_400_000);
}

/**
 * Flag any upcoming bill due within `billDueLookaheadDays` (0 ≤ days ≤ lookahead;
 * a bill already past is not "upcoming"). The vendored MCP exposes no
 * scheduled-transactions tool (docs/decisions/GAP-3-scheduled-transactions.md),
 * so the SKILL DERIVES `upcomingBills` from recurring history and documents that
 * limitation — this detector consumes the derived entries and is agnostic to
 * their source. Severity 🟡. `dedupe_key` is `bill_due:{id}:{due_date}` (the
 * per-occurrence date keeps a monthly bill re-alerting each cycle).
 *
 * @param {Array<object>} upcomingBills  derived bills: { id, name, date
 *   (`YYYY-MM-DD`), amount (milliunits) }.
 * @param {object} config  the loaded alerts config.
 * @param {object} options
 * @param {string|number|Date} options.now  the reference "today" (default now).
 * @returns {Array<object>} findings.
 */
export function detectBillsDue(upcomingBills, config, options = {}) {
  if (!Array.isArray(upcomingBills) || !config) return [];
  const lookahead = config.billDueLookaheadDays;
  if (!Number.isInteger(lookahead) || lookahead < 0) return [];
  const now = options.now ?? new Date();
  const findings = [];
  for (const b of upcomingBills) {
    if (!isObject(b) || typeof b.id !== 'string' || typeof b.date !== 'string') continue;
    const days = daysUntil(b.date, now);
    if (days === null || days < 0 || days > lookahead) continue;
    const name = typeof b.name === 'string' && b.name ? b.name : b.id;
    const amount = isFiniteNumber(b.amount) ? ` (${formatDollars(b.amount)})` : '';
    const when = days === 0 ? 'today' : days === 1 ? 'tomorrow' : `in ${days} days`;
    findings.push({
      severity: ATTENTION,
      title: `${name}${amount} is due ${when}`,
      detail: `Upcoming bill ${b.id} "${name}"${amount} due ${b.date.slice(0, 10)} (${days} day(s) out; `
        + `derived from history — scheduled-transactions data unavailable, see GAP-3).`,
      suggested_action: `Make sure the paying account can cover ${name} by ${b.date.slice(0, 10)}.`,
      dedupe_key: dedupeKey('bill_due', b.id, b.date.slice(0, 10)),
    });
  }
  return findings;
}

// --- Ledger reconciliation ----------------------------------------------------

/**
 * Reconcile a pass's active findings against the M6-1 fired-alert ledger. This
 * is where dedupe (don't re-announce a still-true condition) and expiry (let a
 * cleared condition re-alert later) meet:
 *
 *   * `toDispatch` — the findings whose `dedupe_key` is NOT already in the ledger.
 *     A condition already recorded is still true but already announced, so it is
 *     suppressed this pass (the AC's "a still-true condition does not re-fire").
 *   * the returned `state` — the ledger with cleared keys EXPIRED (via
 *     expireFiredAlerts, scoped to EXPIRING_TYPES so point-event large_txn keys
 *     persist) and every still-active key RECORDED (via recordFiredAlert, which
 *     skips an existing key so its original first-fired payload is preserved).
 *
 * Assumes every EXPIRING_TYPES detector ran this pass, so `findings` carries the
 * complete active set for those domains (the SKILL runs all four each pass). A
 * caller that skipped a detector (e.g. a failed fetch) passes a narrowed
 * `options.expiringTypes` so it never expires a domain it couldn't re-evaluate.
 * Pure — returns a new state, never mutates.
 *
 * @param {object} state     the current (normalized) snapshot.
 * @param {Array<object>} findings  active findings from all detectors this pass.
 * @param {object} [options]
 * @param {string[]} [options.expiringTypes]  override EXPIRING_TYPES.
 * @param {string}   [options.now]  ISO timestamp stored as the first-fired marker.
 * @returns {{ state: object, toDispatch: Array<object>, expired: string[] }}
 */
export function reconcileFindings(state, findings, options = {}) {
  const list = Array.isArray(findings) ? findings.filter((f) => isObject(f) && typeof f.dedupe_key === 'string') : [];
  const now = options.now ?? new Date().toISOString();
  const expiringTypes = options.expiringTypes ?? EXPIRING_TYPES;
  const activeKeys = new Set(list.map((f) => f.dedupe_key));

  const toDispatch = list.filter((f) => !Object.prototype.hasOwnProperty.call(state.firedAlerts, f.dedupe_key));

  let next = expireFiredAlerts(state, activeKeys, { types: expiringTypes });
  const expired = next.expired;
  let s = next.state;
  for (const key of activeKeys) {
    s = recordFiredAlert(s, key, { at: now }).state;
  }
  return { state: s, toDispatch, expired };
}
