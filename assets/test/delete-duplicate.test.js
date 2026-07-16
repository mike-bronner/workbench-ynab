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

test('a delete op with no victim transaction_id is rejected before any MCP call (victim_id_missing, #151)', async () => {
  const cs = loadFixture('delete-duplicate.example.json');
  // Strip the victim id: the op cannot name its target, and an absent id (undefined)
  // would slip past the twin_is_victim collision guard (undefined !== twin.id) — the
  // pre-flight's presence check must reject it end-to-end, symmetric with the
  // twin_evidence_missing / twin_is_victim cases above.
  delete cs.operations[0].transaction_id;
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
  assert.equal(out.twinErrors[0].rule, 'victim_id_missing');
  assert.equal(out.twinErrors[0].op_id, cs.operations[0].id);
  assert.deepEqual(out.twinErrors[0].missing, ['transaction_id']);
  assert.deepEqual(out.results, []);
  // No port was touched — not the read, not the delete, not the audit.
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

// --- (#151) surviving-twin liveness + drift — never delete the only copy -----

test('(#151) a surviving twin that NO LONGER EXISTS live aborts the delete — a fresh victim never deletes the only remaining copy', async () => {
  // The data-loss scenario #151 closes: the twin is deleted by another process
  // (e.g. the YNAB app) during the generate → approve → apply window. The victim's
  // own `before` snapshot is UNCHANGED — the op is not stale — so without the twin
  // liveness gate the victim would be deleted, removing the only remaining copy.
  const cs = loadFixture('delete-duplicate.example.json');
  const twinId = cs.operations[0].twin.id;
  const apply = spy();
  // The victim reads back clean (no drift); the twin's live read resolves to
  // nothing (the projected shape of a transaction that is gone).
  const read = spy((op) => (op.transaction_id === twinId ? null : clone(op.before)));
  const records = [];

  const out = await applyDeleteDuplicates(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    readLiveState: read,
    applyOp: apply,
    authPreflight: okPreflight(),
    audit: async (rec) => { records.push(rec); },
  });

  const res = out.results.find((r) => r.op_id === cs.operations[0].id);
  assert.equal(res.status, STATUS.ERROR); // terminal per-op — never dispatched
  assert.match(res.detail.message, /twin_missing/);
  assert.match(res.detail.message, /only remaining copy/i);
  assert.equal(read.calls.length, 2, 'BOTH candidates are live-read: the victim, then the twin by its own id');
  assert.equal(read.calls[1][0].transaction_id, twinId);
  assert.equal(apply.calls.length, 0, 'the delete tool must NEVER be invoked when the surviving twin is gone');
  // The abort is not silent: the errored op still leaves a paper trail, and no
  // pending_delete intent was written (the wrapped applyOp never ran).
  assert.equal(records.some((r) => r.result.status === STATUS.ERROR), true);
  assert.equal(records.some((r) => r.result.status === 'pending_delete'), false);
});

test('(#151) a surviving twin that MATERIALLY CHANGED live aborts the delete even though the victim itself has not drifted', async () => {
  const cs = loadFixture('delete-duplicate.example.json');
  const twinId = cs.operations[0].twin.id;
  const apply = spy();
  // The victim reads back clean; the live twin's amount no longer matches the
  // evidence the human approved — the pairing is unproven.
  const read = spy((op) => (op.transaction_id === twinId
    ? { ...clone(cs.operations[0].twin), amount: cs.operations[0].twin.amount + 1000 }
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
  assert.match(res.detail.message, /twin_drifted/);
  assert.match(res.detail.message, /amount/);
  assert.equal(apply.calls.length, 0, 'the delete tool must NEVER be invoked when the surviving twin drifted');
});

test('(#151) a live twin whose PAYEE_NAME drifted aborts the delete — every evidence field is drift-checked, not just amount', async () => {
  // Pins payee_name as a decisive drift field in its own right: a refactor that
  // narrows the checked field list (dropping payee_name) must fail this test.
  const cs = loadFixture('delete-duplicate.example.json');
  const twinId = cs.operations[0].twin.id;
  const apply = spy();
  // The victim reads back clean; the live twin's payee no longer matches the
  // evidence the human approved.
  const read = spy((op) => (op.transaction_id === twinId
    ? { ...clone(cs.operations[0].twin), payee_name: 'Amazon Marketplace' }
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
  assert.match(res.detail.message, /twin_drifted/);
  assert.match(res.detail.message, /payee_name/);
  assert.equal(apply.calls.length, 0, 'the delete tool must NEVER be invoked when the surviving twin drifted on payee_name');
});

test('(#151) a live twin whose DATE drifted aborts the delete — every evidence field is drift-checked, not just amount', async () => {
  // Pins date as a decisive drift field in its own right: a refactor that
  // narrows the checked field list (dropping date) must fail this test.
  const cs = loadFixture('delete-duplicate.example.json');
  const twinId = cs.operations[0].twin.id;
  const apply = spy();
  // The victim reads back clean; the live twin's date no longer matches the
  // evidence the human approved.
  const read = spy((op) => (op.transaction_id === twinId
    ? { ...clone(cs.operations[0].twin), date: '2026-06-13' }
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
  assert.match(res.detail.message, /twin_drifted/);
  assert.match(res.detail.message, /date/);
  assert.equal(apply.calls.length, 0, 'the delete tool must NEVER be invoked when the surviving twin drifted on date');
});

test('(#151) a STALE victim with a missing twin is skipped-stale, not errored — the twin gate is decisive only when the victim is fresh', async () => {
  // Pins the deliberate `if (!isStale(op.before, live))` short-circuit: when the
  // victim ITSELF is stale, the executor's own victim-drift skip owns the outcome
  // (richer skip detail, pinned behavior) and the twin liveness gate stands down —
  // even though the twin is gone. Either way nothing is deleted; this test makes
  // the precedence intentional instead of collateral from an unrelated drift test.
  const cs = loadFixture('delete-duplicate.example.json');
  const twinId = cs.operations[0].twin.id;
  const apply = spy();
  // The victim reads back drifted (stale op) AND the twin's live read resolves
  // to nothing — both conditions at once.
  const read = spy((op) => (op.transaction_id === twinId
    ? null
    : { ...clone(op.before), amount: op.before.amount + 1 }));

  const out = await applyDeleteDuplicates(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    readLiveState: read,
    applyOp: apply,
    authPreflight: okPreflight(),
    audit: auditSpy(),
  });

  assert.equal(out.ok, true);
  const res = out.results.find((r) => r.op_id === cs.operations[0].id);
  assert.equal(res.status, STATUS.SKIPPED_STALE, 'the stale victim is SKIPPED by the executor, never errored by the twin gate');
  assert.equal(res.detail.reason, 'stale');
  assert.equal(read.calls.length, 2, 'BOTH candidates are still live-read: the victim, then the twin by its own id');
  assert.equal(apply.calls.length, 0, 'the delete tool must NEVER be invoked for a stale victim');
});

// --- (#151) batch twin↔victim collisions — multi-op, REAL mutating store ----
//
// Every other #151 test is single-op against a fixed-response stub, which cannot
// exhibit the batch hole: the executor prepares EVERY op (all liveness reads)
// before dispatching ANY delete, so two ops that delete each other's survivors
// both read pre-dispatch state, both pass the live twin gate, and both dispatch.
// These tests run a real in-memory store whose applyOp genuinely REMOVES rows,
// so "both copies survive" is observed on actual state, not inferred from spies.

/** A REAL mutating in-memory store: reads resolve current rows, applies DELETE them. */
function makeStatefulStore(rows) {
  const store = new Map(rows.map((r) => [r.id, clone(r)]));
  const read = spy(async (op) => {
    const row = store.get(op.transaction_id);
    return row ? clone(row) : null;
  });
  const apply = spy(async (toolName, op) => {
    store.delete(op.transaction_id);
    return { ok: true };
  });
  return { store, read, apply };
}

/** Clone the fixture's delete op with the given op / victim / twin ids swapped in. */
function makeDeleteOp(base, { opId, victimId, twinId }) {
  const op = clone(base.operations[0]);
  op.id = opId;
  op.transaction_id = victimId;
  op.twin = { ...op.twin, id: twinId };
  return op;
}

/** A live row for the given id, shaped like the fixture victim (duplicates share fields). */
const makeRow = (base, id) => ({ id, ...clone(base.operations[0].before) });

test('(#151) a RECIPROCAL twin↔victim pair aborts the change-set — a batch can never delete both copies', async () => {
  // op1: victim=A/twin=B, op2: victim=B/twin=A. Both ops' liveness reads would run
  // pre-dispatch and see the other side alive — without the batch guard, BOTH
  // deletes dispatch and the store is emptied. The pre-flight must reject instead.
  const base = loadFixture('delete-duplicate.example.json');
  const [idA, idB] = ['t0000000-0000-4000-8000-00000000d00a', 't0000000-0000-4000-8000-00000000d00b'];
  const cs = {
    ...base,
    operations: [
      makeDeleteOp(base, { opId: 'op-delete-duplicate-0001', victimId: idA, twinId: idB }),
      makeDeleteOp(base, { opId: 'op-delete-duplicate-0002', victimId: idB, twinId: idA }),
    ],
  };
  const { store, read, apply } = makeStatefulStore([makeRow(base, idA), makeRow(base, idB)]);
  const audit = auditSpy();

  const out = await applyDeleteDuplicates(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    readLiveState: read,
    applyOp: apply,
    authPreflight: okPreflight(),
    audit,
  });

  assert.equal(out.ok, false);
  assert.equal(out.aborted, true);
  assert.equal(out.reason, 'twin_batch_collision');
  assert.deepEqual(out.results, []);
  // BOTH sides of the reciprocal pair are reported.
  assert.equal(out.batchCollisions.length, 2);
  assert.deepEqual(out.batchCollisions.map((c) => c.rule), ['twin_batch_collision', 'twin_batch_collision']);
  assert.deepEqual(out.batchCollisions[0], {
    op_id: 'op-delete-duplicate-0001',
    rule: 'twin_batch_collision',
    reason: out.batchCollisions[0].reason,
    twin_id: idB,
    victim_op_ids: ['op-delete-duplicate-0002'],
  });
  // No port was touched — not the read, not the delete, not the audit.
  assert.equal(read.calls.length, 0);
  assert.equal(apply.calls.length, 0);
  assert.equal(audit.calls.length, 0);
  // The real store still holds BOTH copies — the outcome the guard exists for.
  assert.deepEqual([...store.keys()].sort(), [idA, idB]);
});

test('(#151) an OVERLAPPING chain aborts too — a victim\'s intended survivor is a batch-mate\'s victim', async () => {
  // op1: victim=B/twin=A, op2: victim=C/twin=B. Without the batch guard the batch
  // deletes C AND its intended survivor B, leaving only A. The pre-flight must
  // reject, naming op2 (whose survivor a batch-mate deletes) and op1 (the deleter).
  const base = loadFixture('delete-duplicate.example.json');
  const [idA, idB, idC] = [
    't0000000-0000-4000-8000-00000000d00a',
    't0000000-0000-4000-8000-00000000d00b',
    't0000000-0000-4000-8000-00000000d00c',
  ];
  const cs = {
    ...base,
    operations: [
      makeDeleteOp(base, { opId: 'op-delete-duplicate-0001', victimId: idB, twinId: idA }),
      makeDeleteOp(base, { opId: 'op-delete-duplicate-0002', victimId: idC, twinId: idB }),
    ],
  };
  const { store, read, apply } = makeStatefulStore([makeRow(base, idA), makeRow(base, idB), makeRow(base, idC)]);
  const audit = auditSpy();

  const out = await applyDeleteDuplicates(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    readLiveState: read,
    applyOp: apply,
    authPreflight: okPreflight(),
    audit,
  });

  assert.equal(out.ok, false);
  assert.equal(out.aborted, true);
  assert.equal(out.reason, 'twin_batch_collision');
  assert.equal(out.batchCollisions.length, 1);
  assert.equal(out.batchCollisions[0].op_id, 'op-delete-duplicate-0002');
  assert.equal(out.batchCollisions[0].twin_id, idB);
  assert.deepEqual(out.batchCollisions[0].victim_op_ids, ['op-delete-duplicate-0001']);
  assert.equal(read.calls.length, 0);
  assert.equal(apply.calls.length, 0);
  assert.equal(audit.calls.length, 0);
  // Nothing was deleted — all three rows survive.
  assert.deepEqual([...store.keys()].sort(), [idA, idB, idC]);
});

test('(#151) DISTINCT duplicate pairs in one batch proceed — the batch guard adds no false positives, and the store proves the harness mutates', async () => {
  // op1: victim=A/twin=B, op2: victim=C/twin=D — no cross-op collision. Both apply
  // for real against the mutating store: exactly the victims vanish, both survivors
  // remain. This also proves makeStatefulStore genuinely deletes, so the two abort
  // tests above assert "store unchanged" against a harness that COULD have emptied it.
  const base = loadFixture('delete-duplicate.example.json');
  const [idA, idB, idC, idD] = [
    't0000000-0000-4000-8000-00000000d00a',
    't0000000-0000-4000-8000-00000000d00b',
    't0000000-0000-4000-8000-00000000d00c',
    't0000000-0000-4000-8000-00000000d00d',
  ];
  const cs = {
    ...base,
    operations: [
      makeDeleteOp(base, { opId: 'op-delete-duplicate-0001', victimId: idA, twinId: idB }),
      makeDeleteOp(base, { opId: 'op-delete-duplicate-0002', victimId: idC, twinId: idD }),
    ],
  };
  const { store, read, apply } = makeStatefulStore([idA, idB, idC, idD].map((id) => makeRow(base, id)));

  const out = await applyDeleteDuplicates(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    readLiveState: read,
    applyOp: apply,
    authPreflight: okPreflight(),
    audit: auditSpy(),
  });

  assert.equal(out.ok, true);
  assert.deepEqual(out.results.map((r) => r.status), [STATUS.APPLIED, STATUS.APPLIED]);
  assert.equal(apply.calls.length, 2);
  assert.ok(apply.calls.every((c) => c[0] === DELETE_TOOL));
  // Exactly the victims were removed; both survivors remain.
  assert.deepEqual([...store.keys()].sort(), [idB, idD]);
});

test('(#151) an unchanged live twin lets a clean delete proceed — the gate adds no false positives', async () => {
  const cs = loadFixture('delete-duplicate.example.json');
  const twinId = cs.operations[0].twin.id;
  const apply = spy(() => ({ ok: true }));
  // Both candidates read back exactly as the evidence promised.
  const read = spy((op) => (op.transaction_id === twinId ? clone(cs.operations[0].twin) : clone(op.before)));

  const out = await applyDeleteDuplicates(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    readLiveState: read,
    applyOp: apply,
    authPreflight: okPreflight(),
    audit: auditSpy(),
  });

  assert.equal(out.ok, true);
  assert.equal(out.results[0].status, STATUS.APPLIED);
  assert.equal(apply.calls.length, 1);
  assert.equal(apply.calls[0][0], DELETE_TOOL);
});
