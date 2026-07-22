// tests/unit/monitor-state.test.mjs — unit tests for the monitor state store
// (lib/monitor/state.mjs, issue #79 / M6-1).
//
// Runs under the built-in node:test runner with NO node_modules present (only
// node: built-ins and repo-local files are imported), per docs/testing.md. The
// store resolves its path from a documented seam, so these tests point it at a
// temp file via the `statePath` option — never the user's real data dir.
//
// Covers the AC test matrix: (a) first run with no state file creates
// monitor-state.json with all required top-level fields; (b) a second run reads
// and updates the file without duplicating fields; (c) a no-op pass produces no
// output and correctly advances lastPollTimestamp — plus serverKnowledge cursor
// persistence, the firedAlerts skip-existing dedupe seam, milliunit storage, and
// the stdout discipline.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

import {
  defaultState,
  resolveStatePath,
  readState,
  computeNextState,
  recordFiredAlert,
  expireFiredAlerts,
  writeState,
  milliunitsToDollars,
} from '../../lib/monitor/state.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const MODULE_PATH = join(ROOT, 'lib', 'monitor', 'state.mjs');

const TMP = mkdtempSync(join(tmpdir(), 'ynab-monitor-'));
let seq = 0;
const freshPath = () => join(TMP, `monitor-state-${seq++}.json`);

const REQUIRED_FIELDS = ['lastPollTimestamp', 'accounts', 'serverKnowledge', 'firedAlerts'];

// --- (a) first run with no state file --------------------------------------

test('(a) first run: absent file → existed:false and the default shape', () => {
  const statePath = freshPath();
  const { state, existed } = readState({ statePath, dataDir: TMP });
  assert.equal(existed, false);
  assert.deepEqual(Object.keys(state).sort(), [...REQUIRED_FIELDS].sort());
  assert.equal(state.lastPollTimestamp, null);
  assert.deepEqual(state.accounts, {});
  assert.equal(state.serverKnowledge, null);
  assert.deepEqual(state.firedAlerts, {});
});

test('(a) first run: writeState creates the file with every required top-level field', () => {
  const statePath = freshPath();
  const { state } = readState({ statePath, dataDir: TMP });
  const obs = {
    timestamp: '2026-06-21T08:00:00Z',
    accounts: { 'acct-1': { cleared: 150000, uncleared: -2500 } },
    serverKnowledge: 42,
    recentTransactionCount: 3,
  };
  const { state: next } = computeNextState(state, obs);
  const written = writeState(next, { statePath, dataDir: TMP });

  assert.equal(written, statePath);
  assert.ok(existsSync(statePath), 'monitor-state.json was created');
  const onDisk = JSON.parse(readFileSync(statePath, 'utf8'));
  for (const f of REQUIRED_FIELDS) {
    assert.ok(Object.prototype.hasOwnProperty.call(onDisk, f), `missing required field: ${f}`);
  }
  assert.equal(onDisk.lastPollTimestamp, '2026-06-21T08:00:00Z');
  assert.deepEqual(onDisk.accounts['acct-1'], { cleared: 150000, uncleared: -2500 });
  assert.equal(onDisk.serverKnowledge, 42);
});

test('readState heals forward on a corrupt file: unparseable → existed:false + default shape', () => {
  // A truncated / garbage state file must not crash an unattended pass. readState
  // treats it as a first run (existed:false, default shape), so the next writeState
  // rewrites a clean file rather than the poll throwing on a JSON.parse.
  const statePath = freshPath();
  writeFileSync(statePath, '{ this is not valid json', 'utf8');
  const { state, existed } = readState({ statePath, dataDir: TMP });
  assert.equal(existed, false, 'a corrupt file heals forward as a first run');
  assert.deepEqual(state, defaultState(), 'corrupt file yields the default shape, not a throw');
  for (const f of REQUIRED_FIELDS) {
    assert.ok(Object.prototype.hasOwnProperty.call(state, f), `healed state missing required field: ${f}`);
  }
});

test('readState normalizes a valid-JSON-but-partial/legacy file to the full required shape', () => {
  // Heal-forward is tested for absent + totally-unparseable files; this covers
  // the per-field coercion in between — a parseable file missing keys (or with a
  // wrong-typed one) must come back as existed:true with EXACTLY the required
  // fields, so a second run updates in place instead of duplicating/orphaning
  // (AC #15b). A legacy stringified cursor coerces back to the null default.
  const statePath = freshPath();
  writeFileSync(statePath, JSON.stringify({ serverKnowledge: '7', accounts: { 'acct-1': { cleared: 5, uncleared: 0 } } }), 'utf8');
  const { state, existed } = readState({ statePath, dataDir: TMP });
  assert.equal(existed, true, 'a valid partial file is a real prior run, not a first run');
  assert.deepEqual(Object.keys(state).sort(), [...REQUIRED_FIELDS].sort(), 'normalized to exactly the required fields');
  assert.equal(state.lastPollTimestamp, null, 'missing field falls back to default');
  assert.deepEqual(state.accounts, { 'acct-1': { cleared: 5, uncleared: 0 } }, 'present field is preserved');
  assert.equal(state.serverKnowledge, null, 'a non-integer (legacy string) cursor coerces to the null default');
  assert.deepEqual(state.firedAlerts, {}, 'missing ledger falls back to the empty default');
});

// --- (b) second run reads + updates without duplicating fields --------------

test('(b) second run: reads existing state, updates in place, no duplicated fields', () => {
  const statePath = freshPath();
  // First pass.
  writeState(
    computeNextState(readState({ statePath, dataDir: TMP }).state, {
      timestamp: '2026-06-20T08:00:00Z',
      accounts: { 'acct-1': { cleared: 100000, uncleared: 0 } },
      serverKnowledge: 10,
      recentTransactionCount: 1,
    }).state,
    { statePath, dataDir: TMP },
  );

  // Second pass — balances move, new cursor, new transactions.
  const { state: prior, existed } = readState({ statePath, dataDir: TMP });
  assert.equal(existed, true);
  const { state: next, changed } = computeNextState(prior, {
    timestamp: '2026-06-21T08:00:00Z',
    accounts: { 'acct-1': { cleared: 125000, uncleared: -500 } },
    serverKnowledge: 23,
    recentTransactionCount: 2,
  });
  assert.equal(changed, true);
  writeState(next, { statePath, dataDir: TMP });

  const onDisk = JSON.parse(readFileSync(statePath, 'utf8'));
  // Exactly the required keys — no field was duplicated or orphaned.
  assert.deepEqual(Object.keys(onDisk).sort(), [...REQUIRED_FIELDS].sort());
  assert.equal(onDisk.lastPollTimestamp, '2026-06-21T08:00:00Z');
  assert.equal(onDisk.accounts['acct-1'].cleared, 125000);
  assert.equal(onDisk.serverKnowledge, 23);
});

test('(b) firedAlerts ledger survives a state update untouched (scaffold fires nothing)', () => {
  const statePath = freshPath();
  const seeded = { ...defaultState(), firedAlerts: { 'overdrawn:acct-1': { at: '2026-06-19T00:00:00Z' } } };
  writeState(seeded, { statePath, dataDir: TMP });

  const { state: prior } = readState({ statePath, dataDir: TMP });
  const { state: next } = computeNextState(prior, {
    timestamp: '2026-06-21T08:00:00Z',
    accounts: { 'acct-1': { cleared: 1, uncleared: 0 } },
    recentTransactionCount: 0,
  });
  writeState(next, { statePath, dataDir: TMP });

  const onDisk = JSON.parse(readFileSync(statePath, 'utf8'));
  assert.deepEqual(onDisk.firedAlerts, { 'overdrawn:acct-1': { at: '2026-06-19T00:00:00Z' } });
});

// --- (c) a no-op pass: no output, but lastPollTimestamp advances ------------

test('(c) no-op pass: balances unchanged + no new transactions → changed:false', () => {
  const accounts = { 'acct-1': { cleared: 100000, uncleared: -500 } };
  const prior = { ...defaultState(), lastPollTimestamp: '2026-06-20T08:00:00Z', accounts };
  const { changed, state: next } = computeNextState(prior, {
    timestamp: '2026-06-21T08:00:00Z',
    accounts: { 'acct-1': { cleared: 100000, uncleared: -500 } },
    recentTransactionCount: 0,
  });
  assert.equal(changed, false, 'a no-op pass must not report a change');
  // ...yet the timestamp still advances and is persisted.
  assert.equal(next.lastPollTimestamp, '2026-06-21T08:00:00Z');
});

test('(c) no-op pass: lastPollTimestamp advances on disk', () => {
  const statePath = freshPath();
  const accounts = { 'acct-1': { cleared: 100000, uncleared: -500 } };
  writeState({ ...defaultState(), lastPollTimestamp: '2026-06-20T08:00:00Z', accounts }, { statePath, dataDir: TMP });

  const { state: prior } = readState({ statePath, dataDir: TMP });
  const { state: next, changed } = computeNextState(prior, {
    timestamp: '2026-06-21T08:00:00Z',
    accounts,
    recentTransactionCount: 0,
  });
  assert.equal(changed, false);
  writeState(next, { statePath, dataDir: TMP });

  assert.equal(JSON.parse(readFileSync(statePath, 'utf8')).lastPollTimestamp, '2026-06-21T08:00:00Z');
});

// The two no-op assertions above only cover inputs where BOTH sub-conditions of
// `changed = !balancesEqual(...) || recentTransactionCount > 0` agree. These
// isolate each OR-branch so a `||`→`&&` regression — which would silence the
// monitor on a balance move with no new txns (or vice-versa) — is caught.

test('changed: balances differ with ZERO new transactions → changed:true (balance branch)', () => {
  const prior = { ...defaultState(), accounts: { 'acct-1': { cleared: 100000, uncleared: 0 } } };
  const { changed } = computeNextState(prior, {
    timestamp: '2026-06-21T08:00:00Z',
    accounts: { 'acct-1': { cleared: 125000, uncleared: 0 } }, // balance moved
    recentTransactionCount: 0, // ...but no new transactions in the window
  });
  assert.equal(changed, true, 'a balance change alone must report changed');
});

test('changed: identical balances with NEW transactions → changed:true (transaction branch)', () => {
  const accounts = { 'acct-1': { cleared: 100000, uncleared: 0 } };
  const { changed } = computeNextState({ ...defaultState(), accounts }, {
    timestamp: '2026-06-21T08:00:00Z',
    accounts, // balances unchanged
    recentTransactionCount: 4, // ...but new transactions arrived
  });
  assert.equal(changed, true, 'new transactions alone must report changed');
});

// --- serverKnowledge cursor persistence -------------------------------------

test('serverKnowledge: a returned cursor is persisted; absence keeps the prior cursor', () => {
  const prior = { ...defaultState(), serverKnowledge: 7 };
  // Delta returned a fresh cursor → persisted.
  assert.equal(computeNextState(prior, { timestamp: 't', accounts: {}, serverKnowledge: 99 }).state.serverKnowledge, 99);
  // Since-timestamp fallback (no cursor) → prior cursor stands.
  assert.equal(computeNextState(prior, { timestamp: 't', accounts: {} }).state.serverKnowledge, 7);
  assert.equal(computeNextState(prior, { timestamp: 't', accounts: {}, serverKnowledge: null }).state.serverKnowledge, 7);
});

// --- firedAlerts skip-existing dedupe seam (AC #10) -------------------------

test('recordFiredAlert: a new key is recorded; an existing key is skipped, never overwritten', () => {
  const s0 = defaultState();
  const { state: s1, recorded: r1 } = recordFiredAlert(s0, 'overdrawn:acct-1', { at: 'first' });
  assert.equal(r1, true);
  assert.deepEqual(s1.firedAlerts, { 'overdrawn:acct-1': { at: 'first' } });

  const { state: s2, recorded: r2 } = recordFiredAlert(s1, 'overdrawn:acct-1', { at: 'second' });
  assert.equal(r2, false, 'an existing condition key must be skipped');
  assert.deepEqual(s2.firedAlerts['overdrawn:acct-1'], { at: 'first' }, 'the original payload is preserved');
  assert.equal(s0.firedAlerts['overdrawn:acct-1'], undefined, 'inputs are never mutated');
});

// --- firedAlerts expiry seam (M6-3 AC: a cleared condition re-alerts) --------

test('expireFiredAlerts: a key absent from keepKeys is dropped; an active key is kept', () => {
  const s0 = { ...defaultState(), firedAlerts: { 'overdrawn:a1': { at: 'old' }, 'overdrawn:a2': { at: 'old' } } };
  const { state: s1, expired } = expireFiredAlerts(s0, new Set(['overdrawn:a1']));
  assert.deepEqual(s1.firedAlerts, { 'overdrawn:a1': { at: 'old' } }, 'the still-active key survives, the cleared one is dropped');
  assert.deepEqual(expired, ['overdrawn:a2'], 'the dropped key is reported');
  assert.deepEqual(s0.firedAlerts, { 'overdrawn:a1': { at: 'old' }, 'overdrawn:a2': { at: 'old' } }, 'input is never mutated');
});

test('expireFiredAlerts: a type OUTSIDE options.types is preserved even when not active', () => {
  // The type gate is what keeps point-event large_txn keys alive: they name a
  // transaction the incremental window can't re-attest, so they must NOT expire
  // just because they are absent from this pass's active set.
  const s0 = { ...defaultState(), firedAlerts: { 'overdrawn:a1': 1, 'large_txn:t1': 1 } };
  const { state, expired } = expireFiredAlerts(s0, new Set(), { types: ['overdrawn'] });
  assert.deepEqual(state.firedAlerts, { 'large_txn:t1': 1 }, 'only the eligible-type cleared key is dropped');
  assert.deepEqual(expired, ['overdrawn:a1']);
});

test('expireFiredAlerts: with no types allow-list, every cleared key is eligible', () => {
  const s0 = { ...defaultState(), firedAlerts: { 'overdrawn:a1': 1, 'large_txn:t1': 1 } };
  const { state } = expireFiredAlerts(s0, new Set(['large_txn:t1']));
  assert.deepEqual(state.firedAlerts, { 'large_txn:t1': 1 }, 'overdrawn:a1 cleared and eligible → dropped');
});

// --- milliunits storage + display conversion (AC #6/#7) ---------------------

test('balances are stored as integer milliunits; milliunitsToDollars divides by 1000 for display only', () => {
  const { state } = computeNextState(defaultState(), {
    timestamp: 't',
    accounts: { 'acct-1': { cleared: 123456, uncleared: -7890 } },
  });
  assert.ok(Number.isInteger(state.accounts['acct-1'].cleared));
  assert.ok(Number.isInteger(state.accounts['acct-1'].uncleared));
  assert.equal(milliunitsToDollars(123456), 123.456);
  assert.equal(milliunitsToDollars(-7890), -7.89);
});

// --- writeState hardening: owner-only modes + failed-rename cleanup ---------

test('writeState writes owner-only: the state file is 0600 and its leaf data dir 0700', () => {
  // monitor-state.json stores real account balances (milliunits) — the same
  // sensitivity class as the tax tracker — so pin both mode bits. A refactor that
  // drops them then fails loudly instead of silently world-exposing balances.
  const dir = join(TMP, `secure-${seq++}`);
  const statePath = join(dir, 'monitor-state.json');
  writeState(defaultState(), { statePath, dataDir: TMP });
  assert.equal(statSync(statePath).mode & 0o777, 0o600);
  assert.equal(statSync(dir).mode & 0o777, 0o700);
});

test('writeState unlinks the orphaned temp file when the rename fails', () => {
  // Point the state path AT an existing directory so renameSync(tmp, path) is
  // forced to throw (a file can't be renamed over a directory). This drives the
  // cleanup path that removes the half-written .tmp, so a partial copy of the
  // balance data is never left lying around after a failed write.
  const statePath = join(TMP, `rename-fails-${seq++}`);
  mkdirSync(statePath, { recursive: true });
  assert.throws(() => writeState(defaultState(), { statePath, dataDir: TMP }));
  // The temp name is unpredictable (#206 review), so scan for ANY temp sibling.
  assert.deepEqual(readdirSync(TMP).filter((n) => n.startsWith(`${basename(statePath)}.`) && n.endsWith('.tmp')), [], 'orphaned temp file was removed');
});

// --- path resolution seam ---------------------------------------------------

test('resolveStatePath honours the seam order: option → env → data dir → default', () => {
  assert.equal(resolveStatePath({ statePath: '/x/state.json' }), '/x/state.json');
  assert.equal(resolveStatePath({ env: { YNAB_MONITOR_STATE_FILE: '/y/s.json' } }), '/y/s.json');
  assert.equal(resolveStatePath({ env: { YNAB_DATA_DIR: '/z' } }), join('/z', 'monitor-state.json'));
});

// --- stdout discipline (safe on an MCP / JSON-RPC path) ---------------------

test('the module writes nothing to stdout', () => {
  const url = pathToFileURL(MODULE_PATH).href;
  const tmpState = freshPath();
  const script = `
    import(${JSON.stringify(url)}).then((m) => {
      const { state } = m.readState({ statePath: ${JSON.stringify(tmpState)}, dataDir: ${JSON.stringify(TMP)} });
      const { state: next } = m.computeNextState(state, { timestamp: 't', accounts: { a: { cleared: 1, uncleared: 0 } }, recentTransactionCount: 0 });
      const { state: fired } = m.recordFiredAlert(next, 'overdrawn:a', 1);
      m.expireFiredAlerts(fired, new Set(), { types: ['overdrawn'] });
      m.writeState(next, { statePath: ${JSON.stringify(tmpState)}, dataDir: ${JSON.stringify(TMP)} });
      m.milliunitsToDollars(1000);
      process.stderr.write('ok');                                      // proof it ran
    });
  `;
  const res = spawnSync(process.execPath, ['-e', script], { encoding: 'utf8' });
  assert.equal(res.status, 0, res.stderr);
  assert.equal(res.stdout, '', `expected empty stdout, got: ${JSON.stringify(res.stdout)}`);
  assert.equal(res.stderr, 'ok');
});
