'use strict';

/**
 * Unit tests for the M4-7 allocate / set-budgeted-amount write path.
 *
 * Run with Node's built-in test runner (no Ajv needed — the handler depends only
 * on the dependency-free guardrail):
 *   npm --prefix assets test          # node --test (runs the whole assets suite)
 *   node --test assets/test/allocate-handler.test.js
 *
 * The allocate fixture (assets/fixtures/allocate.example.json) is the exact
 * envelope M4 produces. The namespaced mutating tool is resolved from the
 * guardrail's exported ALLOWED_TOOLS by suffix — never typed as a literal — so
 * this file holds no hard-coded `mcp__plugin_workbench-ynab_ynab__*` name (#87 guard).
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const allocate = require('../allocate-handler');
const { ALLOWED_TOOLS } = require('../write-safety-guardrail');

const FIXTURES = path.join(__dirname, '..', 'fixtures');
const loadFixture = (name) => JSON.parse(fs.readFileSync(path.join(FIXTURES, name), 'utf8'));
const clone = (x) => JSON.parse(JSON.stringify(x));

// Resolve the expected tool from the guardrail allow-list by suffix, so no literal
// namespaced name lives here (mirrors apply-executor.test.js).
const UPDATE_CATEGORY = ALLOWED_TOOLS.find((t) => t.endsWith('_update_category'));

/** A spy that records its calls and returns a (optionally per-call) value. */
function spy(impl) {
  const calls = [];
  const fn = async (...args) => {
    calls.push(args);
    return impl ? impl(...args) : undefined;
  };
  fn.calls = calls;
  return fn;
}

const allocateOp = () => loadFixture('allocate.example.json').operations[0];

// --- registration point ----------------------------------------------------

test('toolMapEntry registers allocate → the namespaced update_category tool', () => {
  assert.deepEqual(allocate.toolMapEntry(), { allocate: UPDATE_CATEGORY });
  assert.equal(allocate.applyToolName(), UPDATE_CATEGORY);
  // The resolved tool really is on the guardrail's ledger-only allow-list.
  assert.ok(ALLOWED_TOOLS.includes(allocate.applyToolName()));
});

// --- (1) valid op dispatches the correct API call with correct milliunits ----

test('(1) buildApplyArgs maps a valid op to flat update_category args with raw milliunits', () => {
  const op = allocateOp(); // after.budgeted = 250000
  const args = allocate.buildApplyArgs(op);
  assert.deepEqual(args, {
    budget_id: op.budget_id,
    category_id: op.category_id,
    month: op.month,
    budgeted: 250000,
  });
  // budgeted is the RAW integer after.budgeted — no float round-trip.
  assert.equal(args.budgeted, op.after.budgeted);
  assert.equal(Number.isInteger(args.budgeted), true);
});

// --- (2) dry-run produces the expected diff string --------------------------

test('(2) renderDiff produces the expected before→after currency diff (category id fallback)', () => {
  const op = allocateOp();
  assert.equal(
    allocate.renderDiff(op),
    `${op.category_id} — 2026-06-01: $0.00 → $250.00 (+$250.00)`,
  );
});

test('(2) renderDiff uses a resolved category name when supplied', () => {
  assert.equal(
    allocate.renderDiff(allocateOp(), 'Groceries'),
    'Groceries — 2026-06-01: $0.00 → $250.00 (+$250.00)',
  );
});

test('(2) renderDiff renders a zero-delta no-op without a + sign', () => {
  // delta === 0 takes the non-strict branch (`delta > 0` is false), so the
  // delta is rendered as a bare "$0.00" — no "+" prefix.
  const op = allocateOp();
  op.before.budgeted = 250000;
  op.after.budgeted = 250000; // no change
  assert.equal(
    allocate.renderDiff(op, 'Groceries'),
    'Groceries — 2026-06-01: $250.00 → $250.00 ($0.00)',
  );
});

test('(2) dryRunAllocate issues no write and returns a per-op diff', async () => {
  const op = allocateOp();
  const getMonth = spy(() => ({
    to_be_budgeted: 1000000,
    categories: [{ id: op.category_id, name: 'Groceries', budgeted: 0 }],
  }));
  const out = await allocate.dryRunAllocate([op], { getMonth });

  assert.equal(out.dry_run, true);
  assert.equal(out.over_allocated, false);
  assert.equal(out.operations.length, 1);
  assert.equal(out.operations[0].diff, 'Groceries — 2026-06-01: $0.00 → $250.00 (+$250.00)');
  assert.equal(out.operations[0].before, 0);
  assert.equal(out.operations[0].after, 250000);
  // get_month was read exactly once; no mutating port exists on this path at all.
  assert.equal(getMonth.calls.length, 1);
});

test('formatMilliunits matches the contract (÷1000, integer-cent, grouped, signed)', () => {
  assert.equal(allocate.formatMilliunits(250000), '$250.00');
  assert.equal(allocate.formatMilliunits(-54990), '-$54.99');
  assert.equal(allocate.formatMilliunits(0), '$0.00');
  assert.equal(allocate.formatMilliunits(1200000), '$1,200.00');
  assert.equal(allocate.formatMilliunits(-250000), '-$250.00');
});

// --- (3) RTA over-allocation warning ----------------------------------------

test('(3) assessOverAllocation warns when the batch would push RTA negative', () => {
  const op = allocateOp(); // delta = +250000
  const tight = allocate.assessOverAllocation([op], 200000);
  assert.equal(tight.over_allocated, true);
  assert.equal(tight.total_delta, 250000);
  assert.equal(tight.projected_ready_to_assign, -50000);
  // Pin the full message, not just a keyword — a regression in the embedded
  // currency figures would otherwise ship undetected.
  assert.equal(
    tight.message,
    '⚠️ Over-allocation: this batch budgets a net $250.00 but only $200.00 is ' +
      'Ready to Assign — Ready to Assign would fall to -$50.00.',
  );

  const room = allocate.assessOverAllocation([op], 300000);
  assert.equal(room.over_allocated, false);
  assert.equal(room.projected_ready_to_assign, 50000);
  assert.equal(room.message, null);
});

test('(3) assessOverAllocation does not warn when RTA is spent to exactly zero', () => {
  // Boundary: `projected < 0` is strict, so projected === 0 must NOT warn —
  // budgeting RTA down to exactly zero is allowed, not an over-allocation.
  const op = allocateOp(); // delta = +250000
  const exact = allocate.assessOverAllocation([op], 250000); // readyToAssign === totalDelta
  assert.equal(exact.projected_ready_to_assign, 0);
  assert.equal(exact.over_allocated, false);
  assert.equal(exact.message, null);
});

test('(3) dryRunAllocate surfaces the over-allocation warning from the month read', async () => {
  const op = allocateOp();
  const getMonth = spy(() => ({ to_be_budgeted: 200000, categories: [] }));
  const out = await allocate.dryRunAllocate([op], { getMonth });

  assert.equal(out.over_allocated, true);
  assert.equal(out.warnings.length, 1);
  assert.deepEqual(
    {
      budget_id: out.warnings[0].budget_id,
      month: out.warnings[0].month,
      ready_to_assign: out.warnings[0].ready_to_assign,
      projected_ready_to_assign: out.warnings[0].projected_ready_to_assign,
    },
    { budget_id: op.budget_id, month: op.month, ready_to_assign: 200000, projected_ready_to_assign: -50000 },
  );
  // Advisory only — the op is still reported (nothing is blocked or dropped).
  assert.equal(out.operations.length, 1);
});

test('(3) the over-allocation warning is advisory — assessOverAllocation never throws or blocks', () => {
  // Even a wildly over-allocated batch just reports; it returns a verdict, not an error.
  const op = allocateOp();
  assert.doesNotThrow(() => allocate.assessOverAllocation([op], -999999));
});

test('(3) dryRunAllocate groups by month and warns per month, reading get_month once each', async () => {
  const june = allocateOp();
  const july = clone(june);
  july.id = 'op-allocate-0002';
  july.month = '2026-07-01';
  july.after.budgeted = 100000; // delta +100000

  const getMonth = spy(({ month }) =>
    month === '2026-06-01'
      ? { to_be_budgeted: 50000, categories: [] } // June over-allocates (50000 - 250000 < 0)
      : { to_be_budgeted: 500000, categories: [] }, // July has room
  );
  const out = await allocate.dryRunAllocate([june, july], { getMonth });

  assert.equal(getMonth.calls.length, 2); // one read per distinct month
  assert.equal(out.operations.length, 2);
  assert.equal(out.warnings.length, 1);
  assert.equal(out.warnings[0].month, '2026-06-01');
});

test('(3) dryRunAllocate skips the over-allocation check when the month read has no RTA', async () => {
  // get_month returns no usable `to_be_budgeted` → rta === null → the advisory
  // warning is suppressed (never invent a figure, never block on a missing read),
  // but the op is still rendered and reported.
  const op = allocateOp();
  const getMonth = spy(() => ({ categories: [] })); // no to_be_budgeted
  const out = await allocate.dryRunAllocate([op], { getMonth });

  assert.equal(out.warnings.length, 0);
  assert.equal(out.over_allocated, false);
  assert.equal(out.operations.length, 1); // op still reported despite the skipped check
});

// --- (4) negative budgeted (de-funding) -------------------------------------

test('(4) negative after.budgeted (de-funding) passes through apply args and the diff', () => {
  const op = allocateOp();
  op.before.budgeted = 250000;
  op.after.budgeted = -50000; // de-fund below zero — valid

  const args = allocate.buildApplyArgs(op);
  assert.equal(args.budgeted, -50000);
  assert.equal(Number.isInteger(args.budgeted), true);
  assert.equal(
    allocate.renderDiff(op, 'Groceries'),
    'Groceries — 2026-06-01: $250.00 → -$50.00 (-$300.00)',
  );
});

test('(4) a net de-funding batch never over-allocates (raises RTA)', () => {
  const op = allocateOp();
  op.before.budgeted = 250000;
  op.after.budgeted = 0; // delta -250000
  const out = allocate.assessOverAllocation([op], 0);
  assert.equal(out.total_delta, -250000);
  assert.equal(out.projected_ready_to_assign, 250000);
  assert.equal(out.over_allocated, false);
});

// --- (5) missing required fields rejected without an API call ----------------

test('(5) buildApplyArgs throws on a malformed op and never produces apply args', () => {
  const missingMonth = allocateOp();
  delete missingMonth.month;
  assert.throws(() => allocate.buildApplyArgs(missingMonth), /month is required/);

  const missingCategory = allocateOp();
  delete missingCategory.category_id;
  assert.throws(() => allocate.buildApplyArgs(missingCategory), /category_id is required/);

  const badBudgeted = allocateOp();
  badBudgeted.after.budgeted = 250.5; // float, not integer milliunits
  assert.throws(() => allocate.buildApplyArgs(badBudgeted), /after\.budgeted .* integer/);

  const badMonth = allocateOp();
  badMonth.month = '2026-06-15'; // not first-of-month
  assert.throws(() => allocate.buildApplyArgs(badMonth), /YYYY-MM-01/);
});

test('(5) a malformed op never reaches applyOp — buildApplyArgs throws before any dispatch', async () => {
  // Simulate the runtime wiring: applyOp shapes its args from buildApplyArgs. A
  // malformed op throws there, so the (mock) mutating tool is never invoked.
  const applyOp = spy(() => ({ ok: true }));
  const bad = allocateOp();
  delete bad.budget_id;

  await assert.rejects(async () => {
    const args = allocate.buildApplyArgs(bad); // throws here
    return applyOp(UPDATE_CATEGORY, args);
  }, /budget_id is required/);
  assert.equal(applyOp.calls.length, 0);
});

test('validateAllocateOp reports every missing field with a descriptive error', () => {
  const { valid, errors } = allocate.validateAllocateOp({ type: 'allocate' });
  assert.equal(valid, false);
  assert.ok(errors.some((e) => /budget_id/.test(e)));
  assert.ok(errors.some((e) => /category_id/.test(e)));
  assert.ok(errors.some((e) => /month/.test(e)));
  assert.ok(errors.some((e) => /before/.test(e)));
  assert.ok(errors.some((e) => /after/.test(e)));
});

// --- port contract ----------------------------------------------------------

test('dryRunAllocate requires a getMonth port (fail fast on misconfiguration)', async () => {
  await assert.rejects(() => allocate.dryRunAllocate([allocateOp()], {}), /getMonth/);
});
