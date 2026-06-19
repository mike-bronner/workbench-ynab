// tests/unit/harness-selftest.test.mjs — proves the Node harness works using
// the built-in node:test runner. Runs with NO node_modules present (only
// node: built-ins are imported), which is what keeps the M1-7 offline-boot
// test (issue #14) faithful. Later JS-level test issues add their own
// tests/**/*.test.mjs alongside this one.
//
// CHOSEN NODE CONVENTION (recorded here and in docs/testing.md):
//   * node:test (built-in) + node:assert — preferred per the AC because it
//     needs zero install and runs offline. No Jest/Vitest/Mocha.
//   * Test files are ESM (.mjs) named *.test.mjs and import only node: modules
//     and repo-local files.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

function readFixture(rel) {
  return JSON.parse(readFileSync(join(ROOT, 'tests/fixtures', rel), 'utf8'));
}

test('node:test runner is available and assertions work', () => {
  assert.equal(1 + 1, 2);
});

test('populated-budget fixture parses with accounts, categories, transactions', () => {
  const { data } = readFixture('populated-budget.json');
  assert.ok(data.budget.accounts.length > 0, 'expected accounts');
  assert.ok(data.budget.categories.length > 0, 'expected categories');
  assert.ok(data.budget.transactions.length > 0, 'expected transactions');
});

test('empty-budget fixture represents a new/empty budget (no transactions)', () => {
  const { data } = readFixture('empty-budget.json');
  assert.equal(data.budget.transactions.length, 0);
  assert.equal(data.budget.accounts.length, 0);
});

test('hostile transactions fixture includes emoji-memo and zero-amount entries', () => {
  const { data } = readFixture('hostile/hostile-transactions.json');
  const byId = Object.fromEntries(data.budget.transactions.map((t) => [t.id, t]));
  assert.match(byId['txn-emoji-memo'].memo, /☕|🎉/u, 'expected emoji in memo');
  assert.equal(byId['txn-zero-amount'].amount, 0);
});

test('malformed-changeset fixture enumerates named reject cases with reasons', () => {
  const fx = readFixture('hostile/malformed-changeset.json');
  assert.ok(Array.isArray(fx.cases) && fx.cases.length >= 5, 'expected >= 5 reject cases');
  for (const c of fx.cases) {
    assert.ok(c._name, 'each case needs a name');
    assert.ok(c._reject_reason, 'each case needs a reject reason');
    assert.ok(c.changeset, 'each case needs a changeset payload');
  }
});
