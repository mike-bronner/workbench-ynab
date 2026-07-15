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
/** authPreflight that succeeds — a valid, write-capable token (real apply only, #50). */
const okPreflight = () => spy(() => ({ budgets: [{ id: 'b1' }] }));

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
    authPreflight: okPreflight(),
    audit,
  });

  assert.equal(out.ok, true);
  assert.equal(out.reason, OUTCOME.APPLY_COMPLETE);
  assert.equal(out.results[0].status, STATUS.SKIPPED_STALE);
  assert.equal(out.results[0].detail.reason, 'stale');
  // Both candidates were re-read (the victim for drift + shape, the twin for the
  // twin-side live hard block), but nothing was deleted — drift never forces a delete.
  assert.equal(read.calls.length, 2);
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
    authPreflight: okPreflight(),
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
    authPreflight: okPreflight(),
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

// --- (#50) auth-failure handling on the irreversible delete path -----------

/** Build a thrown error carrying an HTTP status — the shape a real MCP port surfaces. */
const httpError = (status, message) => Object.assign(new Error(message || `HTTP ${status}`), { status });
/** The vendored MCP's error shape: a RESOLVED { isError: true } result, NOT a throw. */
const isErrorEnvelope = (status, message) => ({
  isError: true,
  content: [{ type: 'text', text: `{"error":{"message":"${message} (HTTP ${status})"}}` }],
});
/** applyOp (the delete dispatch, 2-arg) that throws `err` for one op id, succeeds otherwise. */
const deleteFailingOn = (failId, err) => spy((_tool, op) => { if (op.id === failId) throw err; return { ok: true }; });

/** A 3-op delete change-set — each victim distinct from its surviving twin (valid evidence). */
function threeDeletes() {
  const base = loadFixture('delete-duplicate.example.json');
  const mk = (n) => {
    const o = clone(base.operations[0]);
    o.id = `op-delete-duplicate-000${n}`;
    o.transaction_id = `t0000000-0000-4000-8000-00000000d0${n}0`;
    o.twin.id = `t0000000-0000-4000-8000-00000000d0${n}1`;
    return o;
  };
  return { ...base, operations: [mk(1), mk(2), mk(3)] };
}

test('(#50) a mid-batch 401 on a delete aborts the batch, records the two-phase trail, and never attempts later deletes', async () => {
  // The highest-stakes path: an irreversible delete on a revoked token mid-batch. op-1
  // deletes, op-2 gets a 401, op-3 must NEVER be attempted (fail-closed). The failed op
  // still leaves the two-phase audit trail #50 guarantees: the pending_delete INTENT
  // (written before the delete ran) then the error/auth_revoked OUTCOME.
  const cs = threeDeletes();
  const [id1, id2, id3] = cs.operations.map((o) => o.id);
  const apply = deleteFailingOn(id2, httpError(401, 'unauthorized'));
  const records = [];
  const audit = async (rec) => { records.push(rec); };

  const out = await applyDeleteDuplicates(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    readLiveState: (o) => clone(o.before), // no drift
    applyOp: apply,
    authPreflight: okPreflight(),
    audit,
  });

  assert.equal(out.ok, false);
  assert.equal(out.aborted, true);
  assert.equal(out.reason, OUTCOME.AUTH_ABORT);
  assert.equal(out.stopped_at_index, 1);
  assert.equal(out.total_ops, 3);
  // op-1 deleted; op-2 errored (auth); op-3 was NEVER processed.
  assert.equal(out.results.length, 2);
  assert.equal(out.results[0].status, STATUS.APPLIED);
  assert.equal(out.results[1].status, STATUS.ERROR);
  assert.equal(out.results[1].detail.error_class, 'auth_revoked');
  assert.equal(out.results[1].detail.applied_state, 'not_applied');
  // The dispatch stopped fail-closed: the delete tool ran for op-1 + op-2 only, never op-3.
  assert.equal(apply.calls.length, 2);
  assert.ok(!apply.calls.some(([, op]) => op.id === id3));
  // Two-phase trail for the FAILED op: a pending_delete intent (before the delete ran),
  // THEN the error/auth_revoked outcome — the ambiguous mid-delete state #50 eliminates.
  const op2Records = records.filter((r) => r.operation.id === id2);
  assert.deepEqual(op2Records.map((r) => r.result.status), ['pending_delete', 'error']);
  assert.equal(op2Records[1].result.error_class, 'auth_revoked');
  assert.equal(op2Records[1].result.applied_state, 'not_applied');
  // op-3 left NO paper trail at all (un-dispatched tail, AC#2) — not even a pending_delete.
  assert.equal(records.some((r) => r.operation.id === id3), false);
});

test('(#50) a delete dispatch that RESOLVES a { isError: true } 401 envelope aborts fail-closed (no fail-open on the destructive path)', async () => {
  // Defense in depth: even if the injected delete port returns the vendored 401 as a
  // RESOLVED { isError: true } result (not a throw), the handler routes it through
  // throwOnErrorResult so it throws → the executor auth-aborts. Without the guard the
  // irreversible path would read the envelope as a "success" and fail OPEN.
  const cs = loadFixture('delete-duplicate.example.json');
  const opId = cs.operations[0].id;
  const apply = spy(() => isErrorEnvelope(401, 'token revoked')); // RESOLVES, does not throw
  const records = [];
  const audit = async (rec) => { records.push(rec); };

  const out = await applyDeleteDuplicates(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    readLiveState: (o) => clone(o.before),
    applyOp: apply,
    authPreflight: okPreflight(),
    audit,
  });

  assert.equal(out.ok, false);
  assert.equal(out.reason, OUTCOME.AUTH_ABORT);
  assert.equal(out.results[0].status, STATUS.ERROR);
  assert.equal(out.results[0].detail.error_class, 'auth_revoked');
  // The intent record was still written before the (failed) dispatch — audit-before-delete.
  const opRecords = records.filter((r) => r.operation.id === opId);
  assert.deepEqual(opRecords.map((r) => r.result.status), ['pending_delete', 'error']);
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
    authPreflight: okPreflight(),
    audit: auditSpy(),
  });
  // Either the schema (risk const) or the guardrail rejects it — never applied.
  assert.equal(out.ok, false);
  assert.notEqual(out.reason, OUTCOME.APPLY_COMPLETE);
});

// --- (GAP-19 / #49) transfer-leg HARD BLOCK — never deletable by this path ---

test('(#49) a non-null transfer_transaction_id on the VICTIM hard-blocks the batch before any read or delete', async () => {
  const cs = loadFixture('delete-duplicate.example.json');
  cs.operations[0].before.transfer_transaction_id = 't-linked-leg';
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

  // A HARD BLOCK, deliberately NOT human_review_required: no confirmation can
  // make a one-leg deletion safe (it corrupts the linked account's ledger).
  assert.equal(out.ok, false);
  assert.equal(out.aborted, true);
  assert.equal(out.reason, 'transfer_leg_hard_block');
  assert.deepEqual(out.results, []);
  assert.equal(out.transferLegBlocks.length, 1);
  assert.equal(out.transferLegBlocks[0].rule, 'transfer_leg_hard_block');
  assert.deepEqual(out.transferLegBlocks[0].transfer_leg, ['victim']);
  // No port was touched — not the read, not the delete, not the audit.
  assert.equal(read.calls.length, 0);
  assert.equal(apply.calls.length, 0);
  assert.equal(audit.calls.length, 0);
});

test('(#49) a transfer signal on the surviving TWIN hard-blocks too — the pair is legitimate, never duplicates', async () => {
  const cs = loadFixture('delete-duplicate.example.json');
  cs.operations[0].twin.transfer_account_id = 'acct-savings';
  const apply = spy();
  const out = await applyDeleteDuplicates(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    readLiveState: noDrift(),
    applyOp: apply,
    audit: auditSpy(),
  });
  assert.equal(out.reason, 'transfer_leg_hard_block');
  assert.deepEqual(out.transferLegBlocks[0].transfer_leg, ['twin']);
  assert.equal(apply.calls.length, 0);
});

test('(#49) the transfer-leg hard block OUTRANKS twin-evidence validation (checked first, dry-run included)', async () => {
  const cs = loadFixture('delete-duplicate.example.json');
  cs.operations[0].before.transfer_account_id = 'acct-savings';
  delete cs.operations[0].twin.amount; // also twin-invalid — the hard block must still win
  const out = await applyDeleteDuplicates(cs, {
    activeBudgetId: cs.budget_id,
    // dryRun omitted → defaults to true; the hard block fires in dry-run too
    readLiveState: noDrift(),
    applyOp: spy(),
    audit: auditSpy(),
  });
  assert.equal(out.reason, 'transfer_leg_hard_block');
  assert.equal(out.dry_run, true);
});

test('(#49) a LIVE transfer leg is hard-blocked from the live read even when the snapshot OMITS the transfer fields — the delete tool is never invoked', async () => {
  // The fail-open payload: the fixture's `before` / `twin` carry NO transfer fields
  // (they are schema-optional), so the snapshot-based pre-flight passes — but the
  // LIVE transaction IS a real transfer leg. The shape-guarded readLiveState must
  // re-derive that from the live read and stop the delete.
  const cs = loadFixture('delete-duplicate.example.json');
  assert.ok(!('transfer_account_id' in cs.operations[0].before)); // the omission is the point
  assert.ok(!('transfer_transaction_id' in cs.operations[0].twin));
  const apply = spy();
  // Full victim projection per skills/delete-duplicate.md: live carries the
  // transfer evidence the snapshot withheld.
  const read = spy((op) => ({ ...clone(op.before), transfer_account_id: null, transfer_transaction_id: 't-linked-leg' }));
  const out = await applyDeleteDuplicates(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    readLiveState: read,
    applyOp: apply,
    authPreflight: okPreflight(),
    audit: auditSpy(),
  });

  const res = out.results.find((r) => r.op_id === cs.operations[0].id);
  assert.equal(res.status, STATUS.ERROR); // terminal per-op — never dispatched
  assert.match(res.detail.message, /transfer_leg_hard_block/);
  assert.equal(apply.calls.length, 0, 'the delete tool must NEVER be invoked for a live transfer leg');
});

test('(#49) a LIVE transfer-leg TWIN is hard-blocked from the live read even when the snapshot OMITS the transfer fields — the delete tool is never invoked', async () => {
  // The twin-side fail-open payload: `twin` carries NO transfer fields (they are
  // schema-optional), so the snapshot-based validateNotTransferLeg passes — but the
  // LIVE surviving twin IS a real transfer leg, proving the "duplicate pair" is a
  // legitimate transfer pair. The shape-guarded readLiveState must re-derive that
  // from a live read of the twin's own id and stop the victim delete.
  const cs = loadFixture('delete-duplicate.example.json');
  assert.ok(!('transfer_account_id' in cs.operations[0].twin)); // the omission is the point
  assert.ok(!('transfer_transaction_id' in cs.operations[0].twin));
  const twinId = cs.operations[0].twin.id;
  const apply = spy();
  // The port resolves whatever `op.transaction_id` names (skills/delete-duplicate.md):
  // the victim reads back clean (no drift, no transfer signal); the twin reads back
  // as the live transfer leg the snapshot withheld.
  const read = spy((op) => (op.transaction_id === twinId
    ? { ...clone(cs.operations[0].twin), transfer_account_id: 'acct-savings', transfer_transaction_id: 't-linked-leg' }
    : clone(op.before)));
  const out = await applyDeleteDuplicates(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    readLiveState: read,
    applyOp: apply,
    authPreflight: okPreflight(),
    audit: auditSpy(),
  });

  const res = out.results.find((r) => r.op_id === cs.operations[0].id);
  assert.equal(res.status, STATUS.ERROR); // terminal per-op — never dispatched
  assert.match(res.detail.message, /transfer_leg_hard_block/);
  assert.match(res.detail.message, /TWIN/);
  assert.equal(read.calls.length, 2, 'BOTH candidates are live-read: the victim, then the twin by its own id');
  assert.equal(read.calls[1][0].transaction_id, twinId);
  assert.equal(apply.calls.length, 0, 'the delete tool must NEVER be invoked when the live twin is a transfer leg');
});
