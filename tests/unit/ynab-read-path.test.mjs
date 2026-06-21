// tests/unit/ynab-read-path.test.mjs — unit tests for the YNAB read-path policy
// (lib/ynab/readPath.mjs, issue #35 / GAP-6).
//
// Runs under the built-in node:test runner with NO node_modules present (only
// node: built-ins and the repo-local module under test are imported), per
// docs/testing.md. Time is never actually spent: every test injects a recording
// no-op `sleep` and (where resetTime matters) a fixed `now`, so the bounded
// backoff is asserted deterministically without waiting.
//
// Covers the AC matrix: 429 detection + retry/backoff/degraded-output (AC #3),
// full pagination never truncated (AC #4), fetch-once caching (AC #2), bounded
// retries + bounded pagination (AC #8), the read path's own timeout context
// distinct from the orchestrator's boot patience (AC #7), and the stdout
// discipline that keeps the module safe on an MCP/JSON-RPC path.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import {
  isRateLimitError,
  retryDelayMs,
  withRateLimitRetry,
  collectAllPages,
  createReadCache,
  RateLimitExhaustedError,
  PaginationBoundError,
  RATE_LIMIT_DEFAULTS,
  PAGINATION_DEFAULTS,
  CACHEABLE_RESOURCES,
  ANNOTATION,
} from '../../lib/ynab/readPath.mjs';

const MODULE_PATH = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'lib', 'ynab', 'readPath.mjs');

// A recording sleep: never waits, just logs the requested delays so backoff is
// observable. Returned alongside its log so each test gets a fresh recorder.
function recordingSleep() {
  const delays = [];
  return { sleep: (ms) => (delays.push(ms), Promise.resolve()), delays };
}

// The vendored bundle throws an Error named 'RateLimitError' carrying resetTime
// (epoch ms) + remaining; an HTTP path may instead carry a 429 message. These
// builders mirror both shapes.
function bundleRateLimit({ resetTime, remaining = 0 } = {}) {
  const e = new Error('Rate limit exceeded. Please wait before making additional requests');
  e.name = 'RateLimitError';
  if (resetTime !== undefined) e.resetTime = resetTime;
  e.remaining = remaining;
  return e;
}
function httpRateLimit({ retryAfter } = {}) {
  const e = new Error('Request failed with status 429 Too Many Requests');
  e.status = 429;
  if (retryAfter !== undefined) e.retryAfter = retryAfter;
  return e;
}

// --- isRateLimitError classifier --------------------------------------------

test('isRateLimitError recognizes every rate-limit shape and rejects others', () => {
  assert.equal(isRateLimitError(bundleRateLimit()), true); // name === RateLimitError
  assert.equal(isRateLimitError(httpRateLimit()), true); // status 429 + message
  assert.equal(isRateLimitError({ code: 'RATE_LIMIT_EXCEEDED' }), true);
  assert.equal(isRateLimitError({ statusCode: 429 }), true);
  assert.equal(isRateLimitError('429 Too Many Requests'), true);
  assert.equal(isRateLimitError('rate limit hit'), true);

  assert.equal(isRateLimitError(new Error('budget not found')), false);
  assert.equal(isRateLimitError({ status: 404 }), false);
  assert.equal(isRateLimitError(null), false);
  assert.equal(isRateLimitError(undefined), false);
});

// --- retryDelayMs: backoff + Retry-After / resetTime hints -------------------

test('retryDelayMs uses exponential backoff with no hint, clamped to maxDelayMs', () => {
  const opts = { baseDelayMs: 1000, maxDelayMs: 60_000 };
  assert.equal(retryDelayMs(1, new Error('plain'), opts), 1000); // base * 2^0
  assert.equal(retryDelayMs(2, new Error('plain'), opts), 2000); // base * 2^1
  assert.equal(retryDelayMs(3, new Error('plain'), opts), 4000); // base * 2^2
  // Far-out attempt is clamped to the ceiling, never astronomically large.
  assert.equal(retryDelayMs(20, new Error('plain'), opts), 60_000);
});

test('retryDelayMs honours an HTTP Retry-After (seconds → ms), clamped', () => {
  assert.equal(retryDelayMs(1, httpRateLimit({ retryAfter: 5 }), { baseDelayMs: 1000 }), 5000);
  // A Retry-After larger than the ceiling is clamped, not obeyed literally.
  assert.equal(retryDelayMs(1, httpRateLimit({ retryAfter: 9999 }), { maxDelayMs: 60_000 }), 60_000);
});

test('retryDelayMs honours a future resetTime and ignores a past one', () => {
  const NOW = 1_000_000;
  const now = () => NOW;
  // resetTime 3s in the future → wait exactly that long.
  assert.equal(retryDelayMs(1, bundleRateLimit({ resetTime: NOW + 3000 }), { now }), 3000);
  // A past resetTime is stale; fall back to exponential backoff, not a negative wait.
  assert.equal(retryDelayMs(2, bundleRateLimit({ resetTime: NOW - 5000 }), { now, baseDelayMs: 1000 }), 2000);
});

// --- withRateLimitRetry: AC #3 retry, AC #8 bound ----------------------------

test('withRateLimitRetry retries a 429 then returns the eventual success', async () => {
  const { sleep, delays } = recordingSleep();
  let calls = 0;
  const fn = async () => {
    calls += 1;
    if (calls <= 2) throw bundleRateLimit();
    return 'ok';
  };
  const out = await withRateLimitRetry(fn, { sleep, baseDelayMs: 1000 });
  assert.equal(out, 'ok');
  assert.equal(calls, 3); // 1 initial + 2 retries
  assert.deepEqual(delays, [1000, 2000]); // exponential backoff between retries
});

test('withRateLimitRetry lets a non-rate-limit error propagate untouched', async () => {
  const { sleep, delays } = recordingSleep();
  await assert.rejects(
    () => withRateLimitRetry(async () => { throw new Error('budget not found'); }, { sleep }),
    /budget not found/,
  );
  assert.equal(delays.length, 0, 'a non-429 error must not trigger any backoff');
});

test('withRateLimitRetry is bounded: it gives up after exactly maxRetries (no unbounded loop)', async () => {
  const { sleep } = recordingSleep();
  let calls = 0;
  const fn = async () => { calls += 1; throw bundleRateLimit(); };
  await assert.rejects(
    () => withRateLimitRetry(fn, { sleep, maxRetries: 3 }),
    (err) => {
      assert.ok(err instanceof RateLimitExhaustedError);
      assert.equal(err.attempts, 3);
      return true;
    },
  );
  assert.equal(calls, 4, 'exactly maxRetries + 1 attempts — the loop never runs unbounded');
});

// --- collectAllPages: AC #4 pagination, AC #8 bound --------------------------

// A faithful paginated source: the first call carries no cursor; each page
// points at the next via `next`, the default adapter threads it back as `cursor`.
function paginatedCall(store) {
  return async (_resource, params) => store[params.cursor ?? '__first__'];
}

test('collectAllPages fetches every page in full and never truncates', async () => {
  const store = {
    __first__: { items: [1, 2], next: 'c1', serverKnowledge: 10 },
    c1: { items: [3, 4], next: 'c2', serverKnowledge: 20 },
    c2: { items: [5], serverKnowledge: 30 }, // no `next` → last page
  };
  const { items, pages, serverKnowledge } = await collectAllPages(paginatedCall(store), 'transactions');
  assert.deepEqual(items, [1, 2, 3, 4, 5], 'all three pages concatenated, not just the first');
  assert.equal(pages, 3);
  assert.equal(serverKnowledge, 30, 'carries the latest server_knowledge');
});

test('collectAllPages is bounded by maxPages against an endless continuation', async () => {
  let calls = 0;
  const endless = async () => { calls += 1; return { items: ['x'], next: 'again' }; };
  await assert.rejects(
    () => collectAllPages(endless, 'transactions', {}, { maxPages: 5 }),
    (err) => {
      assert.ok(err instanceof PaginationBoundError);
      assert.equal(err.maxPages, 5);
      return true;
    },
  );
  assert.equal(calls, 5, 'stops at the page ceiling rather than looping forever');
});

test('collectAllPages attaches already-collected rows when retries exhaust mid-walk', async () => {
  const { sleep } = recordingSleep();
  const call = async (_resource, params) => {
    if (params.cursor === undefined) return { items: [1, 2], next: 'c1' };
    throw bundleRateLimit(); // the second page never clears the limit
  };
  await assert.rejects(
    () => collectAllPages(call, 'transactions', {}, { sleep, maxRetries: 2 }),
    (err) => {
      assert.ok(err instanceof RateLimitExhaustedError);
      assert.deepEqual(err.partialItems, [1, 2], 'page-1 rows survive the failure');
      assert.equal(err.pages, 1);
      return true;
    },
  );
});

// --- createReadCache: AC #2 fetch-once, AC #3 degraded output ----------------

test('createReadCache fetches a resource once and serves every later read from cache', async () => {
  let calls = 0;
  const call = async () => { calls += 1; return { items: [{ id: 'a' }] }; };
  const cache = createReadCache(call);

  const first = await cache.get('transactions');
  const second = await cache.get('transactions');
  assert.deepEqual(first.items, [{ id: 'a' }]);
  assert.equal(second, first, 'the same frozen entry is returned, not a re-fetch');
  assert.equal(calls, 1, 'the MCP is touched exactly once per resource per run');
  assert.equal(cache.stats().calls, 1);
});

test('createReadCache caches the FULL paginated set, counting one call per page', async () => {
  const store = {
    __first__: { items: ['a', 'b'], next: 'c1' },
    c1: { items: ['c'] },
  };
  const cache = createReadCache(paginatedCall(store));
  const r = await cache.get('transactions');
  assert.deepEqual(r.items, ['a', 'b', 'c']);
  assert.equal(r.pages, 2);
  assert.equal(r.partial, false);
  assert.equal(cache.stats().calls, 2, 'two pages → two underlying calls, then memoized');

  await cache.get('transactions'); // served from cache
  assert.equal(cache.stats().calls, 2, 'a cached read adds no calls');
});

test('createReadCache degrades to a labelled partial review when 429 retries exhaust', async () => {
  const { sleep } = recordingSleep();
  let calls = 0;
  const call = async () => { calls += 1; throw httpRateLimit(); };
  const cache = createReadCache(call, { sleep, maxRetries: 3 });

  const r = await cache.get('transactions');
  assert.equal(r.partial, true, 'degrades rather than crashing the run');
  assert.deepEqual(r.items, [], 'no silently-truncated data — an explicit empty partial');
  assert.equal(cache.annotationFor('transactions'), ANNOTATION);
  assert.equal(cache.annotationFor('categories'), null, 'unaffected resources carry no annotation');
  assert.deepEqual(cache.partials(), ['transactions']);
  assert.equal(calls, 4, 'bounded: maxRetries + 1 attempts, then degrade');
});

test('createReadCache lets a non-rate-limit error surface (no false degrade)', async () => {
  const call = async () => { throw new Error('revoked token (401)'); };
  const cache = createReadCache(call);
  await assert.rejects(() => cache.get('accounts'), /revoked token/);
  assert.deepEqual(cache.partials(), [], 'a 401 is not a partial-review condition');
});

// --- AC #7: the read path's timeout context is its own, not the orchestrator's

test('rate-limit defaults are self-contained and distinct from boot patience', () => {
  // The read path caps at 3 retries with exponential backoff — its OWN context.
  // The orchestrator's cold-start patience (agents/ynab-orchestrator.md: ~10×2s)
  // is unrelated; nothing here references or shares it.
  assert.equal(RATE_LIMIT_DEFAULTS.maxRetries, 3);
  assert.ok(RATE_LIMIT_DEFAULTS.baseDelayMs > 0 && RATE_LIMIT_DEFAULTS.maxDelayMs > 0);
  assert.ok(Object.isFrozen(RATE_LIMIT_DEFAULTS) && Object.isFrozen(PAGINATION_DEFAULTS));
  // Callers can override the read path's budget without touching any global.
  assert.equal(retryDelayMs(1, new Error('x'), { baseDelayMs: 500 }), 500);
  assert.deepEqual(CACHEABLE_RESOURCES, [
    'transactions', 'categories', 'accounts', 'payees', 'scheduled_transactions',
  ]);
});

// --- stdout discipline: safe on an MCP / JSON-RPC path ----------------------

test('the read path writes nothing to stdout (degrade + paginate paths)', () => {
  const url = pathToFileURL(MODULE_PATH).href;
  const script = `
    import(${JSON.stringify(url)}).then(async (m) => {
      // degrade path: always-429 → bounded retries → partial, no throw, no log
      const degr = m.createReadCache(async () => { const e = new Error('429'); e.status = 429; throw e; },
        { sleep: () => Promise.resolve(), maxRetries: 2 });
      await degr.get('transactions');
      // paginate path: two pages walked to completion
      const store = { __first__: { items: [1], next: 'c1' }, c1: { items: [2] } };
      const ok = m.createReadCache(async (_r, p) => store[p.cursor ?? '__first__']);
      await ok.get('categories');
      process.stderr.write('ok');
    });
  `;
  const res = spawnSync(process.execPath, ['-e', script], { encoding: 'utf8' });
  assert.equal(res.status, 0, res.stderr);
  assert.equal(res.stdout, '', `expected empty stdout, got: ${JSON.stringify(res.stdout)}`);
  assert.equal(res.stderr, 'ok');
});
