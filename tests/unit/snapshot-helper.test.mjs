// tests/unit/snapshot-helper.test.mjs — proves the golden-snapshot helper in
// tests/lib/snapshot.mjs actually guards corrupt input and actually catches a
// mismatch. The example.test.mjs only ever exercises the matching (happy) path,
// so on its own it could not tell a real comparator from a no-op one; these
// tests pin the negative paths that the whole snapshot mechanism leans on.
//
// Each test that writes a golden uses a throwaway temp dir (via the `dir`
// option) so the committed __snapshots__/ is never touched.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { matchSnapshot, serialize } from '../lib/snapshot.mjs';

test('serialize refuses values that cannot be a faithful golden', () => {
  // Guards Holmes blocker #3: serialize(undefined) used to coerce to the literal
  // string "undefined" and get committed as a golden with no assertion.
  assert.throws(() => serialize(undefined), /refusing to snapshot/);
  assert.throws(() => serialize(null), /refusing to snapshot/);
  assert.throws(() => serialize(() => {}), /not JSON-serializable/);
  assert.throws(() => serialize(Symbol('x')), /not JSON-serializable/);
});

test('serialize passes strings through and pretty-prints objects', () => {
  assert.equal(serialize('hello'), 'hello');
  assert.equal(serialize({ a: 1 }), '{\n  "a": 1\n}\n');
});

test('matchSnapshot rejects names that would escape the snapshots dir', () => {
  assert.throws(() => matchSnapshot('../evil', 'x'), /bare filename/);
  assert.throws(() => matchSnapshot('sub/dir', 'x'), /bare filename/);
  assert.throws(() => matchSnapshot('', 'x'), /bare filename/);
});

test('matchSnapshot writes a golden, matches it, and fails loudly on a mismatch', () => {
  const dir = mkdtempSync(join(tmpdir(), 'snap-'));
  try {
    // First run writes the golden and passes (no committed golden yet).
    matchSnapshot('demo', { value: 1 }, { dir });
    assert.match(readFileSync(join(dir, 'demo.snap'), 'utf8'), /"value": 1/);
    // The same value matches the golden.
    assert.doesNotThrow(() => matchSnapshot('demo', { value: 1 }, { dir }));
    // A different value must fail — proving the comparator actually compares.
    assert.throws(() => matchSnapshot('demo', { value: 2 }, { dir }), /snapshot mismatch/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('UPDATE_SNAPSHOTS=1 regenerates the golden in place', () => {
  const dir = mkdtempSync(join(tmpdir(), 'snap-'));
  const prev = process.env.UPDATE_SNAPSHOTS;
  try {
    matchSnapshot('demo', { value: 1 }, { dir });
    process.env.UPDATE_SNAPSHOTS = '1';
    // In update mode a differing value rewrites the golden instead of failing.
    matchSnapshot('demo', { value: 999 }, { dir });
    delete process.env.UPDATE_SNAPSHOTS;
    assert.match(readFileSync(join(dir, 'demo.snap'), 'utf8'), /"value": 999/);
    // The regenerated golden is now the one enforced.
    assert.doesNotThrow(() => matchSnapshot('demo', { value: 999 }, { dir }));
    assert.throws(() => matchSnapshot('demo', { value: 1 }, { dir }), /snapshot mismatch/);
  } finally {
    if (prev === undefined) delete process.env.UPDATE_SNAPSHOTS;
    else process.env.UPDATE_SNAPSHOTS = prev;
    rmSync(dir, { recursive: true, force: true });
  }
});
