'use strict';

/**
 * End-to-end duplicate-candidate SURFACING test (issue #212 — the deferred
 * conditional AC from #55 / AC #7 of #49): a legitimate transfer
 * inflow+outflow pair is NEVER surfaced as a duplicate candidate.
 *
 * Drives the REAL surfacing logic (assets/duplicate-candidates.js) over the
 * transaction list served by the in-process mock YNAB MCP
 * (tests/lib/mock-ynab-mcp.cjs) from tests/fixtures/mock-budget.json — the
 * same harness and fixture as e2e-write-back.test.js, whose delete-path
 * hard-block proofs this complements: that suite proves a live transfer leg is
 * REFUSED at delete time; this one proves the leg is never even PROPOSED.
 *
 * No concrete tool name is hard-coded here (issue #87) — the list read
 * resolves via the mock's derived ids.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const { surfaceDuplicateCandidates } = require('../duplicate-candidates');
const {
  TOOLS, MUTATION_TOOL_IDS, NEVER_ALLOW_TOOL_IDS, createMockYnab,
} = require('../../tests/lib/mock-ynab-mcp.cjs');

const ROOT = path.join(__dirname, '..', '..');
const fixtureBudget = () => JSON.parse(
  fs.readFileSync(path.join(ROOT, 'tests', 'fixtures', 'mock-budget.json'), 'utf8'),
);

const BUDGET = 'b1f2c3d4-1111-4a2b-9c3d-000000000001';
// The OBVIOUS legitimate transfer pair (payee names carry the transfer signal).
const TXN_TRANSFER_OUT = 't0000000-0000-4000-8000-00000000t001';
const TXN_TRANSFER_IN = 't0000000-0000-4000-8000-00000000t002';
// The DISGUISED transfer pair (neutral payee; transfer signal only in the fields).
const TXN_HIDDEN_TRANSFER = 't0000000-0000-4000-8000-00000000n001';
const TXN_HIDDEN_TWIN = 't0000000-0000-4000-8000-00000000n002';
// n001's innocent same-payee/amount/date doppelganger — a REAL potential duplicate.
const TXN_DOPPELGANGER = 't0000000-0000-4000-8000-00000000n003';
// The known non-transfer duplicate pair.
const TXN_TWIN = 't0000000-0000-4000-8000-00000000d001';
const TXN_VICTIM = 't0000000-0000-4000-8000-00000000d002';

test('E2E: a legitimate transfer inflow+outflow pair is never surfaced as a duplicate candidate', async () => {
  const mock = createMockYnab(fixtureBudget());
  const { transactions } = await mock.callTool(TOOLS.list_transactions, { budget_id: BUDGET });

  const candidates = surfaceDuplicateCandidates(transactions);
  const ids = candidates.map((c) => c.transaction.id);

  // The legitimate transfer pair t001/t002 is never in the candidate list.
  assert.ok(!ids.includes(TXN_TRANSFER_OUT), 'transfer outflow leg must never surface');
  assert.ok(!ids.includes(TXN_TRANSFER_IN), 'transfer inflow leg must never surface');

  // The DISGUISED pair n001/n002 is excluded too — n001 matches n003 exactly on
  // payee/amount/date and only its transfer FIELDS give it away, so this pins
  // the exclusion to transfer_account_id / transfer_transaction_id, never to
  // payee-name heuristics.
  assert.ok(!ids.includes(TXN_HIDDEN_TRANSFER), 'disguised transfer leg must never surface');
  assert.ok(!ids.includes(TXN_HIDDEN_TWIN), 'disguised counterpart leg must never surface');

  // …and ONLY transfer legs are suppressed: the innocent doppelganger and the
  // real duplicate pair still surface — exactly these three, nothing else.
  assert.deepEqual([...ids].sort(), [TXN_TWIN, TXN_VICTIM, TXN_DOPPELGANGER].sort());

  // Non-vacuous: n003 surfaced BECAUSE it matched the disguised leg — the match
  // fired and the field-based exclusion (not a failed match) kept n001 out.
  const doppelganger = candidates.find((c) => c.transaction.id === TXN_DOPPELGANGER);
  assert.deepEqual(doppelganger.matched_ids, [TXN_HIDDEN_TRANSFER]);

  // The known duplicate pair points at each other as evidence.
  assert.deepEqual(candidates.find((c) => c.transaction.id === TXN_TWIN).matched_ids, [TXN_VICTIM]);
  assert.deepEqual(candidates.find((c) => c.transaction.id === TXN_VICTIM).matched_ids, [TXN_TWIN]);

  // STRICTLY READ-ONLY, end to end: the one and only tool call was the list
  // read — zero mutation calls, zero never-allow attempts.
  assert.deepEqual(mock.callLog.map((c) => c.tool), [TOOLS.list_transactions]);
  assert.deepEqual(mock.callLog.filter((c) => MUTATION_TOOL_IDS.includes(c.tool)), []);
  assert.deepEqual(mock.callLog.filter((c) => NEVER_ALLOW_TOOL_IDS.includes(c.tool)), []);
  assert.deepEqual(mock.neverAllowAttempts, []);
});

test('surfacing thresholds are config-overridable: near-amount tolerance and date-proximity window', () => {
  const txn = (id, amount, date) => ({
    id, amount, date, payee_name: 'Cafe', transfer_account_id: null, transfer_transaction_id: null, deleted: false,
  });
  // 990 milliunits and two days apart: invisible at the exact-amount default…
  const pair = [txn('x1', -10000, '2026-06-01'), txn('x2', -10990, '2026-06-03')];
  assert.deepEqual(surfaceDuplicateCandidates(pair), []);
  // …a candidate pair once the thresholds are widened via config.
  const widened = surfaceDuplicateCandidates(pair, { amountToleranceMilliunits: 1000, dateProximityDays: 2 });
  assert.deepEqual(widened.map((c) => c.transaction.id), ['x1', 'x2']);
  // Opposite signs never match — a transfer-shaped inflow/outflow is not a
  // near-amount duplicate, however wide the tolerance (20000 covers the whole
  // signed difference here, so ONLY the direction rule keeps them apart).
  const signs = [txn('y1', -10000, '2026-06-01'), txn('y2', 10000, '2026-06-01')];
  assert.deepEqual(surfaceDuplicateCandidates(signs, { amountToleranceMilliunits: 20000 }), []);
});
