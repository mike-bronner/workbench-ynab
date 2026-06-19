// tests/lib/snapshot.mjs — minimal golden-snapshot helper for the Node suite.
//
// Zero dependencies (node: built-ins only), so it runs with NO node_modules
// present. Golden snapshots live under tests/snapshot/__snapshots__/<name>.snap.
//
// Usage from a node:test file:
//   import { matchSnapshot } from '../lib/snapshot.mjs';
//   matchSnapshot('my-report', actualValueOrString);
//
// Behaviour:
//   * UPDATE_SNAPSHOTS=1 in the environment (re)writes the golden and passes.
//   * If the golden is missing, it is written and the test passes (first run).
//     Commit the generated .snap so later runs become real regression guards.
//   * Otherwise the serialized actual is compared to the committed golden and
//     the assertion fails on any difference, telling you how to update.
//
// This is the mechanism issue #4 documents under "update golden snapshots" and
// that the M2-12 read-only review snapshot tests plug into.

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const SNAP_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'snapshot', '__snapshots__');

function serialize(actual) {
  return typeof actual === 'string' ? actual : JSON.stringify(actual, null, 2) + '\n';
}

export function matchSnapshot(name, actual) {
  const serialized = serialize(actual);
  const file = join(SNAP_DIR, `${name}.snap`);
  const update = process.env.UPDATE_SNAPSHOTS === '1';

  if (update || !existsSync(file)) {
    mkdirSync(SNAP_DIR, { recursive: true });
    writeFileSync(file, serialized);
    return;
  }

  const expected = readFileSync(file, 'utf8');
  assert.equal(
    serialized,
    expected,
    `snapshot mismatch for "${name}" — run \`UPDATE_SNAPSHOTS=1 scripts/test.sh\` to update the golden`,
  );
}
