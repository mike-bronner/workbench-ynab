'use strict';

/**
 * Duplicate-candidate SURFACING for workbench-ynab (the M4-8 surfacing side,
 * issue #212 — the deferred conditional AC from #55 / AC #7 of #49).
 *
 * Turns the Duplicate Detection prose of skills/review/ynab-review.md ("flag
 * likely double-entries: same/near amount + payee + date proximity") into one
 * shared, dependency-free module. STRICTLY READ-ONLY: a pure function over an
 * already-fetched transaction list — it calls no tool, mutates nothing, and
 * only ever LISTS candidates for a later dedup proposal (this module surfaces,
 * never fixes).
 *
 * THE TRANSFER EXCLUSION (GAP-19 / #49). A transfer leg — any transaction with
 * a non-null `transfer_account_id` or `transfer_transaction_id`, per
 * transaction-shape's `isTransferLeg` — is NEVER emitted as a candidate. The
 * two legs of a transfer are a legitimate inflow/outflow pair, not duplicates,
 * no matter how exactly amount/date/payee match, and deleting one leg would
 * corrupt the linked account's ledger (the M4-8 delete handler hard-blocks it;
 * this module makes sure the proposal is never even surfaced). The exclusion
 * keys off those two FIELDS ONLY — never off payee-name heuristics, so a
 * disguised leg (neutral payee name) is just as protected as an obvious one.
 *
 * The exclusion is candidate-side, not input-side: a transfer leg still counts
 * as MATCH EVIDENCE, so an innocent non-transfer double-entry that mirrors a
 * transfer leg (same payee/amount/date) still surfaces — the exclusion is
 * transfer-specific, never a blanket suppression that would hide real
 * duplicates.
 *
 * NO DEPENDENCIES beyond ./transaction-shape (itself dependency-free), so the
 * module stays importable with no install step (docs/testing.md offline
 * constraint). E2E-proven against the mock harness in
 * assets/test/e2e-duplicate-surfacing.test.js.
 */

const { isTransferLeg } = require('./transaction-shape');

/**
 * Match thresholds, config-overridable per skills/review/ynab-review.md ("each
 * parameterized against config — no hardcoded constants"). Defaults are the
 * conservative reading of "same/near amount + date proximity": exact amount,
 * three-day window.
 * @type {Readonly<{amountToleranceMilliunits: number, dateProximityDays: number}>}
 */
const SURFACING_DEFAULTS = Object.freeze({
  amountToleranceMilliunits: 0,
  dateProximityDays: 3,
});

const MS_PER_DAY = 86400000;

const nonEmptyString = (v) => typeof v === 'string' && v.length > 0;

/** Epoch ms for an ISO `YYYY-MM-DD` date, or null when absent/unparseable. */
function dateMs(v) {
  if (!nonEmptyString(v)) return null;
  const ms = Date.parse(v);
  return Number.isNaN(ms) ? null : ms;
}

/**
 * Same payee: by `payee_id` when both carry one, else by case-insensitive
 * non-empty `payee_name`. This is the MATCH heuristic only — the transfer
 * exclusion never reads payee fields.
 */
function samePayee(a, b) {
  if (nonEmptyString(a.payee_id) && nonEmptyString(b.payee_id)) {
    return a.payee_id === b.payee_id;
  }
  return nonEmptyString(a.payee_name) && nonEmptyString(b.payee_name)
    && a.payee_name.toLowerCase() === b.payee_name.toLowerCase();
}

/**
 * Whether two transactions look like a double-entry pair: same payee, same
 * ledger DIRECTION with signed amounts within tolerance (a real duplicate
 * repeats the same inflow or the same outflow — an inflow/outflow pair is
 * transfer-shaped, never a duplicate, however wide the tolerance), dates
 * within the proximity window. Fail-closed: an unparseable date on either
 * side is never a match.
 */
function pairMatches(a, b, opts) {
  if (!samePayee(a, b)) return false;
  if (Math.sign(a.amount) !== Math.sign(b.amount)) return false;
  if (Math.abs(a.amount - b.amount) > opts.amountToleranceMilliunits) return false;
  const da = dateMs(a.date);
  const db = dateMs(b.date);
  if (da === null || db === null) return false;
  return Math.abs(da - db) <= opts.dateProximityDays * MS_PER_DAY;
}

/**
 * Surface likely duplicate candidates over a transaction list.
 *
 * Considers every non-deleted transaction carrying an id and an integer
 * milliunit amount; pairs them on same payee + same/near amount + date
 * proximity; emits each matched NON-transfer-leg transaction once, with the
 * ids of the transactions it matched as evidence. Transfer legs are excluded
 * from the candidate set (see the module header) but remain valid evidence.
 *
 * @param {unknown} transactions the already-fetched transaction list (e.g. the
 *   `transactions` array of a list-transactions read).
 * @param {{amountToleranceMilliunits?: number, dateProximityDays?: number}} [options]
 *   overrides for SURFACING_DEFAULTS; both must be non-negative
 *   (integer milliunits / finite days).
 * @returns {Array<{transaction: object, matched_ids: string[]}>} candidates in
 *   input order; `matched_ids` in input order, duplicates never repeated.
 * @throws {TypeError} on a malformed option — thresholds are guardrail
 *   parameters, so a bad value fails loudly rather than silently widening or
 *   narrowing the match.
 */
function surfaceDuplicateCandidates(transactions, options = {}) {
  const opts = { ...SURFACING_DEFAULTS, ...options };
  if (!Number.isInteger(opts.amountToleranceMilliunits) || opts.amountToleranceMilliunits < 0) {
    throw new TypeError(`amountToleranceMilliunits must be a non-negative integer (milliunits), got: ${opts.amountToleranceMilliunits}`);
  }
  if (typeof opts.dateProximityDays !== 'number' || !Number.isFinite(opts.dateProximityDays) || opts.dateProximityDays < 0) {
    throw new TypeError(`dateProximityDays must be a non-negative finite number, got: ${opts.dateProximityDays}`);
  }

  const pool = (Array.isArray(transactions) ? transactions : []).filter((t) => (
    t !== null && typeof t === 'object' && !Array.isArray(t)
    && t.deleted !== true && nonEmptyString(t.id) && Number.isInteger(t.amount)
  ));

  /** @type {Map<string, Set<string>>} candidate id → evidence ids. */
  const evidence = new Map();
  const record = (candidate, matched) => {
    if (isTransferLeg(candidate)) return; // the exclusion — field-based, always.
    if (!evidence.has(candidate.id)) evidence.set(candidate.id, new Set());
    evidence.get(candidate.id).add(matched.id);
  };

  for (let i = 0; i < pool.length; i += 1) {
    for (let j = i + 1; j < pool.length; j += 1) {
      if (pool[i].id === pool[j].id || !pairMatches(pool[i], pool[j], opts)) continue;
      record(pool[i], pool[j]);
      record(pool[j], pool[i]);
    }
  }

  return pool
    .filter((t) => evidence.has(t.id))
    .map((t) => ({ transaction: t, matched_ids: [...evidence.get(t.id)] }));
}

module.exports = {
  SURFACING_DEFAULTS,
  surfaceDuplicateCandidates,
};
