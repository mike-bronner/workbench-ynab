'use strict';

/**
 * Unit tests for the M4-4 apply executor.
 *
 * Run with Node's built-in test runner. The executor requires the change-set
 * validator (Ajv), so install the assets deps first:
 *   npm --prefix assets install
 *   npm --prefix assets test          # node --test
 *
 * Pass cases load the real change-set contract fixtures (assets/fixtures/*) so the
 * executor is tested against the exact envelopes M4 produces. The injected ports
 * (readLiveState / applyOp / audit) are mocked as spies, and tool names are taken
 * from the guardrail's exported ALLOWED_TOOLS — never typed as literals here — so
 * this file holds no hard-coded namespaced tool name (issue #87 guard).
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const { applyChangeset, isStale, deepEqual, STATUS, OUTCOME } = require('../apply-executor');
const { ALLOWED_TOOLS } = require('../write-safety-guardrail');

const FIXTURES = path.join(__dirname, '..', 'fixtures');
const loadFixture = (name) => JSON.parse(fs.readFileSync(path.join(FIXTURES, name), 'utf8'));
const clone = (x) => JSON.parse(JSON.stringify(x));

// op-type → allowed namespaced tool, resolved from the guardrail's allow-list by
// suffix so no literal `mcp__plugin_workbench-ynab_ynab__*` string lives in this file.
const pick = (suffix) => ALLOWED_TOOLS.find((t) => t.endsWith(suffix));
const TOOL_MAP = {
  categorize: pick('_update_transaction'),
  allocate: pick('_update_category'),
  delete_duplicate: pick('_delete_transaction'),
  reconcile: pick('_reconcile_account'),
};

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

/** A no-op audit sink spy. */
const auditSpy = () => spy(() => undefined);

/** authPreflight that succeeds — a valid, write-capable token (real apply only). */
const okPreflight = () => spy(() => ({ budgets: [{ id: 'b1' }] }));

/** Build a thrown error carrying an HTTP status, the shape a real MCP port surfaces. */
const httpError = (status, message) => Object.assign(new Error(message || `HTTP ${status}`), { status });

// --- opt-in bulk dispatch fixtures -----------------------------------------

const BUDGET = 'b1f2c3d4-1111-4a2b-9c3d-000000000001'; // the shared fixtures' budget
const SINGLE_TOOL = pick('_update_transaction');
const BULK_TOOL = pick('_update_transactions');
/** A group of ≥2 ops each carrying a resolved category_id may go through one bulk call. */
const bulkFits = (ops) => ops.length >= 2 && ops.every((o) => o.after && typeof o.after.category_id === 'string');

/**
 * A well-shaped `ynab_update_transactions` response marking every requested op
 * `updated` — the REAL vendored shape (`{ success, summary, results:[{ request_index,
 * status, transaction_id }] }`), not an off-contract `{ ok: true }`. Fed the ops the
 * bulk port was called with, so `request_index` lines up one-to-one with the request.
 */
const bulkAllUpdated = (ops) => ({
  success: true,
  summary: { total_requested: ops.length, updated: ops.length, failed: 0 },
  results: ops.map((op, i) => ({ request_index: i, status: 'updated', transaction_id: op.transaction_id, correlation_key: `k${i}` })),
});

/** A schema-valid change-set with two categorize ops sharing the fixtures' budget. */
const twoCategorize = () => ({
  schema_version: '1.0.0',
  generated_at: '2026-06-19T14:30:00Z',
  budget_id: BUDGET,
  budget_name: 'Family Budget',
  source: 'manual',
  money_movement: false,
  operations: [
    { id: 'op-1', type: 'categorize', budget_id: BUDGET, transaction_id: 't-a', before: { category_id: null, category_name: null }, after: { category_id: 'c-a', category_name: 'A' }, rationale: 'r', risk: 'low' },
    { id: 'op-2', type: 'categorize', budget_id: BUDGET, transaction_id: 't-b', before: { category_id: null, category_name: null }, after: { category_id: 'c-b', category_name: 'B' }, rationale: 'r', risk: 'low' },
  ],
});

/** A schema-valid change-set with three categorize ops sharing the fixtures' budget. */
const threeCategorize = () => {
  const cs = twoCategorize();
  cs.operations.push({ id: 'op-3', type: 'categorize', budget_id: BUDGET, transaction_id: 't-c', before: { category_id: null, category_name: null }, after: { category_id: 'c-c', category_name: 'C' }, rationale: 'r', risk: 'low' });
  return cs;
};

const bulkCtx = (over = {}) => ({
  activeBudgetId: BUDGET,
  dryRun: false,
  toolMap: { categorize: SINGLE_TOOL },
  bulkToolMap: { categorize: BULK_TOOL },
  bulkApplyOp: spy((_tool, ops) => bulkAllUpdated(ops)),
  bulkFits,
  readLiveState: noDrift(),
  applyOp: spy(() => ({ ok: true })),
  authPreflight: okPreflight(), // #50 — preflight is mandatory on every real-apply run
  audit: auditSpy(),
  ...over,
});

// --- helpers: deepEqual / isStale -----------------------------------------

test('deepEqual compares integer milliunits exactly and never coerces to float', () => {
  assert.equal(deepEqual(250000, 250000), true);
  assert.equal(deepEqual(250000, 250000.0), true); // 250000.0 === 250000 in JS — still an integer compare
  assert.equal(deepEqual({ budgeted: 250000 }, { budgeted: 250001 }), false);
  assert.equal(deepEqual([1, 2, 3], [1, 2, 3]), true);
  assert.equal(deepEqual({ a: 1 }, { a: 1, b: 2 }), false);
});

test('isStale compares only the keys present in `before` (subset match)', () => {
  const before = { category_id: null, category_name: null };
  assert.equal(isStale(before, { category_id: null, category_name: null, extra: 'ignored' }), false);
  assert.equal(isStale(before, { category_id: 'c9', category_name: 'Groceries' }), true);
});

test('isStale fails closed when before or live is not a comparable object', () => {
  assert.equal(isStale({ x: 1 }, null), true);
  assert.equal(isStale(null, { x: 1 }), true);
  assert.equal(isStale({ x: 1 }, [1]), true);
});

// --- (a) dry-run with no drift ---------------------------------------------

test('(a) dry-run with no drift: every op is simulated, nothing is mutated', async () => {
  const cs = loadFixture('combined.example.json');
  const read = noDrift();
  const apply = spy();
  const audit = auditSpy();

  const out = await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    // dryRun omitted → defaults to true
    toolMap: TOOL_MAP,
    readLiveState: read,
    applyOp: apply,
    audit,
  });

  assert.equal(out.ok, true);
  assert.equal(out.dry_run, true);
  assert.equal(out.reason, OUTCOME.DRY_RUN_COMPLETE);
  assert.equal(out.results.length, cs.operations.length);
  for (const r of out.results) {
    assert.equal(r.status, STATUS.APPLIED);
    assert.equal(r.dry_run, true);
    assert.equal(r.detail.simulated, true);
    assert.ok('before' in r.detail.diff && 'after' in r.detail.diff);
  }
  // The default is dry-run: NO mutating tool was invoked.
  assert.equal(apply.calls.length, 0);
  // Live state was re-read for every op (drift detection runs in dry-run too).
  assert.equal(read.calls.length, cs.operations.length);
  // Every op was audited with dry_run stamped true.
  assert.equal(audit.calls.length, cs.operations.length);
  for (const [rec] of audit.calls) assert.equal(rec.dryRun, true);
});

test('the simulated diff carries raw integer milliunits verbatim (no float round-trip)', async () => {
  const cs = loadFixture('allocate.example.json'); // after.budgeted = 250000
  const out = await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    toolMap: TOOL_MAP,
    readLiveState: noDrift(),
    audit: auditSpy(),
  });
  const diff = out.results[0].detail.diff;
  assert.equal(diff.after.budgeted, 250000);
  assert.equal(Number.isInteger(diff.after.budgeted), true);
});

// --- (b) dry-run detecting drift on one op ---------------------------------

test('(b) dry-run flags the drifted op stale while clean ops simulate', async () => {
  const cs = loadFixture('combined.example.json');
  const driftId = cs.operations[1].id; // the allocate op
  const read = spy((op) => (op.id === driftId ? { budgeted: 999999 } : clone(op.before)));
  const apply = spy();
  const audit = auditSpy();

  const out = await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: true,
    toolMap: TOOL_MAP,
    readLiveState: read,
    applyOp: apply,
    audit,
  });

  assert.equal(out.ok, true);
  const byId = Object.fromEntries(out.results.map((r) => [r.op_id, r]));
  assert.equal(byId[driftId].status, STATUS.SKIPPED_STALE);
  assert.equal(byId[driftId].detail.reason, 'stale');
  for (const r of out.results) {
    if (r.op_id !== driftId) assert.equal(r.status, STATUS.APPLIED);
  }
  assert.equal(apply.calls.length, 0); // still dry-run: nothing mutated
});

// --- (c) real-apply: one stale skipped, one clean applied ------------------

test('(c) real apply skips the stale op individually and applies the clean one', async () => {
  const cs = loadFixture('combined.example.json');
  const staleId = cs.operations[2].id; // the delete_duplicate op
  const read = spy((op) => (op.id === staleId ? { amount: 1, date: 'moved' } : clone(op.before)));
  const apply = spy((toolName) => ({ ok: true, tool: toolName }));
  const audit = auditSpy();

  const out = await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: read,
    applyOp: apply,
    authPreflight: okPreflight(),
    audit,
  });

  assert.equal(out.ok, true);
  assert.equal(out.dry_run, false);
  assert.equal(out.reason, OUTCOME.APPLY_COMPLETE);

  const byId = Object.fromEntries(out.results.map((r) => [r.op_id, r]));
  assert.equal(byId[staleId].status, STATUS.SKIPPED_STALE);
  // Every NON-stale op applied for real.
  for (const r of out.results) {
    if (r.op_id !== staleId) {
      assert.equal(r.status, STATUS.APPLIED);
      assert.equal(r.dry_run, false);
    }
  }
  // applyOp was invoked for exactly the non-stale ops, never the stale one.
  assert.equal(apply.calls.length, cs.operations.length - 1);
  assert.ok(!apply.calls.some(([, op]) => op.id === staleId));
  // Every op (including the skipped one) left an audit record stamped dry_run=false.
  assert.equal(audit.calls.length, cs.operations.length);
  for (const [rec] of audit.calls) assert.equal(rec.dryRun, false);
});

test('an applyOp failure becomes a per-op error and the rest of the batch still applies', async () => {
  const cs = loadFixture('combined.example.json');
  const failId = cs.operations[0].id;
  const apply = spy((toolName, op) => {
    if (op.id === failId) throw new Error('YNAB 500');
    return { ok: true };
  });
  const out = await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: noDrift(),
    applyOp: apply,
    authPreflight: okPreflight(),
    audit: auditSpy(),
  });
  const byId = Object.fromEntries(out.results.map((r) => [r.op_id, r]));
  assert.equal(byId[failId].status, STATUS.ERROR);
  assert.equal(byId[failId].detail.message, 'YNAB 500');
  for (const r of out.results) {
    if (r.op_id !== failId) assert.equal(r.status, STATUS.APPLIED);
  }
});

// --- (d) guardrail block aborts the whole batch ----------------------------

test('(d) a guardrail block (wrong active budget) aborts the whole batch: nothing applies, nothing audits', async () => {
  // A schema-VALID change-set that targets a different budget than the one the human
  // approved against. The schema can't see the active budget (a runtime input), so it
  // passes — and the guardrail blocks fail-closed on the cross-budget mismatch. This
  // is the realistic guardrail-block path: transfer signals and the money_movement
  // flag are caught one layer earlier by the schema (additionalProperties:false / the
  // money_movement const), so a budget mismatch is how a well-formed envelope reaches
  // the guardrail's runtime layer.
  const cs = loadFixture('combined.example.json');
  const apply = spy();
  const audit = auditSpy();

  const out = await applyChangeset(cs, {
    activeBudgetId: 'a-different-active-budget',
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: noDrift(),
    applyOp: apply,
    authPreflight: okPreflight(),
    audit,
  });

  assert.equal(out.ok, false);
  assert.equal(out.aborted, true);
  assert.equal(out.reason, OUTCOME.GUARDRAIL_BLOCK);
  assert.equal(out.guardrail.verdict, 'block');
  // Every op result is blocked; nothing dispatched, nothing audited (batch aborted pre-loop).
  for (const r of out.results) assert.equal(r.status, STATUS.BLOCKED);
  assert.equal(apply.calls.length, 0);
  assert.equal(audit.calls.length, 0);
  // The offending ops carry their full guardrail verdict.
  const offender = out.results.find((r) => r.op_id === cs.operations[0].id);
  assert.equal(offender.detail.reason, 'guardrail_block');
  assert.ok(offender.detail.verdict.rule.length > 0);
});

test('an envelope money_movement !== false is rejected by the schema (const false, two-layer defense)', async () => {
  // money_movement is a schema `const false`, so true is UNREPRESENTABLE and the
  // validator rejects it before the guardrail ever runs — the structural half of
  // the M4 safety promise. (The guardrail's runtime half is exercised by the
  // transfer-smuggle test above, which passes the schema but blocks at apply.)
  const cs = loadFixture('categorize.example.json');
  cs.money_movement = true;
  const out = await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    readLiveState: noDrift(),
    audit: auditSpy(),
  });
  assert.equal(out.reason, OUTCOME.SCHEMA_INVALID);
  assert.equal(out.ok, false);
});

// --- (e) schema validation rejection before any MCP call -------------------

test('(e) a schema-invalid change-set is rejected before any port is touched', async () => {
  const cs = loadFixture('categorize.example.json');
  delete cs.operations[0].rationale; // schema requires rationale; the guardrail does not check it
  const read = noDrift();
  const apply = spy();
  const preflight = okPreflight();
  const audit = auditSpy();

  const out = await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: read,
    applyOp: apply,
    authPreflight: preflight,
    audit,
  });

  assert.equal(out.ok, false);
  assert.equal(out.reason, OUTCOME.SCHEMA_INVALID);
  assert.equal(out.validation.valid, false);
  assert.ok(out.validation.errors.length > 0);
  assert.deepEqual(out.results, []);
  // No port was called — not even the read or the auth preflight.
  assert.equal(read.calls.length, 0);
  assert.equal(apply.calls.length, 0);
  assert.equal(preflight.calls.length, 0);
  assert.equal(audit.calls.length, 0);
});

// --- registration point + namespaced enforcement ---------------------------

test('the op→tool mapping is supplied by the caller (registration point), not hard-coded', async () => {
  const cs = loadFixture('categorize.example.json');
  const apply = spy(() => ({ ok: true }));
  await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: noDrift(),
    applyOp: apply,
    authPreflight: okPreflight(),
    audit: auditSpy(),
  });
  // The exact tool the executor dispatched is the one the caller registered.
  assert.equal(apply.calls[0][0], TOOL_MAP.categorize);
});

test('real apply aborts the whole batch when a registered tool is denied / un-namespaced', async () => {
  const cs = loadFixture('categorize.example.json');
  const apply = spy();
  const out = await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    // a bare, un-namespaced create tool — not on the guardrail allow-list
    toolMap: { categorize: 'mcp__ynab__ynab_create_transaction' },
    readLiveState: noDrift(),
    applyOp: apply,
    authPreflight: okPreflight(),
    audit: auditSpy(),
  });
  assert.equal(out.ok, false);
  assert.equal(out.reason, OUTCOME.TOOL_BLOCK);
  assert.equal(apply.calls.length, 0); // pre-flight aborted before any dispatch
  assert.equal(out.results[0].status, STATUS.BLOCKED);
});

test('real apply blocks an op whose type has no registered tool (fail-closed)', async () => {
  const cs = loadFixture('categorize.example.json');
  const out = await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    toolMap: {}, // categorize unmapped → evaluateTool(undefined) blocks
    readLiveState: noDrift(),
    applyOp: spy(),
    authPreflight: okPreflight(),
    audit: auditSpy(),
  });
  assert.equal(out.reason, OUTCOME.TOOL_BLOCK);
});

test('dry-run does NOT require a tool mapping (no mutating dispatch happens)', async () => {
  const cs = loadFixture('categorize.example.json');
  const out = await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: true,
    toolMap: {}, // intentionally empty
    readLiveState: noDrift(),
    audit: auditSpy(),
  });
  assert.equal(out.ok, true);
  assert.equal(out.results[0].status, STATUS.APPLIED);
});

// --- audit record shape ----------------------------------------------------

test('each audit record mirrors the _audit_append contract (operation, result, dryRun)', async () => {
  const cs = loadFixture('categorize.example.json');
  const audit = auditSpy();
  await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: true,
    toolMap: TOOL_MAP,
    readLiveState: noDrift(),
    audit,
  });
  const [rec] = audit.calls[0];
  assert.deepEqual(rec.operation, cs.operations[0]);
  assert.equal(rec.result.tool, TOOL_MAP.categorize);
  assert.equal(rec.result.status, STATUS.APPLIED);
  assert.equal(rec.result.schema_version, cs.schema_version);
  assert.equal(rec.result.run_id, cs.source);
  assert.equal(rec.dryRun, true);
});

// --- result contract -------------------------------------------------------

test('every result entry matches the { op_id, status, dry_run, detail } contract', async () => {
  const cs = loadFixture('combined.example.json');
  const out = await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: true,
    toolMap: TOOL_MAP,
    readLiveState: noDrift(),
    audit: auditSpy(),
  });
  const allowed = new Set(Object.values(STATUS));
  for (const r of out.results) {
    assert.deepEqual(Object.keys(r).sort(), ['detail', 'dry_run', 'op_id', 'status']);
    assert.ok(allowed.has(r.status));
    assert.equal(typeof r.op_id, 'string');
    assert.equal(typeof r.dry_run, 'boolean');
  }
});

// --- port contract (fail fast on misconfiguration) -------------------------

test('a missing readLiveState or audit port throws; real apply also requires applyOp + authPreflight', async () => {
  const cs = loadFixture('categorize.example.json');
  await assert.rejects(
    () => applyChangeset(cs, { activeBudgetId: cs.budget_id, audit: auditSpy() }),
    /readLiveState/,
  );
  await assert.rejects(
    () => applyChangeset(cs, { activeBudgetId: cs.budget_id, readLiveState: noDrift() }),
    /audit/,
  );
  await assert.rejects(
    () => applyChangeset(cs, { activeBudgetId: cs.budget_id, dryRun: false, readLiveState: noDrift(), audit: auditSpy() }),
    /applyOp/,
  );
  // Real apply also fails closed without the mandatory auth preflight port.
  await assert.rejects(
    () => applyChangeset(cs, { activeBudgetId: cs.budget_id, dryRun: false, toolMap: TOOL_MAP, readLiveState: noDrift(), applyOp: spy(), audit: auditSpy() }),
    /authPreflight/,
  );
});

test('a missing or empty activeBudgetId throws (fail-closed, never a silent envelope fallback)', async () => {
  const cs = loadFixture('categorize.example.json');
  await assert.rejects(
    () => applyChangeset(cs, { dryRun: false, toolMap: TOOL_MAP, readLiveState: noDrift(), applyOp: spy(), audit: auditSpy() }),
    /activeBudgetId/,
  );
  await assert.rejects(
    () => applyChangeset(cs, { activeBudgetId: '', readLiveState: noDrift(), audit: auditSpy() }),
    /activeBudgetId/,
  );
});

// --- (#50) auth-failure handling on the write path -------------------------

const { describeAuthFailure } = require('../apply-executor');

/** applyOp that throws `err` for one op id and succeeds for the rest. */
const applyFailingOn = (failId, err) => spy((toolName, op) => {
  if (op.id === failId) throw err;
  return { ok: true };
});

/** readLiveState that throws `err` for one op id and echoes `before` (no drift) otherwise. */
const readFailingOn = (failId, err) => spy((op) => {
  if (op.id === failId) throw err;
  return clone(op.before);
});

test('preflight auth failure aborts before any mutation — zero ops, no audit records', async () => {
  const cs = loadFixture('combined.example.json');
  const apply = spy();
  const audit = auditSpy();

  const out = await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: noDrift(),
    applyOp: apply,
    authPreflight: spy(() => { throw httpError(401, 'token revoked'); }),
    audit,
  });

  assert.equal(out.ok, false);
  assert.equal(out.aborted, true);
  assert.equal(out.reason, OUTCOME.AUTH_PREFLIGHT_FAIL);
  assert.equal(out.authFailure.error_class, 'auth_revoked');
  assert.equal(out.authFailure.applied_state, 'not_applied');
  assert.equal(out.authFailure.phase, 'preflight');
  assert.deepEqual(out.results, []);
  // The mutation port was NEVER reached, and no op that never ran was audited.
  assert.equal(apply.calls.length, 0);
  assert.equal(audit.calls.length, 0);
});

test('preflight NETWORK failure (statusless) also aborts the whole batch', async () => {
  const cs = loadFixture('combined.example.json');
  const apply = spy();

  const out = await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: noDrift(),
    applyOp: apply,
    authPreflight: spy(() => { throw new Error('network timeout: socket hang up'); }),
    audit: auditSpy(),
  });

  assert.equal(out.reason, OUTCOME.AUTH_PREFLIGHT_FAIL);
  assert.equal(out.authFailure.error_class, 'unknown');
  assert.equal(out.authFailure.applied_state, 'unknown');
  assert.equal(apply.calls.length, 0);
});

test('mid-batch 401 stops the batch and audits the failed op (auth_revoked / not_applied)', async () => {
  const cs = loadFixture('combined.example.json');
  const failId = cs.operations[1].id; // fail on the SECOND op → the first still applies
  const apply = applyFailingOn(failId, httpError(401, 'unauthorized'));
  const audit = auditSpy();

  const out = await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: noDrift(),
    applyOp: apply,
    authPreflight: okPreflight(),
    audit,
  });

  assert.equal(out.ok, false);
  assert.equal(out.aborted, true);
  assert.equal(out.reason, OUTCOME.AUTH_ABORT);
  assert.equal(out.stopped_at_index, 1);
  assert.equal(out.total_ops, cs.operations.length);

  // Op 0 applied; op 1 errored (auth); op 2 was NEVER processed.
  assert.equal(out.results.length, 2);
  assert.equal(out.results[0].status, STATUS.APPLIED);
  assert.equal(out.results[1].status, STATUS.ERROR);
  assert.equal(out.results[1].detail.error_class, 'auth_revoked');
  assert.equal(out.results[1].detail.applied_state, 'not_applied');
  // The mutation was attempted for op 0 and op 1 only, never op 2 (fail-closed stop).
  assert.equal(apply.calls.length, 2);
  assert.ok(!apply.calls.some(([, op]) => op.id === cs.operations[2].id));

  // Exactly the two processed ops were audited; the failed op's record carries the class.
  assert.equal(audit.calls.length, 2);
  const failedRec = audit.calls[1][0];
  assert.equal(failedRec.result.status, STATUS.ERROR);
  assert.equal(failedRec.result.error_class, 'auth_revoked');
  assert.equal(failedRec.result.applied_state, 'not_applied');
});

test('mid-batch 403 stops the batch and records insufficient_scope (load-bearing: later ops never dispatched)', async () => {
  const cs = loadFixture('combined.example.json');
  const failId = cs.operations[1].id; // fail on the SECOND op → the first still applies, the third must NOT
  const apply = applyFailingOn(failId, httpError(403, 'not authorized (scope)'));
  const audit = auditSpy();

  const out = await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: noDrift(),
    applyOp: apply,
    authPreflight: okPreflight(),
    audit,
  });

  assert.equal(out.reason, OUTCOME.AUTH_ABORT);
  assert.equal(out.stopped_at_index, 1);
  assert.equal(out.results.length, 2);
  assert.equal(out.results[1].detail.error_class, 'insufficient_scope');
  assert.equal(out.results[1].detail.applied_state, 'not_applied');
  // Load-bearing (mirrors the 401 sibling): capture the spy and prove op 2's port was
  // NEVER called — remove `break dispatch` and this assertion fails directly, rather
  // than passing on post-hoc array lengths derived from `stopIndex`.
  assert.equal(apply.calls.length, 2);
  assert.ok(!apply.calls.some(([, op]) => op.id === cs.operations[2].id));
  assert.equal(audit.calls.length, 2);
});

test('mid-batch 401 on the READ phase also aborts the batch (phase-agnostic fail-closed)', async () => {
  const cs = loadFixture('combined.example.json');
  const failId = cs.operations[1].id; // fail the SECOND op's read → the first still applies
  const apply = spy(() => ({ ok: true }));
  const audit = auditSpy();

  const out = await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: readFailingOn(failId, httpError(401, 'unauthorized')),
    applyOp: apply,
    authPreflight: okPreflight(),
    audit,
  });

  // The abort check keys on error_class, NOT the phase — a 401 surfacing on the
  // re-read stops the batch just like one on the mutation (a dead token is caught
  // one op earlier). A regression scoping the abort to phase==='apply' fails here.
  assert.equal(out.ok, false);
  assert.equal(out.aborted, true);
  assert.equal(out.reason, OUTCOME.AUTH_ABORT);
  assert.equal(out.stopped_at_index, 1);
  assert.equal(out.authFailure.phase, 'read');
  assert.equal(out.authFailure.error_class, 'auth_revoked');
  assert.equal(out.authFailure.applied_state, 'not_applied');

  // Op 0 applied; op 1 errored on the READ; op 2 was NEVER processed.
  assert.equal(out.results.length, 2);
  assert.equal(out.results[0].status, STATUS.APPLIED);
  assert.equal(out.results[1].status, STATUS.ERROR);
  assert.equal(out.results[1].detail.phase, 'read');
  assert.equal(out.results[1].detail.error_class, 'auth_revoked');
  assert.equal(out.results[1].detail.applied_state, 'not_applied');

  // Op 1's read threw BEFORE its mutation, so applyOp ran for op 0 only — never op 1 or op 2.
  assert.equal(apply.calls.length, 1);
  assert.equal(apply.calls[0][1].id, cs.operations[0].id);

  // Both processed ops were audited (the failed op before the break); its record carries the class.
  assert.equal(audit.calls.length, 2);
  const failedRec = audit.calls[1][0];
  assert.equal(failedRec.result.status, STATUS.ERROR);
  assert.equal(failedRec.result.error_class, 'auth_revoked');
  assert.equal(failedRec.result.applied_state, 'not_applied');
});

test('a mixed read/dispatch auth interleaving audits BOTH failed ops — neither abort clobbers the other (#50 AC#4)', async () => {
  // The token dies MID-prepare: a LATER op's READ auth-fails during prepare (stops the
  // read pass at that higher index), and then an EARLIER survivor's MUTATION auth-fails
  // during dispatch (stops at a lower index). Both ops genuinely failed and must EACH be
  // audited — the earlier dispatch abort must not clobber the later read failure out of
  // the trail. Regression guard: the old truncate-to-a-single-stopIndex audit dropped the
  // read-failed op → results.length === 1 when two ops failed.
  const cs = loadFixture('combined.example.json');
  const readFailId = cs.operations[2].id; // op 2's READ auth-fails during prepare (higher index)
  const applyFailId = cs.operations[0].id; // op 0's MUTATION auth-fails during dispatch (lower index)
  const apply = applyFailingOn(applyFailId, httpError(401, 'unauthorized (mutation)'));
  const audit = auditSpy();

  const out = await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: readFailingOn(readFailId, httpError(403, 'insufficient scope (read)')),
    applyOp: apply,
    authPreflight: okPreflight(),
    audit,
  });

  assert.equal(out.reason, OUTCOME.AUTH_ABORT);
  // Primary stop is the dispatch abort (the lower index — where the mutation halted).
  assert.equal(out.stopped_at_index, 0);
  // BOTH failures are recorded — the dispatch-failed op 0 AND the read-failed op 2 (the
  // bug dropped op 2, returning length 1). The middle survivor (op 1) is NOT dispatched.
  assert.equal(out.results.length, 2);
  assert.equal(audit.calls.length, 2);
  const byId = Object.fromEntries(out.results.map((r) => [r.op_id, r]));
  assert.equal(byId[cs.operations[0].id].detail.phase, 'apply');
  assert.equal(byId[cs.operations[0].id].detail.error_class, 'auth_revoked');
  assert.equal(byId[cs.operations[2].id].detail.phase, 'read');
  assert.equal(byId[cs.operations[2].id].detail.error_class, 'insufficient_scope');
  // Op 1 (the un-run middle survivor) is neither returned nor audited.
  assert.ok(!(cs.operations[1].id in byId));
  const auditedIds = audit.calls.map(([rec]) => rec.operation.id).sort();
  assert.deepEqual(auditedIds, [cs.operations[0].id, cs.operations[2].id].sort());
});

test('a single-op 422 skips that op and CONTINUES the rest (data-error policy)', async () => {
  const cs = loadFixture('combined.example.json');
  const failId = cs.operations[1].id;
  const apply = applyFailingOn(failId, httpError(422, 'Unprocessable Entity'));
  const audit = auditSpy();

  const out = await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: noDrift(),
    applyOp: apply,
    authPreflight: okPreflight(),
    audit,
  });

  // NOT an abort — the whole batch is processed to completion.
  assert.equal(out.ok, true);
  assert.equal(out.reason, OUTCOME.APPLY_COMPLETE);
  const byId = Object.fromEntries(out.results.map((r) => [r.op_id, r]));
  assert.equal(byId[failId].status, STATUS.ERROR);
  assert.equal(byId[failId].detail.error_class, 'unknown'); // 422 is not an auth/rate class
  assert.equal(byId[failId].detail.applied_state, 'not_applied'); // but YNAB rejected it → no change
  for (const r of out.results) {
    if (r.op_id !== failId) assert.equal(r.status, STATUS.APPLIED);
  }
  // Every op was attempted and audited (the 422 didn't stop the batch).
  assert.equal(apply.calls.length, cs.operations.length);
  assert.equal(audit.calls.length, cs.operations.length);
});

test('a network timeout on a mutation records applied_state=unknown and continues', async () => {
  const cs = loadFixture('combined.example.json');
  const failId = cs.operations[1].id;
  const apply = applyFailingOn(failId, new Error('network timeout during mutation'));
  const audit = auditSpy();
  const out = await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: noDrift(),
    applyOp: apply,
    authPreflight: okPreflight(),
    audit,
  });

  assert.equal(out.reason, OUTCOME.APPLY_COMPLETE); // indeterminate ≠ auth → not an abort
  const failed = out.results.find((r) => r.op_id === failId);
  assert.equal(failed.status, STATUS.ERROR);
  assert.equal(failed.detail.applied_state, 'unknown'); // may have landed server-side
  assert.equal(failed.detail.error_class, 'unknown');
  // Continuation (mirrors the 422 test): every OTHER op still applied and the batch
  // ran to completion — apply + audit fired once per op — so a regression that
  // stopped the batch on an indeterminate error is caught directly here.
  for (const r of out.results) {
    if (r.op_id !== failId) assert.equal(r.status, STATUS.APPLIED);
  }
  assert.equal(apply.calls.length, cs.operations.length);
  assert.equal(audit.calls.length, cs.operations.length);
});

test('a normal applied op audits error_class=null and applied_state=null', async () => {
  const cs = loadFixture('categorize.example.json');
  const audit = auditSpy();
  await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: noDrift(),
    applyOp: spy(() => ({ ok: true })),
    authPreflight: okPreflight(),
    audit,
  });
  const [rec] = audit.calls[0];
  assert.equal(rec.result.status, STATUS.APPLIED);
  assert.equal(rec.result.error_class, null);
  assert.equal(rec.result.applied_state, null);
});

test('describeAuthFailure distinguishes "no changes" from "N of M applied, stopped at op K"', async () => {
  const cs = loadFixture('combined.example.json');

  // Mid-batch abort after op 0 applied → "1 of 3 applied, stopped at op 2".
  const mid = await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: noDrift(),
    applyOp: applyFailingOn(cs.operations[1].id, httpError(401)),
    authPreflight: okPreflight(),
    audit: auditSpy(),
  });
  const midMsg = describeAuthFailure(mid);
  assert.match(midMsg, /1 of \d+ op\(s\) applied, batch stopped at op 2/);
  assert.match(midMsg, /Applied before the failure: /);
  assert.match(midMsg, /re-issue token via \/workbench-ynab:setup/); // auth_revoked remediation

  // Preflight failure → "No changes applied." + the scope remediation.
  const pre = await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: noDrift(),
    applyOp: spy(),
    authPreflight: spy(() => { throw httpError(403); }),
    audit: auditSpy(),
  });
  const preMsg = describeAuthFailure(pre);
  assert.match(preMsg, /^No changes applied\./);
  assert.match(preMsg, /token requires write scope/);

  // A first-op mid-batch failure is also "No changes applied." (nothing applied yet).
  const first = await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: false,
    toolMap: TOOL_MAP,
    readLiveState: noDrift(),
    applyOp: applyFailingOn(cs.operations[0].id, httpError(401)),
    authPreflight: okPreflight(),
    audit: auditSpy(),
  });
  assert.match(describeAuthFailure(first), /^No changes applied\./);

  // A non-auth-failure outcome has no auth message.
  const clean = await applyChangeset(cs, {
    activeBudgetId: cs.budget_id,
    dryRun: true,
    toolMap: TOOL_MAP,
    readLiveState: noDrift(),
    audit: auditSpy(),
  });
  assert.equal(describeAuthFailure(clean), null);
});

// --- opt-in bulk dispatch (M4-6 Option 1) ----------------------------------

test('bulk dispatch: same-type survivors go through ONE bulkApplyOp call; each op is still drift-checked and audited', async () => {
  const cs = twoCategorize();
  const read = noDrift();
  const bulk = spy((_tool, ops) => bulkAllUpdated(ops)); // real, confirmed per-entry shape
  const apply = spy();
  const audit = auditSpy();
  const out = await applyChangeset(cs, bulkCtx({ readLiveState: read, bulkApplyOp: bulk, applyOp: apply, audit }));

  assert.equal(bulk.calls.length, 1); // exactly one bulk call for the group
  assert.equal(bulk.calls[0][0], BULK_TOOL);
  assert.equal(bulk.calls[0][1].length, 2); // the whole group of ops
  assert.equal(apply.calls.length, 0); // no per-op dispatch
  for (const r of out.results) {
    assert.equal(r.status, STATUS.APPLIED);
    assert.equal(r.detail.bulk, true);
    assert.equal(r.detail.tool, BULK_TOOL);
  }
  assert.equal(read.calls.length, 2); // drift-checked each op individually
  assert.equal(audit.calls.length, 2); // audited each op individually
  for (const [rec] of audit.calls) assert.equal(rec.result.tool, BULK_TOOL); // audit records the tool that ran
});

test('bulk dispatch falls back to per-op applyOp when bulkApplyOp throws (rejected bulk shape)', async () => {
  const cs = twoCategorize();
  const bulk = spy(() => { throw new Error('bulk shape rejected'); });
  const apply = spy(() => ({ ok: true }));
  const out = await applyChangeset(cs, bulkCtx({ bulkApplyOp: bulk, applyOp: apply }));

  assert.equal(bulk.calls.length, 1);
  assert.equal(apply.calls.length, 2); // fell back to a per-op call for each op in the group
  for (const r of out.results) assert.equal(r.status, STATUS.APPLIED);
});

test('bulk dispatch: a RESOLVED but partially-failed bulk envelope audits each failed entry as error, not applied', async () => {
  const cs = twoCategorize(); // op-1 → t-a, op-2 → t-b
  // The vendored ynab_update_transactions does NOT throw on a partial failure — it
  // RESOLVES with per-entry statuses. t-a updated; t-b failed.
  const bulk = spy(() => ({
    success: false,
    summary: { total_requested: 2, updated: 1, failed: 1 },
    results: [
      { request_index: 0, status: 'updated', transaction_id: 't-a', correlation_key: 'k0' },
      { request_index: 1, status: 'failed', transaction_id: 't-b', correlation_key: 'k1', error: 'insufficient scope' },
    ],
  }));
  const apply = spy(() => ({ ok: true }));
  const audit = auditSpy();
  const out = await applyChangeset(cs, bulkCtx({ bulkApplyOp: bulk, applyOp: apply, audit }));

  assert.equal(bulk.calls.length, 1); // one bulk call, no throw → no fallback
  assert.equal(apply.calls.length, 0);
  const byId = Object.fromEntries(out.results.map((r) => [r.op_id, r]));
  assert.equal(byId['op-1'].status, STATUS.APPLIED); // t-a updated
  assert.equal(byId['op-2'].status, STATUS.ERROR); // t-b failed — NOT applied
  assert.match(byId['op-2'].detail.message, /insufficient scope/);
  // AC #4: the failed entry carries an audit-grade class, NEVER null — a RESOLVED bulk
  // call means the HTTP request itself succeeded, so a per-entry failure is a data-level
  // rejection (unknown) that YNAB positively marked `failed` → not_applied.
  assert.equal(byId['op-2'].detail.error_class, 'unknown');
  assert.equal(byId['op-2'].detail.applied_state, 'not_applied');
  // The audit trail must NOT lie: the failed op is audited as error, not applied — and
  // its record carries the same non-null error_class / applied_state (never null/null).
  const auditByStatus = audit.calls.map(([rec]) => rec.result.status).sort();
  assert.deepEqual(auditByStatus, ['applied', 'error']);
  const failedAudit = audit.calls.map(([rec]) => rec.result).find((r) => r.status === STATUS.ERROR);
  assert.equal(failedAudit.error_class, 'unknown');
  assert.equal(failedAudit.applied_state, 'not_applied');
});

test('bulk dispatch fails CLOSED on a resolved-but-off-contract payload: no op is recorded applied', async () => {
  const cs = twoCategorize();
  // A resolved payload with NO `results` array (the exact fail-open repro): the tool
  // returned without throwing, but confirms nothing. Every op must be `error`, not applied.
  const bulk = spy(() => ({ ok: true }));
  const apply = spy(() => ({ ok: true }));
  const audit = auditSpy();
  const out = await applyChangeset(cs, bulkCtx({ bulkApplyOp: bulk, applyOp: apply, audit }));

  assert.equal(bulk.calls.length, 1);
  assert.equal(apply.calls.length, 0); // resolved (no throw) → no per-op fallback
  for (const r of out.results) {
    assert.equal(r.status, STATUS.ERROR); // fail-closed, never a blanket applied
    assert.match(r.detail.message, /without confirming this op/);
  }
  // The audit trail must NOT lie: an unconfirmed mutation is audited as error.
  for (const [rec] of audit.calls) assert.equal(rec.result.status, STATUS.ERROR);
});

test('bulk dispatch fails CLOSED when the results array omits an op entry (partial shape)', async () => {
  const cs = twoCategorize(); // op-1 → t-a, op-2 → t-b
  // Only op-1 has an entry; op-2 is missing from `results` → op-2 must be error, not applied.
  const bulk = spy(() => ({
    success: true,
    summary: { total_requested: 2, updated: 1, failed: 0 },
    results: [{ request_index: 0, status: 'updated', transaction_id: 't-a', correlation_key: 'k0' }],
  }));
  const out = await applyChangeset(cs, bulkCtx({ bulkApplyOp: bulk }));
  const byId = Object.fromEntries(out.results.map((r) => [r.op_id, r]));
  assert.equal(byId['op-1'].status, STATUS.ERROR); // length mismatch fails the whole group closed
  assert.equal(byId['op-2'].status, STATUS.ERROR);
});

test('a stale op is excluded from a ≥2-survivor bulk call — the survivors still go through ONE bulk dispatch', async () => {
  const cs = threeCategorize(); // op-1 (t-a), op-2 (t-b), op-3 (t-c)
  // op-2 drifted; op-1 + op-3 survive → 2 survivors, bulkFits=true → ONE bulk call for both.
  const read = spy((op) => (op.id === 'op-2' ? { category_id: 'moved', category_name: 'x' } : clone(op.before)));
  const bulk = spy((_tool, ops) => bulkAllUpdated(ops));
  const apply = spy();
  const out = await applyChangeset(cs, bulkCtx({ readLiveState: read, bulkApplyOp: bulk, applyOp: apply }));

  const byId = Object.fromEntries(out.results.map((r) => [r.op_id, r]));
  assert.equal(byId['op-2'].status, STATUS.SKIPPED_STALE);
  assert.equal(byId['op-1'].status, STATUS.APPLIED);
  assert.equal(byId['op-3'].status, STATUS.APPLIED);
  assert.equal(bulk.calls.length, 1); // exactly ONE bulk call
  assert.equal(bulk.calls[0][1].length, 2); // carrying only the 2 survivors
  assert.deepEqual(bulk.calls[0][1].map((o) => o.id).sort(), ['op-1', 'op-3']);
  assert.equal(apply.calls.length, 0); // the survivors went bulk, not per-op
});

test('bulkFits=false keeps the group on the per-op path (no bulk call)', async () => {
  const cs = twoCategorize();
  const bulk = spy(() => ({ ok: true }));
  const apply = spy(() => ({ ok: true }));
  await applyChangeset(cs, bulkCtx({ bulkFits: () => false, bulkApplyOp: bulk, applyOp: apply }));

  assert.equal(bulk.calls.length, 0);
  assert.equal(apply.calls.length, 2);
});

test('a stale op in a bulk group is skipped; only the survivors are bulk-dispatched', async () => {
  const cs = twoCategorize();
  // op-2 drifted from its `before`; only op-1 survives → 1 survivor, bulkFits=false → per-op.
  const read = spy((op) => (op.id === 'op-2' ? { category_id: 'moved', category_name: 'x' } : clone(op.before)));
  const bulk = spy(() => ({ ok: true }));
  const apply = spy(() => ({ ok: true }));
  const out = await applyChangeset(cs, bulkCtx({ readLiveState: read, bulkApplyOp: bulk, applyOp: apply }));

  const byId = Object.fromEntries(out.results.map((r) => [r.op_id, r]));
  assert.equal(byId['op-2'].status, STATUS.SKIPPED_STALE);
  assert.equal(byId['op-1'].status, STATUS.APPLIED);
  // One survivor doesn't fit bulk → per-op; the stale op is never dispatched at all.
  assert.equal(bulk.calls.length, 0);
  assert.equal(apply.calls.length, 1);
});

test('a denied / un-namespaced bulk tool aborts the whole batch in pre-flight (tool_block, before any dispatch)', async () => {
  const cs = twoCategorize();
  const bulk = spy();
  const apply = spy();
  const out = await applyChangeset(cs, bulkCtx({
    bulkToolMap: { categorize: 'mcp__ynab__ynab_create_transactions' }, // bare, off the allow-list
    bulkApplyOp: bulk,
    applyOp: apply,
  }));
  assert.equal(out.ok, false);
  assert.equal(out.reason, OUTCOME.TOOL_BLOCK);
  assert.equal(bulk.calls.length, 0);
  assert.equal(apply.calls.length, 0);
});

test('dry-run ignores the bulk config entirely — every op is simulated, no bulk/per-op dispatch', async () => {
  const cs = twoCategorize();
  const bulk = spy();
  const apply = spy();
  const out = await applyChangeset(cs, bulkCtx({ dryRun: true, bulkApplyOp: bulk, applyOp: apply }));
  assert.equal(bulk.calls.length, 0);
  assert.equal(apply.calls.length, 0);
  for (const r of out.results) {
    assert.equal(r.status, STATUS.APPLIED);
    assert.equal(r.detail.simulated, true);
  }
});
