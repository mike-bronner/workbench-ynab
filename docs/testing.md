# Testing — harness, runner, and conventions

This is the **canonical test convention** for `workbench-ynab` (M1 foundation,
issue #4). Every later test-adding issue — offline-boot (#14), CI (#16), and the
M2/M3/M4 test issues — follows the layout and commands here instead of inventing
its own. If you are about to add a test, read this first.

## TL;DR

```bash
scripts/test.sh                       # run the whole suite (bash + node)
scripts/test.sh --bash                # only the bash suite
scripts/test.sh --node                # only the node suite
scripts/test.sh tests/unit/x.test.sh  # run a single test file
UPDATE_SNAPSHOTS=1 scripts/test.sh    # regenerate golden snapshots
```

`scripts/test.sh` is the **single entrypoint** and the command CI (#16) invokes.
It exits non-zero if any test fails. Two near-miss cases are deliberately kept
distinct so the runner can never report a false green:

- **`no tests yet` (exit 0)** — a clean checkout with the harness in place but
  **no test files on disk** at all.
- **selector matched nothing (exit 1)** — test files exist but `--bash` /
  `--node` excluded every one of them. Refusing to exit 0 here is the point:
  a CI gate must never pass having run nothing.
- **contradictory flags (exit 2)** — `--bash` and `--node` together select
  disjoint suites and are rejected as a usage error, not silently merged into
  "run nothing."

## Requirements — and why there are no installs

The harness needs only what the plugin already requires:

- **`bash`** — the bash suite and the entrypoint.
- **system `node`** (current LTS) — the Node suite uses the **built-in
  `node:test`** runner.
- **`jq`** — JSON validation in the bash suite.
- **`security(1)`** — only for tests that read the Keychain (none yet; the
  offline-boot test uses a sentinel env var, not the Keychain).

**No `node_modules`, ever.** This is deliberate, not incidental: the M1-7
offline-boot proof (#14) must launch the vendored MCP with *no* `node_modules`
on the resolution path. If the test harness itself pulled in an npm framework,
that proof would be a lie. So the Node suite imports only `node:` built-ins and
repo-local files, and `scripts/test.sh` runs fine with an absent or empty
`vendor/node_modules`. Keep it that way — do not add a test dependency.

## Directory layout (the canonical convention)

```
tests/
  lib/                     # shared helpers — NOT discovered as tests
    assert.sh              #   bash assertions + run_tests runner
    snapshot.mjs           #   golden-snapshot helper for the node suite
  unit/                    # fast, pure-function tests (bash and/or node)
    *.test.sh
    *.test.mjs
  integration/             # end-to-end: MCP boot, launcher, Keychain
    *.test.sh              #   e.g. offline-boot.test.sh (issue #14)
  snapshot/                # golden-snapshot tests (e.g. M2-12 review output)
    *.test.mjs
    __snapshots__/*.snap   #   committed goldens
  fixtures/                # shared YNAB-shaped fixtures
    populated-budget.json  #   realistic accounts/categories/transactions
    empty-budget.json      #   new/empty budget (GAP-4)
    hostile/               #   adversarial inputs (GAP-13 / GAP-18)
      hostile-transactions.json
      malformed-changeset.json
scripts/
  test.sh                  # the single entrypoint CI invokes
```

**Discovery rules** (enforced by `scripts/test.sh`):

- Bash tests: files named `*.test.sh` anywhere under `tests/` except `tests/lib/`.
- Node tests: files named `*.test.mjs` (or `*.test.js`) anywhere under `tests/`
  except `tests/lib/`.
- Anything under `tests/lib/` is a helper, never run as a test.

## Bash test approach — decision: **raw bash, not bats-core**

The AC let us pick bats-core or a raw-bash convention. We chose **raw bash**, and
this is the recorded decision:

> The plugin's premise is "nothing to install" — vendored MCP, system
> `node`/`jq`/`security`, no `npx`-on-demand. Requiring `brew install bats-core`
> would break that and the no-`node_modules`/offline guarantee. Raw bash needs
> only tools the plugin already mandates.

**Convention.** Each bash test file:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/tests/lib/assert.sh"

test_something() {
  assert_eq "expected" "$(produce_value)"
}

run_tests          # discovers every test_* function, runs each, reports ✓/✗
```

`tests/lib/assert.sh` provides `assert_eq`, `assert_contains`,
`assert_exact_line` (a **whole newline-bounded line** must match, not just a
substring — for set-membership over a newline-separated list),
`assert_file_exists` (a **regular file**, not a directory), `assert_dir_exists`,
`assert_json_valid`, `fail`, and the `run_tests` runner. A failed assertion (or
any non-zero command under `set -e`) fails that test; `run_tests` exits non-zero
if any test failed — **and also if the file defines zero `test_*` functions**, so
a naming typo (`mytest_foo`) is a loud failure, never a silent pass. All bash
scripts must pass `shellcheck` (CI #16 lints them).

## Node test approach — decision: **`node:test` built-in**

We use Node's **built-in test runner** (`node --test`) with `node:assert/strict`
— preferred per the AC because it needs **zero install** and runs offline. No
Jest/Vitest/Mocha.

**Convention.** Each node test file is ESM named `*.test.mjs`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';

test('describes the behaviour', () => {
  assert.equal(actual, expected);
});
```

Import only `node:` modules and repo-local files — never a third-party package.

## How to: run a single test

```bash
scripts/test.sh tests/unit/harness-selftest.test.sh    # one bash file
scripts/test.sh tests/snapshot/example.test.mjs        # one node file
```

You can also run a file directly — `bash tests/unit/x.test.sh` or
`node --test tests/unit/x.test.mjs` — but going through `scripts/test.sh` keeps
discovery/exit semantics identical to CI.

## How to: add a new fixture

1. Drop a YNAB-shaped JSON file under `tests/fixtures/` (or `tests/fixtures/hostile/`
   for adversarial inputs). Mirror the YNAB API response shape — wrap budget data
   as `{ "data": { "budget": { ... } } }`, and keep all monetary amounts as
   **integer milliunits** (1000 milliunits = 1 currency unit).
2. Add a top-level `"_fixture"` description string explaining what the fixture
   represents and which edge case (GAP-n) it covers.
3. Reference it from tests by repo-relative path (resolve `ROOT` as the snippets
   above do) so it's reusable across unit, integration, and snapshot suites.
4. The harness self-test validates every committed fixture is parseable JSON —
   run `scripts/test.sh` and confirm green.

Existing fixtures:

| Fixture | Represents | Edge case |
|---|---|---|
| `populated-budget.json` | realistic budget: 3 accounts, categories, transactions (income, expense, transfer) | — |
| `empty-budget.json` | brand-new budget, no accounts/transactions | GAP-4 |
| `hostile/hostile-transactions.json` | emoji memo, zero-amount, HTML-injection, null fields, very long memo | GAP-13 / GAP-18 |
| `hostile/malformed-changeset.json` | reject-path samples for the M4 change-set validator (#52) | M4-1 |
| `mock-budget.json` | M4 write-back sandbox: uncategorized + miscategorized txns, a duplicate pair, allocation headroom, an account mid-reconcile, a disguised transfer leg, a split parent | M4-12 (#55) |

## Mock YNAB MCP (the M4 write-back sandbox)

`tests/lib/mock-ynab-mcp.cjs` is the **in-process mock YNAB MCP** the M4
write-back tests target (issue #55, M4-12), backed by
`tests/fixtures/mock-budget.json`. It lives under `tests/lib/` — a helper,
never discovered as a test.

**How tests point the executor at the mock vs the vendored bundle.** The apply
executor (M4-4) and every write-path handler (M4-6..M4-9) take their I/O as
**injected ports** — `callTool`, `readLiveState`, `applyOp`, `authPreflight`
(see `skills/apply-executor.md`). Production wires those ports to the vendored
bundle's namespaced tools; tests wire the *same* ports to
`createMockYnab(fixture).callTool`. The seam is the port, so executor and
handler code is **identical in test and prod** — nothing is stubbed inside the
code under test.

**Same namespace, derived — never hard-coded.** Every tool id the mock speaks
is the fully namespaced id the vendored bundle exposes. The ids are *derived*
from the guardrail's exported `ALLOWED_TOOLS`/`DENIED_TOOLS`
(`assets/write-safety-guardrail.js`, an allowlisted tool-name source per issue
#87), so a namespace swap propagates here with no edit, and a bare or
mis-namespaced name never resolves.

**Deliberately in-process, not a stdio MCP server.** Because the seam is the
injected port, there is no JSON-RPC transport, no child process, and no
stdout/stderr discipline to get wrong — and the mock runs in the
no-`node_modules` lane. (The stdio stdout-is-JSON-RPC rule therefore doesn't
apply; it would only bind if the mock ever became a stdio server.)

What it provides:

- **Reads** (`ynab_list_*`, `ynab_get_*`) served from the in-memory fixture —
  responses carry the shape-evidence fields (`subtransactions`,
  `transfer_account_id`, `transfer_transaction_id`) so the #49 live-read hard
  blocks are exercisable end to end.
- **Mutations** (`ynab_update_transaction(s)`, `ynab_update_category`,
  `ynab_delete_transaction`, `ynab_reconcile_account`) that update the
  in-memory state — a read after a write reflects the change
  (drift/idempotency assertions).
- **A call log** — every invocation (name + args) recorded in `callLog`, with
  `callsTo(toolId)` for per-tool assertions.
- **The never-allow gate** — any create/transfer/payment tool throws and the
  attempt is recorded in `neverAllowAttempts` (the never-move-money invariant).
- **Drift injection** — `injectDrift(mutate)` hands the raw in-memory budget to
  the test between proposal-generation and apply (M4-4 drift detection, M4-8
  stale-victim aborts).

Where the suites live:

- `tests/unit/mock-ynab-mcp.test.mjs` — mock unit tests, dependency-free, run
  by `scripts/test.sh` in the no-`node_modules` lane.
- `assets/test/e2e-write-back.test.js` — the end-to-end proposal → dry-run →
  approval → apply test driving the **real** executor and the **real** audit
  writer against the mock. It needs the assets deps (Ajv), so it runs in the
  assets lane: `npm --prefix assets ci && npm --prefix assets test`.

## How to: update golden snapshots

Snapshot tests (e.g. the M2-12 review output) compare a rendered value against a
committed golden under `tests/snapshot/__snapshots__/<name>.snap` via
`matchSnapshot(name, value)` from `tests/lib/snapshot.mjs`.

After an **intentional** change to the rendered output:

```bash
UPDATE_SNAPSHOTS=1 scripts/test.sh        # rewrites all goldens, then passes
```

Then **review the `.snap` diff** like any other code change and commit it. A
missing golden is written automatically on first run (and must be committed so
later runs are real regression guards). Without `UPDATE_SNAPSHOTS`, any
difference fails the test.

`matchSnapshot(name, value)` refuses to write a corrupt golden: a `value` of
`undefined`/`null` or anything `JSON.stringify` drops (a function, a symbol,
or a render with no `return`) throws instead of committing the literal text
`"undefined"`. `name` must be a bare filename — no path separators — so a
snapshot can never be written outside `__snapshots__/`.

## No-`node_modules` mode (offline faithfulness)

`scripts/test.sh` runs with no `node_modules` present. The offline-boot test
(#14) relies on this: it launches `node vendor/ynab-mcp/index.cjs` with a
sentinel `YNAB_ACCESS_TOKEN` and asserts the MCP completes its handshake without
`MODULE_NOT_FOUND`. Never introduce a harness dependency that would require an
`npm install` before tests can run.

## Path map for downstream issues

So later issues plug in without inventing their own layout:

| Issue | What it adds | Canonical path |
|---|---|---|
| #14 (M1-7) offline-boot | MCP boot proof, no `node_modules` | `tests/integration/offline-boot.test.sh` |
| #16 (M1-9) CI | GitHub Actions lint + test | invokes `scripts/test.sh`; lints `bin/*.sh`, `hooks/*.sh`, test `*.sh` |
| M2-12 review snapshot | golden-snapshot of review output | `tests/snapshot/*.test.mjs` + `__snapshots__/` |
| M3 / M4 unit tests | pure-function coverage | `tests/unit/*.test.sh` or `*.test.mjs` |
| M4 change-set validator (#52) | reject-path regression guard | iterate `tests/fixtures/hostile/malformed-changeset.json` |
| M4-12 mock harness (#55) | in-process mock YNAB MCP + E2E write-back test | `tests/lib/mock-ynab-mcp.cjs`, `tests/fixtures/mock-budget.json`, `tests/unit/mock-ynab-mcp.test.mjs`, `assets/test/e2e-write-back.test.js` |

> **Naming note.** Issue #14 loosely refers to `test/offline-boot.sh` (singular).
> The canonical location is `tests/integration/offline-boot.test.sh` (plural
> `tests/`, `.test.sh` suffix so the runner discovers it). Use the canonical
> path.
