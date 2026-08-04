// tests/unit/resolve-tool.test.mjs — the shared fail-closed write-tool resolver
// (assets/resolve-tool.js, issue #216).
//
// The resolver is dependency-free pure string inspection, so — like write-error.mjs
// and transaction-shape.mjs — it gates here in CI with NO node_modules present, per
// docs/testing.md. Its whole job is to REFUSE, so most of these cases assert a throw:
// a write path that resolves a guess instead of throwing is the fail-open bug this
// module exists to make impossible.
//
// Tool names below use a fake `mcp__x__` prefix so this file holds no concrete
// namespaced YNAB name (the issue #87 guard, bin/check-tool-name-sources.sh).
//
// The module is CommonJS; require it through createRequire.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

const { resolveUniqueTool } = require(join(ROOT, 'assets', 'resolve-tool.js'));

const LABELS = { context: 'test-path', subject: 'the test tool' };

// --- exactly one match: the only case that resolves ---------------------------

test('resolveUniqueTool returns the single suffix match', () => {
  assert.equal(
    resolveUniqueTool(['mcp__x__ynab_get_transaction', 'mcp__x__ynab_delete_transaction'], '_delete_transaction', LABELS),
    'mcp__x__ynab_delete_transaction',
  );
});

test('resolveUniqueTool ignores non-string allow-list entries rather than crashing on them', () => {
  assert.equal(
    resolveUniqueTool([null, 42, undefined, 'mcp__x__ynab_update_category'], '_update_category', LABELS),
    'mcp__x__ynab_update_category',
  );
});

// --- zero matches: fail closed ------------------------------------------------

test('resolveUniqueTool fails closed on ZERO matches — never returns undefined', () => {
  assert.throws(
    () => resolveUniqueTool(['mcp__x__ynab_get_transaction'], '_delete_transaction', LABELS),
    /test-path: expected exactly ONE \*_delete_transaction tool.*found 0.*refusing to resolve the test tool \(fail-closed\)/,
  );
  assert.throws(() => resolveUniqueTool([], '_delete_transaction', LABELS), /found 0/);
});

test('resolveUniqueTool fails closed on a non-array allow-list — an absent list is zero matches, not a pass', () => {
  // A guardrail import gone wrong (undefined export, a swapped object) must throw,
  // never resolve. `.filter` on a non-array would also throw, but with a TypeError
  // that names nothing useful — this is the diagnosable refusal.
  for (const bad of [undefined, null, 'mcp__x__ynab_delete_transaction', { 0: 'mcp__x__ynab_delete_transaction' }]) {
    assert.throws(() => resolveUniqueTool(bad, '_delete_transaction', LABELS), /found 0/);
  }
});

// --- multiple matches: fail closed, and name the collision --------------------

test('resolveUniqueTool fails closed on MULTIPLE matches and names every colliding tool', () => {
  // The regression: `.find()` silently took the first match, so an allow-list entry
  // sharing a suffix could receive a write meant for another tool. Both names appear
  // in the message so the offending allow-list edit is obvious from the throw alone.
  assert.throws(
    () => resolveUniqueTool(['mcp__x__ynab_delete_transaction', 'mcp__x__ynab_bulk_delete_transaction'], '_delete_transaction', LABELS),
    /found 2 \(mcp__x__ynab_delete_transaction, mcp__x__ynab_bulk_delete_transaction\)/,
  );
});

// --- anchored suffix, NOT substring: the nesting suffix pair ------------------

test('resolveUniqueTool matches an ANCHORED suffix, so the nesting update-transaction pair stays unambiguous', () => {
  // `_update_transaction` is a substring of `_update_transactions`. Under a substring
  // (`includes`) match the singular suffix would match BOTH tools — with `.find()`
  // that silently routes a single-transaction write to the BULK tool. `endsWith` is
  // anchored, so each suffix resolves exactly its own tool. Both array orders are
  // pinned: a resolver that depended on order would pass one and fail the other.
  const singular = 'mcp__x__ynab_update_transaction';
  const plural = 'mcp__x__ynab_update_transactions';
  for (const list of [[singular, plural], [plural, singular]]) {
    assert.equal(resolveUniqueTool(list, '_update_transaction', LABELS), singular);
    assert.equal(resolveUniqueTool(list, '_update_transactions', LABELS), plural);
  }
});

// --- a bad suffix is its own, distinct refusal --------------------------------

test('resolveUniqueTool rejects an empty or non-string suffix instead of matching everything', () => {
  // `''.endsWith` is true for every string, so an empty suffix would "resolve" the
  // first entry of a one-tool allow-list — a silent mis-route. It is rejected as a
  // caller error, with a message that points at the suffix rather than the allow-list.
  const list = ['mcp__x__ynab_delete_transaction'];
  for (const bad of ['', undefined, null, 42, {}]) {
    assert.throws(
      () => resolveUniqueTool(list, bad, LABELS),
      /tool suffix must be a non-empty string.*refusing to resolve the test tool \(fail-closed\)/,
    );
  }
});

// --- diagnostics ---------------------------------------------------------------

test('resolveUniqueTool still throws an intelligible message when the caller omits labels', () => {
  assert.throws(
    () => resolveUniqueTool([], '_delete_transaction'),
    /tool resolution: expected exactly ONE \*_delete_transaction tool.*refusing to resolve the write tool \(fail-closed\)/,
  );
});
