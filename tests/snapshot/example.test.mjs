// tests/snapshot/example.test.mjs — demonstrates the golden-snapshot flow that
// the M2-12 read-only review snapshot tests will use. It renders a deterministic
// shape and asserts it against a committed golden under __snapshots__/. To
// update goldens after an intentional change:  UPDATE_SNAPSHOTS=1 scripts/test.sh
//
// Delete or repurpose this example once a real snapshot test lands — it exists
// to prove the mechanism and document the update workflow on a clean checkout.

import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { matchSnapshot } from '../lib/snapshot.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

// A tiny, deterministic "render" derived from a shared fixture — the kind of
// thing a review section produces and a snapshot test pins.
function renderAccountSummary(budget) {
  return {
    budget: budget.name,
    accounts: budget.accounts.map((a) => ({ name: a.name, type: a.type, balance: a.balance })),
  };
}

test('account summary matches the committed golden snapshot', () => {
  const { data } = JSON.parse(
    readFileSync(join(ROOT, 'tests/fixtures/populated-budget.json'), 'utf8'),
  );
  matchSnapshot('account-summary', renderAccountSummary(data.budget));
});
