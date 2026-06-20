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
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const SNAP_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'snapshot', '__snapshots__');

// Turn a value into the exact bytes of its golden. Refuses values that cannot
// be faithfully captured — `undefined`/`null`, and anything `JSON.stringify`
// drops to `undefined` (functions, symbols). Without these guards a typo'd prop
// or a no-return render would silently commit the literal text "undefined" as
// the golden, which later runs would then enforce as "correct".
export function serialize(actual) {
  if (actual === undefined || actual === null) {
    throw new TypeError(
      `matchSnapshot: refusing to snapshot ${String(actual)} — pass a string or a JSON-serializable value`,
    );
  }
  if (typeof actual === 'string') return actual;
  const json = JSON.stringify(actual, null, 2);
  if (json === undefined) {
    throw new TypeError(
      `matchSnapshot: value of type ${typeof actual} is not JSON-serializable — refusing to write a corrupt golden`,
    );
  }
  return json + '\n';
}

// matchSnapshot(name, actual[, { dir }])
//   * name must be a bare filename — no path separators — so a snapshot can
//     never be written outside the snapshots directory (e.g. a "../" name).
//   * dir defaults to the committed __snapshots__ location; tests override it to
//     exercise the write/compare/update paths without touching real goldens.
export function matchSnapshot(name, actual, { dir = SNAP_DIR } = {}) {
  if (typeof name !== 'string' || name === '' || name !== basename(name)) {
    throw new Error(
      `matchSnapshot: name must be a bare filename with no path separators, got ${JSON.stringify(name)}`,
    );
  }
  const serialized = serialize(actual);
  const file = join(dir, `${name}.snap`);
  const update = process.env.UPDATE_SNAPSHOTS === '1';

  if (update || !existsSync(file)) {
    mkdirSync(dir, { recursive: true });
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
