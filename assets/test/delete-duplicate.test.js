'use strict';

/**
 * Integration tests for the M4-8 duplicate-fix (delete) write path.
 *
 * These exercise applyDeleteDuplicates end-to-end through the real M4-4 executor
 * and Ajv-backed validator, so install the assets deps first:
 *   npm --prefix assets install
 *   npm --prefix assets test          # node --test
 *
 * They load the real delete-duplicate fixture so the path is tested against the
 * exact envelope M4 produces, and resolve the delete tool from the guardrail's
 * exported ALLOWED_TOOLS — never a literal `mcp__plugin_workbench-ynab_ynab__*`
 * string (issue #87 guard). Pure-helper coverage (twin validation, preview,
 * dollars, strong-confirmation) lives in the CI-gated tests/unit/delete-duplicate.test.mjs.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const {
  applyDeleteDuplicates,
  buildToolMap,
  DELETE_TOOL,
  OP_TYPE,
} = require('../delete-duplicate');
const { STATUS, OUTCOME } = require('../apply-executor');
const { ALLOWED_TOOLS, evaluateTool } = require('../write-safety-guardrail');

const FIXTURES = path.join(__dirname, '..', 'fixtures');
const loadFixture = (name) => JSON.parse(fs.readFileSync(path.join(FIXTURES, name), 'utf8'));
const clone = (x) => JSON.parse(JSON.stringify(x));

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

/** readLiveState that echoes each op's own `before` snapshot → never stale. */
const noDrift = () => spy((op) => clone(op.before));
const auditSpy = () => spy(() => undefined);

// --- registration point ----------------------------------------------------

test('the delete tool is resolved from the guardrail allow-list, never hard-coded', () => {
  assert.ok(DELETE_TOOL, 'DELETE_TOOL resolved');
  assert.ok(DELETE_TOOL.endsWith('_delete_transaction'));
  assert.ok(ALLOWED_TOOLS.includes(DELETE_TOOL), 'delete tool is on the ledger-only allow-list');
  assert.equal(evaluateTool(DELETE_TOOL).verdict, 'pass');
});

test('buildToolMap registers delete_duplicate → the namespaced delete tool', () => {
  assert.deepEqual(buildToolMap(), { [OP_TYPE]: DELETE_TOOL });
});

// --- AC: twin evidence rejected before any MCP call ------------------------

test('a delete_duplicate op missing twin evidence is rejected before any MCP call is made', async () => {
  const cs = loadFixture('delete-duplicate.example.json');
  delete cs.operations[0].twin; // strip the surviving-twin evidence
  const read = noDrift();
  const apply = spy();
  const audit = auditSpy();

  const out = await applyDeleteDuplicates(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    readLiveState: read,
    applyOp: apply,
    audit,
  });

  assert.equal(out.ok, false);
  assert.equal(out.reason, 'twin_evidence_missing');
  assert.equal(out.aborted, true);
  assert.deepEqual(out.results, []);
  assert.equal(out.twinErrors.length, 1);
  assert.equal(out.twinErrors[0].op_id, cs.operations[0].id);
  assert.deepEqual(out.twinErrors[0].missing, ['id', 'payee_name', 'amount', 'date']);
  // No port was touched — not the read, not the delete, not the audit.
  assert.equal(read.calls.length, 0);
  assert.equal(apply.calls.length, 0);
  assert.equal(audit.calls.length, 0);
});

test('a partially-malformed twin (missing one field) is also rejected before any MCP call', async () => {
  const cs = loadFixture('delete-duplicate.example.json');
  delete cs.operations[0].twin.amount; // a single missing field is enough to reject
  const apply = spy();
  const out = await applyDeleteDuplicates(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    readLiveState: noDrift(),
    applyOp: apply,
    audit: auditSpy(),
  });
  assert.equal(out.reason, 'twin_evidence_missing');
  assert.deepEqual(out.twinErrors[0].missing, ['amount']);
  assert.equal(apply.calls.length, 0);
});

test('a delete op whose victim IS the surviving twin is rejected before any MCP call (never deletes the only copy)', async () => {
  const cs = loadFixture('delete-duplicate.example.json');
  // The highest-blast-radius failure: name the survivor as the victim. Field
  // presence is complete, so only the cross-field guard can stop it.
  cs.operations[0].twin.id = cs.operations[0].transaction_id;
  const read = noDrift();
  const apply = spy();
  const audit = auditSpy();

  const out = await applyDeleteDuplicates(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    readLiveState: read,
    applyOp: apply,
    audit,
  });

  assert.equal(out.ok, false);
  assert.equal(out.aborted, true);
  assert.equal(out.reason, 'twin_evidence_missing');
  assert.equal(out.twinErrors[0].rule, 'twin_is_victim');
  assert.deepEqual(out.results, []);
  // Nothing was touched — not the read, not the delete, not the audit.
  assert.equal(read.calls.length, 0);
  assert.equal(apply.calls.length, 0);
  assert.equal(audit.calls.length, 0);
});

test('every failing delete op accumulates — a multi-op change-set reports all twin errors, not just the first', async () => {
  // The fixtures are single-op, so the accumulate-vs-short-circuit loop in
  // applyDeleteDuplicates was previously unverified. Build a two-op change-set where
  // BOTH deletes fail twin evidence (for different reasons) and assert both surface.
  const base = loadFixture('delete-duplicate.example.json');
  const op2 = clone(base.operations[0]);
  op2.id = 'op-delete-duplicate-0002';
  op2.transaction_id = 't0000000-0000-4000-8000-00000000d004';
  const cs = { ...base, operations: [clone(base.operations[0]), op2] };
  delete cs.operations[0].twin;          // op 1: no twin object at all
  delete cs.operations[1].twin.date;     // op 2: a single missing twin field
  const read = noDrift();
  const apply = spy();
  const audit = auditSpy();

  const out = await applyDeleteDuplicates(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    readLiveState: read,
    applyOp: apply,
    audit,
  });

  assert.equal(out.ok, false);
  assert.equal(out.reason, 'twin_evidence_missing');
  assert.equal(out.aborted, true);
  // Both ops are reported — the loop accumulates, it does not return on the first.
  assert.equal(out.twinErrors.length, 2);
  assert.deepEqual(out.twinErrors.map((e) => e.op_id), ['op-delete-duplicate-0001', 'op-delete-duplicate-0002']);
  assert.deepEqual(out.twinErrors[1].missing, ['date']);
  // A single bad op aborts the whole batch before any port is touched.
  assert.equal(read.calls.length, 0);
  assert.equal(apply.calls.length, 0);
  assert.equal(audit.calls.length, 0);
});

// --- AC: drift = abort for that op -----------------------------------------

test('a delete_duplicate op whose victim has drifted is marked stale and skipped, not applied', async () => {
  const cs = loadFixture('delete-duplicate.example.json');
  const opId = cs.operations[0].id;
  // Live victim differs from the `before` snapshot (amount changed since generation).
  const read = spy((op) => ({ ...clone(op.before), amount: op.before.amount + 1 }));
  const apply = spy(() => ({ ok: true }));
  const audit = auditSpy();

  const out = await applyDeleteDuplicates(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    readLiveState: read,
    applyOp: apply,
    audit,
  });

  assert.equal(out.ok, true);
  assert.equal(out.reason, OUTCOME.APPLY_COMPLETE);
  assert.equal(out.results[0].status, STATUS.SKIPPED_STALE);
  assert.equal(out.results[0].detail.reason, 'stale');
  // The victim was re-read, but never deleted — drift never forces a delete.
  assert.equal(read.calls.length, 1);
  assert.equal(apply.calls.length, 0);
  // Skipping is not silent: the stale op still leaves a paper trail. Exactly one
  // audit record was written, stamping the skipped-stale status (and no pending_delete
  // record, since no delete preceded — the wrapped applyOp never ran).
  assert.equal(audit.calls.length, 1);
  assert.equal(audit.calls[0][0].result.status, STATUS.SKIPPED_STALE);
  assert.equal(audit.calls.some((c) => c[0].result.status === 'pending_delete'), false);
});

// --- dry-run preview path: nothing mutated ---------------------------------

test('dry-run (the default) simulates the delete and calls no mutating tool', async () => {
  const cs = loadFixture('delete-duplicate.example.json');
  const apply = spy();
  const out = await applyDeleteDuplicates(cs, {
    activeBudgetId: cs.budget_id,
    // dryRun omitted → defaults to true
    readLiveState: noDrift(),
    applyOp: apply,
    audit: auditSpy(),
  });
  assert.equal(out.ok, true);
  assert.equal(out.dry_run, true);
  assert.equal(out.results[0].status, STATUS.APPLIED);
  assert.equal(out.results[0].detail.simulated, true);
  assert.equal(apply.calls.length, 0); // no real delete in dry-run
});

// --- real apply: dispatch + audit-before-delete ----------------------------

test('real apply dispatches exactly the registered delete tool for the victim', async () => {
  const cs = loadFixture('delete-duplicate.example.json');
  const apply = spy(() => ({ ok: true }));
  const out = await applyDeleteDuplicates(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    readLiveState: noDrift(),
    applyOp: apply,
    audit: auditSpy(),
  });
  assert.equal(out.results[0].status, STATUS.APPLIED);
  assert.equal(out.results[0].dry_run, false);
  assert.equal(apply.calls.length, 1);
  assert.equal(apply.calls[0][0], DELETE_TOOL);
  assert.equal(apply.calls[0][1].id, cs.operations[0].id);
});

test('the full before-snapshot is audited BEFORE the irreversible delete, not after', async () => {
  const cs = loadFixture('delete-duplicate.example.json');
  const op = cs.operations[0];
  const events = [];
  const records = [];
  const audit = async (rec) => { events.push(`audit:${rec.result.status}`); records.push(rec); };
  const apply = async (toolName, applied) => { events.push(`apply:${applied.id}`); return { ok: true }; };

  await applyDeleteDuplicates(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    readLiveState: (o) => clone(o.before),
    applyOp: apply,
    audit,
  });

  // Ordering: pending-delete snapshot is written, THEN the delete runs, THEN the result.
  const pendingIdx = events.indexOf('audit:pending_delete');
  const applyIdx = events.indexOf(`apply:${op.id}`);
  const appliedIdx = events.indexOf(`audit:${STATUS.APPLIED}`);
  assert.ok(pendingIdx >= 0, 'a pending_delete record was written');
  assert.ok(pendingIdx < applyIdx, 'snapshot audited before the delete');
  assert.ok(applyIdx < appliedIdx, 'result audited after the delete');

  // The pre-delete record carries the FULL victim state (audit completeness).
  const pre = records.find((r) => r.result.status === 'pending_delete');
  assert.equal(pre.dryRun, false);
  assert.equal(pre.result.tool, DELETE_TOOL);
  for (const field of ['payee_name', 'amount', 'date', 'category_id', 'account_id', 'cleared', 'memo']) {
    assert.ok(field in pre.operation.before, `before-snapshot carries ${field}`);
  }
  assert.equal(pre.result.schema_version, cs.schema_version);
});

test('dry-run writes no pending_delete record (no delete to precede)', async () => {
  const cs = loadFixture('delete-duplicate.example.json');
  const records = [];
  await applyDeleteDuplicates(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: true,
    readLiveState: (o) => clone(o.before),
    audit: async (rec) => { records.push(rec); },
  });
  assert.equal(records.some((r) => r.result.status === 'pending_delete'), false);
});

// --- guardrail still governs the path --------------------------------------

test('a delete op missing risk:destructive is blocked by the guardrail through this path', async () => {
  const cs = loadFixture('delete-duplicate.example.json');
  cs.operations[0].risk = 'low'; // schema oneOf still matches via the other fields? force the guardrail path
  const out = await applyDeleteDuplicates(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    readLiveState: noDrift(),
    applyOp: spy(),
    audit: auditSpy(),
  });
  // Either the schema (risk const) or the guardrail rejects it — never applied.
  assert.equal(out.ok, false);
  assert.notEqual(out.reason, OUTCOME.APPLY_COMPLETE);
});
