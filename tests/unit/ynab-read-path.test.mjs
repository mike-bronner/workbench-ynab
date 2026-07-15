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
// (a `Date` for when the window clears, built as `new Date(now + windowMs)`) +
// remaining; an HTTP path may instead carry a 429 message with a Retry-After.
// These builders mirror both shapes — pass resetTime as a Date to mirror the real
// bundle, or as epoch-ms to exercise the numeric-coercion path.
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

test('retryDelayMs honours a Date resetTime from the real bundle (coerced to ms)', () => {
  // The vendored bundle sets resetTime = new Date(now + windowMs) — a Date, NOT
  // epoch-ms. A bare Number.isFinite(Date) is false, so without coercion the
  // bundle's only reset signal is silently discarded and backoff falls through to
  // blind exponential. This pins the coercion against the REAL bundle shape.
  const NOW = 2_000_000;
  const now = () => NOW;
  const future = bundleRateLimit({ resetTime: new Date(NOW + 4000) });
  assert.equal(retryDelayMs(1, future, { now }), 4000, 'Date resetTime honoured, not discarded');
  // A past Date is stale → fall back to exponential, never a negative wait.
  const past = bundleRateLimit({ resetTime: new Date(NOW - 5000) });
  assert.equal(retryDelayMs(3, past, { now, baseDelayMs: 1000 }), 4000); // 1000 * 2^2
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
      assert.equal(err.attempts, 4, 'reports the actual attempts made (maxRetries + 1), not the cap');
      return true;
    },
  );
  assert.equal(calls, 4, 'exactly maxRetries + 1 attempts — the loop never runs unbounded');
});

// --- collectAllPages: AC #4 pagination, AC #8 bound --------------------------

// A faithful paginated source matching the REAL vendored bundle's structured
// list response: rows keyed by the resource name, a `limit` page size (default
// 50), `has_more` true while rows remain, and `next_offset = offset + limit`.
// This is the shape `@dizzlkheinz/ynab-mcpb@0.26.10` actually produces — NOT a
// synthetic cursor shape — so tests built on it prove the default adapter can
// paginate the real bundle (see docs/ynab-read-path.md §1).
function bundlePaginatedCall(resource, allRows, pageSize = 50) {
  return async (_resource, params) => {
    const offset = params.offset ?? 0;
    const limit = params.limit ?? pageSize;
    const page = allRows.slice(offset, offset + limit);
    const hasMore = offset + limit < allRows.length;
    return {
      [resource]: page,
      total_count: allRows.length,
      returned_count: page.length,
      offset,
      has_more: hasMore,
      next_offset: hasMore ? offset + limit : undefined,
    };
  };
}

test('collectAllPages walks every page of the REAL bundle shape and never truncates past page 1', async () => {
  // 125 rows at a 50-row page size ⇒ three pages (50 + 50 + 25). The pre-fix
  // default adapter (which keyed on a non-existent `res.next`) would have
  // stopped after page 1 and silently cut this to the first 50 — the exact
  // failure AC #4 forbids. A weekly review routinely exceeds 50 transactions.
  const rows = Array.from({ length: 125 }, (_, i) => i + 1);
  const { items, pages } = await collectAllPages(
    bundlePaginatedCall('transactions', rows, 50),
    'transactions',
  );
  assert.equal(items.length, 125, 'all 125 rows fetched — not silently cut to the first 50');
  assert.deepEqual(items, rows, 'every page concatenated in order');
  assert.equal(pages, 3, '50 + 50 + 25 ⇒ three offset-paged calls');
});

test('collectAllPages captures server_knowledge when a transport surfaces it (delta forward-hook)', async () => {
  // The vendored bundle's list output does NOT expose server_knowledge (it is
  // consumed internally by the bundle's cacheManager); v1 does full pulls and
  // persists no cursor (docs §3). This asserts only the forward-compat hook: a
  // transport that DOES surface it gets it recorded for a later delta milestone.
  const call = async () => ({ transactions: [1, 2], has_more: false, server_knowledge: 42 });
  const { items, serverKnowledge } = await collectAllPages(call, 'transactions');
  assert.deepEqual(items, [1, 2]);
  assert.equal(serverKnowledge, 42);
});

test('collectAllPages is bounded by maxPages against an endless continuation', async () => {
  let calls = 0;
  // Always signals has_more with an advancing offset — never terminates on its own.
  const endless = async (_resource, params) => {
    calls += 1;
    return { transactions: ['x'], has_more: true, next_offset: (params.offset ?? 0) + 50 };
  };
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
    if ((params.offset ?? 0) === 0) return { transactions: [1, 2], has_more: true, next_offset: 50 };
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
  const call = async () => { calls += 1; return { transactions: [{ id: 'a' }], has_more: false }; };
  const cache = createReadCache(call);

  const first = await cache.get('transactions');
  const second = await cache.get('transactions');
  assert.deepEqual(first.items, [{ id: 'a' }]);
  assert.equal(second, first, 'the same frozen entry is returned, not a re-fetch');
  assert.equal(calls, 1, 'the MCP is touched exactly once per resource per run');
  assert.equal(cache.stats().calls, 1);
});

test('createReadCache caches the FULL paginated set, counting one call per page', async () => {
  // 110 payees at 50/page ⇒ three pages; all 110 must reach the cache.
  const rows = Array.from({ length: 110 }, (_, i) => `p${i}`);
  const cache = createReadCache(bundlePaginatedCall('payees', rows, 50));
  const r = await cache.get('payees');
  assert.deepEqual(r.items, rows);
  assert.equal(r.pages, 3);
  assert.equal(r.partial, false);
  assert.equal(cache.stats().calls, 3, 'three pages → three underlying calls, then memoized');

  await cache.get('payees'); // served from cache
  assert.equal(cache.stats().calls, 3, 'a cached read adds no calls');
});

test('createReadCache shares one in-flight pull across concurrent same-key gets (no double-fetch)', async () => {
  // Pre-#158, get() only cache.set() AFTER awaiting collectAllPages, memoizing
  // the resolved entry — so two concurrent gets for the same key both missed
  // the cache and double-fetched, and a divergent later outcome (e.g. a
  // 429-degraded partial) could clobber the earlier entry. Memoizing the
  // in-flight promise closes that hole in the fetch-once (AC #2) contract.
  // Both get() calls below are issued before either pull resolves.
  let calls = 0;
  const call = async () => { calls += 1; return { transactions: [{ id: 'a' }], has_more: false }; };
  const cache = createReadCache(call);

  const [first, second] = await Promise.all([cache.get('transactions'), cache.get('transactions')]);
  assert.equal(calls, 1, 'two concurrent gets share exactly one underlying call');
  assert.equal(cache.stats().calls, 1);
  assert.equal(second, first, 'both concurrent callers receive the same frozen entry');
  assert.deepEqual(first.items, [{ id: 'a' }]);
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

test('createReadCache surfaces page-1 rows through the cache as a labelled partial when a later page exhausts', async () => {
  // The path that matters for "no silently-truncated data": page 1 succeeds, page
  // 2 exhausts retries. The already-collected rows must reach the cache with
  // partial:true — not be lost and not masquerade as a complete pull. An always-
  // throw-from-call-1 test (above) can never exercise this, since partialItems
  // would be [] by construction.
  const { sleep } = recordingSleep();
  let calls = 0;
  const call = async (_resource, params) => {
    calls += 1;
    if ((params.offset ?? 0) === 0) return { transactions: [{ id: 1 }, { id: 2 }], has_more: true, next_offset: 50 };
    throw httpRateLimit(); // page 2 never clears the limit
  };
  const cache = createReadCache(call, { sleep, maxRetries: 2 });

  const r = await cache.get('transactions');
  assert.equal(r.partial, true, 'flagged partial, not a silent complete pull');
  assert.deepEqual(r.items, [{ id: 1 }, { id: 2 }], 'page-1 rows survive into the cache, not lost');
  assert.equal(r.pages, 1, 'one page landed before the limit bit');
  assert.equal(cache.annotationFor('transactions'), ANNOTATION);
  assert.deepEqual(cache.partials(), ['transactions']);
  assert.equal(calls, 4, '1 success + (maxRetries + 1) exhausted attempts on page 2');

  const again = await cache.get('transactions'); // served from cache, no re-fetch
  assert.equal(again, r);
  assert.equal(calls, 4, 'a cached partial read adds no calls');
});

test('createReadCache lets a non-rate-limit error surface (no false degrade)', async () => {
  const call = async () => { throw new Error('revoked token (401)'); };
  const cache = createReadCache(call);
  await assert.rejects(() => cache.get('accounts'), /revoked token/);
  assert.deepEqual(cache.partials(), [], 'a 401 is not a partial-review condition');
});

test('createReadCache does not memoize a non-rate-limit failure — a later get retries', async () => {
  // Promise memoization (#158) must not change the sequential error semantics:
  // pre-#158 a thrown (non-429) pull left the cache empty, so a later get()
  // re-fetched. The rejected in-flight promise is therefore evicted, never
  // served as a poisoned cache entry to every subsequent caller.
  let calls = 0;
  const call = async () => {
    calls += 1;
    if (calls === 1) throw new Error('revoked token (401)');
    return { accounts: [{ id: 'a1' }], has_more: false };
  };
  const cache = createReadCache(call);

  await assert.rejects(() => cache.get('accounts'), /revoked token/);
  const r = await cache.get('accounts');
  assert.deepEqual(r.items, [{ id: 'a1' }], 'the failed pull was not memoized — the retry fetched');
  assert.equal(calls, 2);
  assert.deepEqual(cache.partials(), [], 'a plain failure never marks the resource partial');
});

test('createReadCache rejects a non-scalar param (no silent cache-key collision)', async () => {
  // JSON.stringify silently drops a function-valued param, so two distinct param
  // sets could otherwise collide on one key. The guard fails loud instead.
  const cache = createReadCache(async () => ({ transactions: [], has_more: false }));
  await assert.rejects(
    () => cache.get('transactions', { weird: () => {} }),
    (err) => {
      assert.ok(err instanceof TypeError);
      assert.match(err.message, /non-scalar param 'weird'/);
      return true;
    },
  );
});

test('RateLimitExhaustedError scrubs the upstream cause to a minimal descriptor', async () => {
  const { sleep } = recordingSleep();
  // An upstream error carrying a sensitive field that must NOT survive onto cause.
  const dirty = httpRateLimit({ retryAfter: 1 });
  dirty.config = { headers: { authorization: 'Bearer SECRET' } };
  await assert.rejects(
    () => withRateLimitRetry(async () => { throw dirty; }, { sleep, maxRetries: 1 }),
    (err) => {
      assert.ok(err instanceof RateLimitExhaustedError);
      assert.deepEqual(Object.keys(err.cause).sort(), ['message', 'name', 'status']);
      assert.equal(err.cause.status, 429);
      assert.equal('config' in err.cause, false, 'sensitive upstream fields are dropped');
      return true;
    },
  );
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
  // Scheduled transactions are deliberately absent: the bundle has no list tool
  // for them and v1 defers them (docs §1).
  assert.deepEqual(CACHEABLE_RESOURCES, [
    'transactions', 'categories', 'accounts', 'payees',
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
      // paginate path: two pages of the real bundle shape walked to completion
      const ok = m.createReadCache(async (_r, p) => {
        const offset = p.offset ?? 0;
        return offset === 0
          ? { categories: [1], has_more: true, next_offset: 50 }
          : { categories: [2], has_more: false };
      });
      await ok.get('categories');
      process.stderr.write('ok');
    });
  `;
  const res = spawnSync(process.execPath, ['-e', script], { encoding: 'utf8' });
  assert.equal(res.status, 0, res.stderr);
  assert.equal(res.stdout, '', `expected empty stdout, got: ${JSON.stringify(res.stdout)}`);
  assert.equal(res.stderr, 'ok');
});
