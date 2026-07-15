// tests/unit/transaction-shape.test.mjs — CI-gated unit tests for the shared
// transaction-shape helpers (assets/transaction-shape.js, GAP-19 / #49).
//
// Runs under the built-in node:test runner with NO node_modules present, per
// docs/testing.md. transaction-shape.js is deliberately dependency-free (pure
// object inspection) so every write-path handler and the guardrail can share ONE
// split/transfer classification — these tests pin that classification and the
// reconcile-path ledger math (clearedBalanceContribution). The handler-level
// behavior these helpers gate (categorize human_review_required, dedupe hard
// block, reconcile cleared_balance_impact) is covered in assets/test/*.test.js.
//
// The module is CommonJS; import via createRequire and destructure.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

const {
  HUMAN_REVIEW_REASONS,
  isSplitTransaction,
  isTransferLeg,
  clearedBalanceContribution,
} = require(join(ROOT, 'assets', 'transaction-shape.js'));

// --- isSplitTransaction (AC: non-empty subtransactions array ⇒ split) --------

test('isSplitTransaction: subtransactions: [] → false; non-empty → true (the AC fixtures)', () => {
  assert.equal(isSplitTransaction({ id: 't1', subtransactions: [] }), false);
  assert.equal(isSplitTransaction({ id: 't1', subtransactions: [{ id: 's1', amount: -1000 }] }), true);
});

test('isSplitTransaction: absent or non-array subtransactions is not a split', () => {
  assert.equal(isSplitTransaction({ id: 't1' }), false);
  assert.equal(isSplitTransaction({ id: 't1', subtransactions: null }), false);
  assert.equal(isSplitTransaction({ id: 't1', subtransactions: 'yes' }), false);
});

test('isSplitTransaction: a non-object payload is never a split (fail-closed on shape)', () => {
  assert.equal(isSplitTransaction(null), false);
  assert.equal(isSplitTransaction(undefined), false);
  assert.equal(isSplitTransaction('tx'), false);
  assert.equal(isSplitTransaction([{ subtransactions: [{}] }]), false); // an array is not a tx
});

// --- isTransferLeg (AC: either transfer field non-null ⇒ transfer leg) --------

test('isTransferLeg: both transfer fields null → false; either non-null → true (the AC fixtures)', () => {
  assert.equal(isTransferLeg({ transfer_account_id: null, transfer_transaction_id: null }), false);
  assert.equal(isTransferLeg({ transfer_account_id: 'acct-2', transfer_transaction_id: null }), true);
  assert.equal(isTransferLeg({ transfer_account_id: null, transfer_transaction_id: 't-9' }), true);
  assert.equal(isTransferLeg({ transfer_account_id: 'acct-2', transfer_transaction_id: 't-9' }), true);
});

test('isTransferLeg: absent or empty-string transfer fields are "no value" (mirrors the guardrail)', () => {
  assert.equal(isTransferLeg({ id: 't1' }), false);
  assert.equal(isTransferLeg({ transfer_account_id: '', transfer_transaction_id: '' }), false);
});

test('isTransferLeg: a non-object payload is never a transfer leg', () => {
  assert.equal(isTransferLeg(null), false);
  assert.equal(isTransferLeg(undefined), false);
  assert.equal(isTransferLeg([{ transfer_account_id: 'a' }]), false);
});

// --- HUMAN_REVIEW_REASONS (stable identifiers the handlers emit) --------------

test('HUMAN_REVIEW_REASONS pins the two v1 flag-not-auto-modify reason ids, frozen', () => {
  assert.equal(HUMAN_REVIEW_REASONS.SPLIT_PARENT_AMBIGUOUS_CATEGORY, 'split_parent_ambiguous_category');
  assert.equal(HUMAN_REVIEW_REASONS.TRANSFER_LEG_CATEGORY_RESERVED, 'transfer_leg_category_reserved');
  assert.ok(Object.isFrozen(HUMAN_REVIEW_REASONS));
});

// --- clearedBalanceContribution (reconcile ledger math, GAP-19) ---------------

test('a split parent contributes the SUM of its subtransaction amounts, never the parent amount', () => {
  // Parent amount deliberately DIVERGES from the sub sum, so a regression back to
  // the parent field cannot pass by coincidence.
  const split = {
    id: 't-split', account_id: 'a1', amount: -99999,
    subtransactions: [{ amount: -30000 }, { amount: -12500 }],
  };
  assert.equal(clearedBalanceContribution(split, 'a1'), -42500);
});

test('a plain transaction contributes its own amount', () => {
  assert.equal(clearedBalanceContribution({ id: 't1', account_id: 'a1', amount: -54990 }, 'a1'), -54990);
  assert.equal(clearedBalanceContribution({ id: 't1', amount: 1000 }), 1000); // no perspective filter
});

test('perspective: a transaction of ANOTHER account contributes 0 — a transfer counterpart is never double-counted', () => {
  const otherLeg = {
    id: 't-leg-b', account_id: 'a2', amount: 50000,
    transfer_account_id: 'a1', transfer_transaction_id: 't-leg-a',
  };
  assert.equal(clearedBalanceContribution(otherLeg, 'a1'), 0);
  // The leg that DOES belong to the reconciled account counts once, in its own account.
  const ownLeg = { id: 't-leg-a', account_id: 'a1', amount: -50000, transfer_account_id: 'a2' };
  assert.equal(clearedBalanceContribution(ownLeg, 'a1'), -50000);
});

test('returns null — never a fabricated number — when the amount cannot be computed honestly', () => {
  assert.equal(clearedBalanceContribution(null, 'a1'), null);
  assert.equal(clearedBalanceContribution({ id: 't1', account_id: 'a1' }, 'a1'), null); // no amount
  assert.equal(clearedBalanceContribution({ id: 't1', account_id: 'a1', amount: 54.99 }, 'a1'), null); // non-integer
  const badSplit = { id: 't1', account_id: 'a1', subtransactions: [{ amount: -1000 }, { amount: null }] };
  assert.equal(clearedBalanceContribution(badSplit, 'a1'), null); // any bad sub poisons the sum
});
