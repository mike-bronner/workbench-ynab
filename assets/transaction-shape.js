'use strict';

/**
 * Transaction-shape helpers for workbench-ynab write-back (GAP-19 / #49).
 *
 * YNAB transactions are not flat: a transaction can be a SPLIT (a parent whose
 * `subtransactions` carry the real category legs) or a TRANSFER LEG (one half of
 * a linked inflow/outflow pair, marked by `transfer_account_id` /
 * `transfer_transaction_id`). Both shapes have special write semantics, and every
 * write path (categorize M4-6, duplicate-fix M4-8, reconcile M4-9, guardrail
 * M4-2) must classify them the same way — so the detection lives HERE, in one
 * shared, dependency-free module, never re-implemented per handler.
 *
 * V1 CONSERVATIVE POSTURE (the locked GAP-19 decision): flag-not-auto-modify for
 * all split/transfer ambiguity; route to human review only. Concretely:
 *  - A split PARENT has no single category (its subtransactions do). The
 *    categorizer never sets a category on the parent's id — it emits a
 *    `human_review_required` entry (`split_parent_ambiguous_category`) instead.
 *    Categorizing a specific subtransaction BY ITS OWN id is allowed.
 *  - A transfer leg's category is reserved by transfer semantics. The categorizer
 *    never touches it — `human_review_required` (`transfer_leg_category_reserved`)
 *    — and the M4-2 guardrail blocks it at guardrail time too.
 *  - The deduper must NEVER delete one leg of a transfer pair as a "duplicate":
 *    the inflow/outflow pair is legitimate, and deleting one leg corrupts the
 *    linked account's ledger. That is a HARD BLOCK (not human review).
 *  - The proposal generator (M4-10) routes every `human_review_required` case to
 *    the human-review-only bucket — no auto-proposed change is generated for them
 *    (see assets/changeset-contract.md).
 *
 * Detection reads the transaction payload directly (or an op's `before` snapshot
 * carrying the same fields): `subtransactions` non-empty ⇒ split;
 * `transfer_account_id` / `transfer_transaction_id` non-null ⇒ transfer leg.
 *
 * NO DEPENDENCIES. Pure object inspection, importable by the guardrail and every
 * handler without an install step (docs/testing.md offline constraint).
 */

/**
 * Stable `human_review_required` reason constants, so consumers branch on an
 * identifier rather than prose (mirrors the guardrail's RULES).
 * @type {Readonly<Record<string, string>>}
 */
const HUMAN_REVIEW_REASONS = Object.freeze({
  SPLIT_PARENT_AMBIGUOUS_CATEGORY: 'split_parent_ambiguous_category',
  TRANSFER_LEG_CATEGORY_RESERVED: 'transfer_leg_category_reserved',
});

/**
 * Whether a transaction (or an op snapshot shaped like one) is a SPLIT parent:
 * `subtransactions` is a non-empty array. An absent / empty / non-array
 * `subtransactions` is not a split. This is the AC's `is_split_transaction(tx)`.
 * @param {unknown} tx a transaction payload or an op `before` snapshot.
 * @returns {boolean}
 */
function isSplitTransaction(tx) {
  if (tx === null || typeof tx !== 'object' || Array.isArray(tx)) return false;
  return Array.isArray(tx.subtransactions) && tx.subtransactions.length > 0;
}

/**
 * Whether a transaction (or an op snapshot shaped like one) is a TRANSFER LEG:
 * `transfer_account_id` or `transfer_transaction_id` is non-null (and non-empty —
 * mirroring the guardrail's transfer-signal check, an empty string is treated as
 * "no value"). This is the AC's `is_transfer_leg(tx)`.
 * @param {unknown} tx a transaction payload or an op `before` / `twin` snapshot.
 * @returns {boolean}
 */
function isTransferLeg(tx) {
  if (tx === null || typeof tx !== 'object' || Array.isArray(tx)) return false;
  const signal = (v) => v !== null && v !== undefined && v !== '';
  return signal(tx.transfer_account_id) || signal(tx.transfer_transaction_id);
}

/**
 * A transaction's contribution to the cleared balance of the account being
 * reconciled, in integer milliunits — the reconcile-path ledger math (M4-9):
 *
 *  - PERSPECTIVE (no double-counting): when `accountId` is supplied, a
 *    transaction KNOWN to belong to any OTHER account contributes 0 — a
 *    transfer's counterpart leg lives in the linked account and must never be
 *    counted from this account's side. Each leg counts exactly once, in its own
 *    account. A transaction whose OWN account is unknown (absent / empty
 *    `account_id` on the live read) yields `null`, never 0: perspective cannot
 *    be determined, so the amount cannot be computed honestly (the
 *    `mark_cleared` live read must carry `account_id` — see
 *    skills/reconcile-write-path.md).
 *  - SPLITS: a split parent's contribution is the SUM of its subtransaction
 *    amounts, never the parent `amount` field, so the ledger math stays correct
 *    even when the two diverge.
 *  - Returns `null` (never a fabricated number) when the amount cannot be
 *    computed honestly: a non-object transaction, a non-integer amount, or a
 *    split with any non-integer subtransaction amount.
 *
 * The caller owns cleared-status filtering (which transactions count toward the
 * cleared balance at all); this helper owns only the per-transaction amount.
 * @param {unknown} tx the live transaction.
 * @param {string} [accountId] the account being reconciled (perspective filter).
 * @returns {number|null} signed milliunits, 0 for an out-of-perspective
 *   transaction, or null when incomputable.
 */
function clearedBalanceContribution(tx, accountId) {
  if (tx === null || typeof tx !== 'object' || Array.isArray(tx)) return null;
  if (typeof accountId === 'string' && accountId.length > 0) {
    // Fail honest, never fabricate: with no known account on the transaction the
    // perspective filter cannot run — `null` (incomputable), NOT a silent 0 that
    // would zero out every impact when a live read omits `account_id`.
    if (typeof tx.account_id !== 'string' || tx.account_id.length === 0) return null;
    if (tx.account_id !== accountId) return 0;
  }
  if (isSplitTransaction(tx)) {
    let sum = 0;
    for (const sub of tx.subtransactions) {
      if (sub === null || typeof sub !== 'object' || !Number.isInteger(sub.amount)) return null;
      sum += sub.amount;
    }
    return sum;
  }
  return Number.isInteger(tx.amount) ? tx.amount : null;
}

module.exports = {
  HUMAN_REVIEW_REASONS,
  isSplitTransaction,
  isTransferLeg,
  clearedBalanceContribution,
};
