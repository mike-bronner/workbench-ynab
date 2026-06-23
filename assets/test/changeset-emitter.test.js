'use strict';

/**
 * Unit tests for the M4-10 change-set proposal emitter.
 *
 * Run with Node's built-in test runner (the M1 node:test harness). The emitter
 * composes the change-set validator (Ajv) and the M4-2 guardrail, so install the
 * assets deps first:
 *   npm --prefix assets install
 *   npm --prefix assets test          # node --test
 *
 * Every test feeds SYNTHETIC findings (ids already resolved, as the read-only
 * review would resolve them) through the emission pipeline with a SPY writer —
 * never a real YNAB API and never the real filesystem. The happy path uses the
 * REAL M4-2 guardrail (integration); the drop / all-blocked branches inject a
 * stub guardrail so they can be exercised in isolation. Tool/op shapes are
 * asserted against the real schema validator, so the test proves the emitted
 * JSON is a valid M4-1 change-set, not just structurally plausible.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const {
  emitProposal, assembleChangeset, mapFindingsToOperations, proposalFilename, OUTCOME, SCHEMA_VERSION,
} = require('../changeset-emitter');
const { validateChangeset } = require('../validate-changeset');

const EMITTER_CLI = path.join(__dirname, '..', 'changeset-emitter.js');

/** Synthetic review findings — every op type, with ids the review already resolved. */
function sampleFindings() {
  return {
    meta: { note: 'the lib ignores meta; it reads only the four buckets' },
    categorize: [{
      transaction_id: 'txn-groc-1',
      before: { category_id: null, category_name: null },
      after: { category_id: 'cat-groceries', category_name: 'Groceries' },
      rationale: 'Whole Foods purchase → Groceries (personal; not Schedule C deductible).',
    }],
    allocate: [{
      category_id: 'cat-groceries',
      month: '2026-06-01',
      before: { budgeted: 0 },
      after: { budgeted: 250000 },
      rationale: 'Fund Groceries to its $250.00 monthly target from the Ready-to-Assign surplus.',
    }],
    delete_duplicate: [{
      transaction_id: 'txn-dup-2',
      before: { amount: -54990, date: '2026-06-12', payee_name: 'Amazon', category_name: 'Shopping', import_id: 'YNAB:-54990:2026-06-12:1' },
      rationale: 'Exact duplicate of txn-orig-1 (same amount, date, import_id); safe to remove.',
    }],
    reconcile: [{
      account_id: 'acct-checking',
      transaction_ids: ['txn-r1', 'txn-r2'],
      before: { cleared_balance: 1200000, reconciled_balance: 1145010, cleared: 'cleared' },
      after: { reconciled_balance: 1200000, cleared: 'reconciled' },
      rationale: 'Bank statement matches the cleared balance of $1,200.00; reconcile checking.',
    }],
  };
}

const META = {
  budgetId: 'budget-xyz',
  budgetName: 'Family Budget',
  source: 'review-2026-06-19T14-00-00Z',
  generatedAt: '2026-06-19T14:30:00Z',
  schemaVersion: SCHEMA_VERSION,
  outDir: '/tmp/proposals',
  date: '2026-06-19',
};

/** A writeFile spy that records (path, contents) and writes nothing. */
function writerSpy() {
  const calls = [];
  const fn = async (absPath, contents) => { calls.push({ absPath, contents }); };
  fn.calls = calls;
  return fn;
}

// --- happy path: real guardrail, every op type emitted -----------------------

test('emits a schema-valid proposal of every op type, ids resolved, via the real guardrail', async () => {
  const writeFile = writerSpy();
  const result = await emitProposal(sampleFindings(), { ...META, writeFile });

  assert.equal(result.written, true);
  assert.equal(result.reason, OUTCOME.WRITTEN);
  assert.deepEqual(result.dropped, []); // the real guardrail passes every clean op
  assert.equal(writeFile.calls.length, 1);
  assert.equal(result.path, path.join(META.outDir, 'changeset-2026-06-19.json'));

  // The written bytes round-trip to a VALID M4-1 change-set.
  const written = JSON.parse(writeFile.calls[0].contents);
  assert.equal(writeFile.calls[0].absPath, result.path);
  assert.equal(validateChangeset(written).valid, true);

  // Envelope provenance + the money invariant.
  assert.equal(written.schema_version, SCHEMA_VERSION);
  assert.equal(written.budget_id, META.budgetId);
  assert.equal(written.budget_name, META.budgetName);
  assert.equal(written.source, META.source);
  assert.equal(written.money_movement, false);

  // Operations are emitted in schema order with the resolved ids carried through.
  assert.deepEqual(written.operations.map((o) => o.type), ['categorize', 'allocate', 'delete_duplicate', 'reconcile']);
  const [cat, alloc, del, rec] = written.operations;
  assert.equal(cat.transaction_id, 'txn-groc-1');
  assert.equal(cat.after.category_id, 'cat-groceries');
  assert.equal(cat.before.category_id, null);
  assert.equal(alloc.category_id, 'cat-groceries');
  assert.equal(alloc.month, '2026-06-01');
  assert.equal(del.transaction_id, 'txn-dup-2');
  assert.equal(rec.account_id, 'acct-checking');
  assert.deepEqual(rec.transaction_ids, ['txn-r1', 'txn-r2']);

  // Every op targets the envelope budget and carries a non-empty stable id.
  for (const op of written.operations) {
    assert.equal(op.budget_id, META.budgetId);
    assert.equal(typeof op.id, 'string');
    assert.ok(op.id.length > 0);
  }
});

test('delete_duplicate is forced destructive with after { deleted: true }, never taken from the finding', async () => {
  const findings = sampleFindings();
  findings.delete_duplicate[0].risk = 'low'; // a finding that lies about risk…
  const writeFile = writerSpy();
  const result = await emitProposal(findings, { ...META, writeFile });
  const del = result.changeset.operations.find((o) => o.type === 'delete_duplicate');
  assert.equal(del.risk, 'destructive'); // …is overridden to the schema const.
  assert.deepEqual(del.after, { deleted: true });
});

test('monetary fields pass through verbatim as integer milliunits (no float round-trip)', async () => {
  const writeFile = writerSpy();
  await emitProposal(sampleFindings(), { ...META, writeFile });
  const written = JSON.parse(writeFile.calls[0].contents);
  const alloc = written.operations.find((o) => o.type === 'allocate');
  assert.equal(alloc.after.budgeted, 250000);
  assert.equal(Number.isInteger(alloc.after.budgeted), true);
  const del = written.operations.find((o) => o.type === 'delete_duplicate');
  assert.equal(del.before.amount, -54990);
});

test('operation ids are deterministic per type (op-<kebab-type>-NNNN) and finding ids win when supplied', () => {
  const ops = mapFindingsToOperations({
    categorize: [{ transaction_id: 't1', after: { category_id: 'c1' }, rationale: 'r' }, { id: 'custom-id', transaction_id: 't2', after: { category_id: 'c2' }, rationale: 'r' }],
    delete_duplicate: [{ transaction_id: 't3', before: { amount: -1, date: '2026-06-01' }, rationale: 'r' }],
  }, 'budget-xyz');
  assert.equal(ops[0].id, 'op-categorize-0001');
  assert.equal(ops[1].id, 'custom-id');
  assert.equal(ops[2].id, 'op-delete-duplicate-0001');
});

// --- empty / reject paths: NO file is written --------------------------------

test('no findings → no operations → no proposal written (the writer is never called)', async () => {
  const writeFile = writerSpy();
  const result = await emitProposal({}, { ...META, writeFile });
  assert.equal(result.written, false);
  assert.equal(result.reason, OUTCOME.NO_OPERATIONS);
  assert.equal(writeFile.calls.length, 0);
  assert.ok(result.notes.length > 0);
});

test('a schema-invalid assembled change-set (missing rationale) is rejected before any write', async () => {
  const findings = sampleFindings();
  delete findings.categorize[0].rationale; // schema requires a rationale
  const writeFile = writerSpy();
  const result = await emitProposal(findings, { ...META, writeFile });
  assert.equal(result.written, false);
  assert.equal(result.reason, OUTCOME.SCHEMA_INVALID);
  assert.equal(result.validation.valid, false);
  assert.ok(result.validation.errors.length > 0);
  assert.equal(writeFile.calls.length, 0);
});

test('every written proposal asserts money_movement false (the §4 invariant holds on success)', async () => {
  const writeFile = writerSpy();
  const result = await emitProposal(sampleFindings(), { ...META, writeFile });
  // money_movement is hard-set false and re-asserted; the schema `const false`
  // makes the non-false branch unreachable by construction, so it is kept as
  // defense-in-depth (AC item 8 / contract §4) rather than separately reachable.
  assert.equal(result.changeset.money_movement, false);
});

// --- guardrail check-only: drop blocked ops, keep the rest -------------------

test('an op the guardrail blocks is dropped (with a note) while the rest are written', async () => {
  const findings = sampleFindings();
  const writeFile = writerSpy();
  // Stub guardrail: block exactly the delete_duplicate op, pass everything else.
  const evaluateOperation = (op) => (op.type === 'delete_duplicate'
    ? { verdict: 'block', op_id: op.id, op_type: op.type, rule: 'denied_for_test', reason: 'blocked by the test stub' }
    : { verdict: 'pass' });

  const result = await emitProposal(findings, { ...META, writeFile, evaluateOperation });
  assert.equal(result.written, true);
  assert.equal(result.dropped.length, 1);
  assert.equal(result.dropped[0].op_type, 'delete_duplicate');
  assert.equal(result.dropped[0].rule, 'denied_for_test');
  assert.ok(result.notes.some((n) => n.includes('Dropped operation') && n.includes('delete_duplicate')));

  // The written change-set carries only the surviving ops — no delete_duplicate.
  const written = JSON.parse(writeFile.calls[0].contents);
  assert.deepEqual(written.operations.map((o) => o.type), ['categorize', 'allocate', 'reconcile']);
  assert.equal(validateChangeset(written).valid, true);
});

test('all operations blocked → no proposal written, the outcome is logged', async () => {
  const writeFile = writerSpy();
  const evaluateOperation = (op) => ({ verdict: 'block', op_id: op.id, op_type: op.type, rule: 'denied_for_test', reason: 'all blocked' });
  const result = await emitProposal(sampleFindings(), { ...META, writeFile, evaluateOperation });
  assert.equal(result.written, false);
  assert.equal(result.reason, OUTCOME.ALL_BLOCKED);
  assert.equal(result.dropped.length, 4);
  assert.equal(writeFile.calls.length, 0);
  assert.ok(result.notes.some((n) => n.includes('Every proposed operation was blocked')));
});

// --- path derivation + port contract -----------------------------------------

test('the proposal filename is derived from the date as changeset-YYYY-MM-DD.json', () => {
  assert.equal(proposalFilename('2026-06-19'), 'changeset-2026-06-19.json');
  assert.throws(() => proposalFilename('2026/06/19'), /YYYY-MM-DD/);
  assert.throws(() => proposalFilename(undefined), /YYYY-MM-DD/);
});

test('assembleChangeset hard-sets money_movement false and defaults the schema version', () => {
  const cs = assembleChangeset(sampleFindings(), { budgetId: 'b', budgetName: 'n', source: 's' });
  assert.equal(cs.money_movement, false);
  assert.equal(cs.schema_version, SCHEMA_VERSION);
  assert.equal(cs.operations.length, 4);
});

test('a missing writeFile, an empty outDir, or a bad date throws (fail-fast on misconfiguration)', async () => {
  await assert.rejects(() => emitProposal(sampleFindings(), { ...META, writeFile: undefined }), /writeFile/);
  await assert.rejects(() => emitProposal(sampleFindings(), { ...META, outDir: '', writeFile: writerSpy() }), /outDir/);
  await assert.rejects(() => emitProposal(sampleFindings(), { ...META, date: 'nope', writeFile: writerSpy() }), /YYYY-MM-DD/);
});

// --- CLI: real fs write, exit codes ------------------------------------------

test('CLI writes a real proposal file to the out-dir and exits 0', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'emitter-cli-'));
  const findingsPath = path.join(dir, 'findings.json');
  const outDir = path.join(dir, 'proposals');
  fs.writeFileSync(findingsPath, JSON.stringify({
    meta: { budget_id: 'budget-xyz', budget_name: 'Family Budget', source: 'review-run' },
    categorize: [{ transaction_id: 't1', before: { category_id: null }, after: { category_id: 'c1', category_name: 'Groceries' }, rationale: 'matches Groceries' }],
  }));

  const stdout = execFileSync('node', [EMITTER_CLI, '--findings', findingsPath, '--out-dir', outDir, '--date', '2026-06-19'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  const result = JSON.parse(stdout);
  assert.equal(result.written, true);

  const proposalPath = path.join(outDir, 'changeset-2026-06-19.json');
  assert.ok(fs.existsSync(proposalPath));
  assert.equal(validateChangeset(JSON.parse(fs.readFileSync(proposalPath, 'utf8'))).valid, true);
});

test('CLI exits 1 when no proposal is written (no findings), and 2 on a usage error', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'emitter-cli-'));
  const findingsPath = path.join(dir, 'empty.json');
  fs.writeFileSync(findingsPath, JSON.stringify({ meta: { budget_id: 'b', budget_name: 'n', source: 's' } }));

  assert.throws(
    () => execFileSync('node', [EMITTER_CLI, '--findings', findingsPath, '--out-dir', path.join(dir, 'p'), '--date', '2026-06-19'], { stdio: 'pipe' }),
    (err) => err.status === 1,
  );
  assert.throws(
    () => execFileSync('node', [EMITTER_CLI, '--findings', findingsPath], { stdio: 'pipe' }),
    (err) => err.status === 2,
  );
});
