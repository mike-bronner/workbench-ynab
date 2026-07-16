// tests/unit/delete-duplicate.test.mjs — CI-gated unit tests for the pure safety
// helpers of the M4-8 duplicate-fix (delete) write path (assets/delete-duplicate.js).
//
// Runs under the built-in node:test runner with NO node_modules present, per
// docs/testing.md. delete-duplicate.js lazy-requires the Ajv-backed executor only
// inside applyDeleteDuplicates, so importing it for these helpers pulls in NO
// dependency — that is what lets this destructive path's safety logic (twin-evidence
// validation, the dry-run preview, dollar formatting, the strong-confirmation gate)
// gate in CI offline. The full executor-integration tests (twin rejection before any
// MCP call, drift→stale skip, audit-before-delete) live in assets/test/delete-duplicate.test.js
// and run via `npm --prefix assets test` where Ajv is installed.
//
// The module is CommonJS; import its default export and destructure.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

const {
  formatDollars,
  validateTwinEvidence,
  validateNotTransferLeg,
  shapeVictimSnapshot,
  renderDeletePreview,
  requiresStrongConfirmation,
  destructiveOps,
  buildToolMap,
  makeAuditingDeleteApplyOp,
  resolveDeleteTool,
  DELETE_TOOL,
  OP_TYPE,
  TWIN_REQUIRED_FIELDS,
  VICTIM_SNAPSHOT_FIELDS,
} = require(join(ROOT, 'assets', 'delete-duplicate.js'));

// A minimal, schema-shaped delete op (no Ajv needed — these helpers are pure).
const validOp = () => ({
  id: 'op-delete-duplicate-0001',
  type: 'delete_duplicate',
  budget_id: 'b1',
  transaction_id: 't-victim',
  twin: { id: 't-survivor', payee_name: 'Amazon', amount: -54990, date: '2026-06-12' },
  before: {
    amount: -54990, date: '2026-06-12', payee_name: 'Amazon',
    category_id: 'c7', account_id: 'a1', cleared: 'cleared', memo: null, import_id: 'YNAB:-54990:2026-06-12:1',
  },
  after: { deleted: true },
  rationale: 'Exact duplicate of t-survivor.',
  risk: 'destructive',
});

// --- formatDollars (milliunits → display dollars, integer math) -------------

test('formatDollars renders milliunits as dollars (÷1000), signed, with separators', () => {
  assert.equal(formatDollars(-54990), '-$54.99');
  assert.equal(formatDollars(250000), '$250.00');
  assert.equal(formatDollars(1200000), '$1,200.00');
  assert.equal(formatDollars(0), '$0.00');
  assert.equal(formatDollars(1000), '$1.00');
});

test('formatDollars rejects a non-integer (never a float round-trip)', () => {
  assert.throws(() => formatDollars(54.99), /integer milliunits/);
  assert.throws(() => formatDollars('250000'), /integer milliunits/);
});

// --- fractional-milliunit ROUNDING direction is pinned (issue #150) ----------
// Every OTHER formatDollars input in this suite is a whole-cent multiple, so the
// truncation direction is never exercised — a `Math.floor` → `Math.round`/`Math.ceil`
// regression would pass the cases above unchanged. formatDollars TRUNCATES the sub-cent
// remainder (Math.floor of the absolute value), which DELIBERATELY DIVERGES from the
// shared assets/format-money.js formatMoney, that ROUNDS half-toward-+∞: on a
// fractional-milliunit value the two disagree (e.g. 2995 → "$2.99" here vs "$3.00" from
// formatMoney). The divergence is intentional and inert — both formatters only ever
// receive whole-cent YNAB amounts on real data, where their outputs are byte-identical,
// and this path renders the destructive delete preview, so its behavior is guarded, not
// churned. See the divergence note in formatDollars's docblock (assets/delete-duplicate.js).
test('formatDollars truncates a sub-cent remainder toward zero (floors, does not round)', () => {
  // 2995 milliunits = $2.995. Math.floor → "$2.99"; a Math.round/Math.ceil regression → "$3.00".
  assert.equal(formatDollars(2995), '$2.99');
  // Magnitude is floored, sign taken from milliunits < 0: -2995 → "-$2.99".
  assert.equal(formatDollars(-2995), '-$2.99');
});

test('formatDollars renders a tiny negative that floors to zero as "-$0.00" (known signed-zero render)', () => {
  // -5 milliunits floors to $0.00, but the sign is set from `milliunits < 0`, independent
  // of the rounded magnitude. Pin the actual output so the sign logic can't drift silently.
  // Harmless in practice: unreachable under whole-cent YNAB data.
  assert.equal(formatDollars(-5), '-$0.00');
});

// --- validateTwinEvidence ---------------------------------------------------

test('TWIN_REQUIRED_FIELDS is the documented evidence set', () => {
  assert.deepEqual([...TWIN_REQUIRED_FIELDS], ['id', 'payee_name', 'amount', 'date']);
});

test('a complete twin passes validation', () => {
  assert.deepEqual(validateTwinEvidence(validOp()), { valid: true });
});

test('a null payee_name is accepted (a real transaction may have no payee)', () => {
  const op = validOp();
  op.twin.payee_name = null;
  assert.equal(validateTwinEvidence(op).valid, true);
});

test('an op with no twin object is rejected, listing every required field', () => {
  const op = validOp();
  delete op.twin;
  const v = validateTwinEvidence(op);
  assert.equal(v.valid, false);
  assert.equal(v.error.rule, 'twin_evidence_missing');
  assert.equal(v.error.op_id, op.id);
  assert.deepEqual(v.error.missing, ['id', 'payee_name', 'amount', 'date']);
});

test('each missing or malformed twin field is reported individually', () => {
  for (const [field, mutate] of [
    ['id', (t) => { delete t.id; }],
    ['id', (t) => { t.id = ''; }],
    ['amount', (t) => { t.amount = -54.99; }], // non-integer
    ['amount', (t) => { delete t.amount; }],
    ['date', (t) => { delete t.date; }],
    ['payee_name', (t) => { t.payee_name = 42; }], // wrong type
  ]) {
    const op = validOp();
    mutate(op.twin);
    const v = validateTwinEvidence(op);
    assert.equal(v.valid, false, `${field} should fail`);
    assert.ok(v.error.missing.includes(field), `${field} listed missing`);
  }
});

test('a non-object op fails closed', () => {
  assert.equal(validateTwinEvidence(null).valid, false);
  assert.equal(validateTwinEvidence([]).valid, false);
});

test('an op whose victim IS its surviving twin is rejected (would delete the only copy)', () => {
  const op = validOp();
  op.twin.id = op.transaction_id; // survivor === victim — the highest-blast-radius collision
  const v = validateTwinEvidence(op);
  assert.equal(v.valid, false);
  assert.equal(v.error.rule, 'twin_is_victim');
  assert.equal(v.error.op_id, op.id);
  assert.deepEqual(v.error.missing, []);
});

test('an op with no victim transaction_id is rejected (cannot slip past the collision guard)', () => {
  // The collision guard is `op.transaction_id === twin.id`; an absent victim id is
  // `undefined`, which never equals the proven non-empty twin.id — so without an
  // explicit presence check it would sail through this exported safety primitive.
  for (const mutate of [(o) => { delete o.transaction_id; }, (o) => { o.transaction_id = ''; }, (o) => { o.transaction_id = 42; }]) {
    const op = validOp();
    mutate(op);
    const v = validateTwinEvidence(op);
    assert.equal(v.valid, false);
    assert.equal(v.error.rule, 'victim_id_missing');
    assert.equal(v.error.op_id, op.id);
    assert.deepEqual(v.error.missing, ['transaction_id']);
  }
});

test('a twin amount of 0 is accepted (a real $0.00 transaction is valid evidence)', () => {
  // Regression anchor: 0 is a valid integer milliunit amount. A future `if (!twin.amount)`
  // shortcut would silently reject it — this pins the integer-type check as correct.
  const op = validOp();
  op.twin.amount = 0;
  assert.equal(validateTwinEvidence(op).valid, true);
});

// --- requiresStrongConfirmation / destructiveOps ----------------------------

test('every destructive op requires strong confirmation; non-destructive does not', () => {
  assert.equal(requiresStrongConfirmation(validOp()), true);
  assert.equal(requiresStrongConfirmation({ risk: 'low' }), false);
  assert.equal(requiresStrongConfirmation(null), false);
});

test('destructiveOps selects exactly the destructive ops in a change-set', () => {
  const cs = { operations: [validOp(), { id: 'x', risk: 'low' }, validOp()] };
  assert.equal(destructiveOps(cs).length, 2);
  assert.deepEqual(destructiveOps({}).length, 0);
});

// --- renderDeletePreview ----------------------------------------------------

test('renderDeletePreview shows victim and survivor side by side in dollars', () => {
  const preview = renderDeletePreview(validOp(), { clearedBalanceBefore: 1200000 });
  assert.equal(preview.victim.payee_name, 'Amazon');
  assert.equal(preview.victim.amount, '-$54.99');
  assert.equal(preview.victim.amount_milliunits, -54990); // raw milliunits retained internally
  assert.equal(preview.victim.date, '2026-06-12');
  assert.equal(preview.victim.account_id, 'a1');
  assert.equal(preview.victim.cleared, 'cleared');
  assert.equal(preview.survivor.transaction_id, 't-survivor');
  assert.equal(preview.survivor.amount, '-$54.99');
});

test('deleting a cleared victim projects the cleared balance (adds the outflow back)', () => {
  // victim amount -54990 counts toward cleared → after = before − (−54990) = +54990.
  const preview = renderDeletePreview(validOp(), { clearedBalanceBefore: 1200000 });
  assert.equal(preview.cleared_balance.counts_toward_cleared, true);
  assert.equal(preview.cleared_balance.before, '$1,200.00');
  assert.equal(preview.cleared_balance.after_milliunits, 1254990);
  assert.equal(preview.cleared_balance.after, '$1,254.99');
});

test('deleting a reconciled victim projects the cleared balance (reconciled also counts)', () => {
  // `reconciled` is the other state that counts toward the cleared balance — same
  // projection as `cleared`: after = before − (−54990) = +54990.
  const op = validOp();
  op.before.cleared = 'reconciled';
  const preview = renderDeletePreview(op, { clearedBalanceBefore: 1200000 });
  assert.equal(preview.victim.cleared, 'reconciled');
  assert.equal(preview.cleared_balance.counts_toward_cleared, true);
  assert.equal(preview.cleared_balance.after_milliunits, 1254990);
  assert.equal(preview.cleared_balance.after, '$1,254.99');
});

test('deleting an uncleared victim leaves the cleared balance unchanged', () => {
  const op = validOp();
  op.before.cleared = 'uncleared';
  const preview = renderDeletePreview(op, { clearedBalanceBefore: 1200000 });
  assert.equal(preview.cleared_balance.counts_toward_cleared, false);
  assert.equal(preview.cleared_balance.after_milliunits, 1200000);
});

test('renderDeletePreview omits the balance projection when no balance is supplied', () => {
  const preview = renderDeletePreview(validOp());
  assert.equal(preview.cleared_balance.before, null);
  assert.equal(preview.cleared_balance.after, null);
});

test('a cleared victim with no numeric amount yields a null projection, never a NaN throw', () => {
  // The helper is exported, so a caller can reach it with an incomplete `before`.
  // Without the guard, clearedBalanceBefore − undefined === NaN → formatDollars throws.
  const op = validOp();
  delete op.before.amount;
  let preview;
  assert.doesNotThrow(() => { preview = renderDeletePreview(op, { clearedBalanceBefore: 1200000 }); });
  assert.equal(preview.cleared_balance.counts_toward_cleared, true);
  assert.equal(preview.cleared_balance.before, '$1,200.00');
  assert.equal(preview.cleared_balance.after_milliunits, null);
  assert.equal(preview.cleared_balance.after, null);
  assert.equal(preview.victim.amount, null); // display field already guarded the same way
});

// --- shapeVictimSnapshot ----------------------------------------------------

test('shapeVictimSnapshot projects a live transaction onto the snapshot fields', () => {
  const live = { amount: -54990, date: '2026-06-12', payee_name: 'Amazon', category_id: 'c7', account_id: 'a1', cleared: 'cleared', memo: null, extra: 'ignored' };
  const snap = shapeVictimSnapshot(live, ['amount', 'date', 'payee_name', 'cleared']);
  assert.deepEqual(snap, { amount: -54990, date: '2026-06-12', payee_name: 'Amazon', cleared: 'cleared' });
});

test('shapeVictimSnapshot fills absent fields with null and fails closed on non-objects', () => {
  assert.deepEqual(shapeVictimSnapshot({ amount: 1 }, ['amount', 'memo']), { amount: 1, memo: null });
  assert.equal(shapeVictimSnapshot(null), null);
  assert.equal(shapeVictimSnapshot([1, 2]), null);
});

test('VICTIM_SNAPSHOT_FIELDS covers the full audit before-snapshot', () => {
  for (const field of ['amount', 'date', 'payee_name', 'category_id', 'account_id', 'cleared', 'memo']) {
    assert.ok(VICTIM_SNAPSHOT_FIELDS.includes(field), `${field} in snapshot fields`);
  }
});

// --- buildToolMap (resolved from the guardrail SSoT) ------------------------

test('buildToolMap registers delete_duplicate → the namespaced delete tool', () => {
  assert.equal(OP_TYPE, 'delete_duplicate');
  assert.ok(DELETE_TOOL.endsWith('_delete_transaction'));
  assert.deepEqual(buildToolMap(), { delete_duplicate: DELETE_TOOL });
});

// --- resolveDeleteTool (uniqueness asserted, fail-closed — issue #151) -------

test('resolveDeleteTool resolves the single suffix match', () => {
  assert.equal(
    resolveDeleteTool(['mcp__x__ynab_get_transaction', 'mcp__x__ynab_delete_transaction']),
    'mcp__x__ynab_delete_transaction',
  );
});

test('resolveDeleteTool fails closed on ZERO matches — never resolves undefined for the destructive tool', () => {
  assert.throws(() => resolveDeleteTool(['mcp__x__ynab_get_transaction']), /exactly ONE.*found 0/);
  assert.throws(() => resolveDeleteTool([]), /found 0/);
  assert.throws(() => resolveDeleteTool(undefined), /found 0/);
});

test('resolveDeleteTool fails closed on MULTIPLE matches — a suffix collision must never silently pick the first', () => {
  // The regression this guards: `.find()` silently took the first match, so a
  // future allow-list entry sharing the suffix could route irreversible deletes
  // to the wrong tool. Both matches are named in the error for diagnosis.
  assert.throws(
    () => resolveDeleteTool(['mcp__x__ynab_delete_transaction', 'mcp__x__ynab_bulk_delete_transaction']),
    /found 2.*ynab_delete_transaction.*ynab_bulk_delete_transaction/,
  );
});

// --- makeAuditingDeleteApplyOp (dryRun propagation, not a hardcoded literal) -

test('the pre-delete audit record carries the actual dryRun flag', async () => {
  const records = [];
  const audit = async (rec) => { records.push(rec); };
  const applyOp = async () => ({ ok: true });

  // The flag is propagated verbatim — a true value must NOT be overwritten by a
  // hardcoded false (the regression this guards: a misleading record claiming a
  // real delete during a dry-run if the construction guard ever loosens).
  const wrapped = makeAuditingDeleteApplyOp({ applyOp, audit, changeset: { schema_version: 1 }, dryRun: true });
  await wrapped(DELETE_TOOL, validOp());
  assert.equal(records.length, 1);
  assert.equal(records[0].dryRun, true);
  assert.equal(records[0].result.status, 'pending_delete');

  // Omitting dryRun defaults to false — the real-apply construction path today.
  records.length = 0;
  const wrappedDefault = makeAuditingDeleteApplyOp({ applyOp, audit, changeset: { schema_version: 1 } });
  await wrappedDefault(DELETE_TOOL, validOp());
  assert.equal(records[0].dryRun, false);
});

// --- validateNotTransferLeg (GAP-19 / #49: transfer-leg HARD BLOCK) ----------

test('validateNotTransferLeg passes a plain duplicate pair (no transfer signal on either candidate)', () => {
  assert.deepEqual(validateNotTransferLeg(validOp()), { valid: true });
});

test('a non-null transfer_transaction_id on the VICTIM hard-blocks with rule transfer_leg_hard_block', () => {
  const op = validOp();
  op.before.transfer_transaction_id = 't-linked-leg';
  const verdict = validateNotTransferLeg(op);
  assert.equal(verdict.valid, false);
  assert.equal(verdict.error.rule, 'transfer_leg_hard_block');
  assert.equal(verdict.error.op_id, op.id);
  assert.deepEqual(verdict.error.transfer_leg, ['victim']);
  assert.match(verdict.error.reason, /never a duplicate/);
});

test('a non-null transfer_account_id on the TWIN hard-blocks too — checked on BOTH candidates', () => {
  const op = validOp();
  op.twin.transfer_account_id = 'acct-savings';
  const verdict = validateNotTransferLeg(op);
  assert.equal(verdict.valid, false);
  assert.deepEqual(verdict.error.transfer_leg, ['twin']);
});

test('both candidates transfer legs → both named, victim first (a full pair mis-flagged as duplicates)', () => {
  const op = validOp();
  op.before.transfer_account_id = 'acct-b';
  op.twin.transfer_transaction_id = op.transaction_id;
  const verdict = validateNotTransferLeg(op);
  assert.equal(verdict.valid, false);
  assert.deepEqual(verdict.error.transfer_leg, ['victim', 'twin']);
});

test('null / empty-string transfer fields are "no value" — no false-positive block', () => {
  const op = validOp();
  op.before.transfer_account_id = null;
  op.before.transfer_transaction_id = '';
  op.twin.transfer_account_id = null;
  assert.deepEqual(validateNotTransferLeg(op), { valid: true });
});
