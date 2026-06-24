// lib/ynab/readPath.mjs — the workbench-ynab YNAB read-path policy (issue #35, GAP-6).
//
// WHAT THIS IS
//   The executable specification of how a financial-review run reads YNAB:
//     1. FETCH-ONCE — each list resource (transactions, categories, accounts,
//        payees) is pulled at most once per run and held in an in-memory cache;
//        all 12 review sections derive from that cache instead of re-querying the
//        MCP per section. (Scheduled transactions have no list tool in the
//        vendored bundle and are deferred for v1 — see docs/ynab-read-path.md §1.)
//     2. RATE-LIMIT BACKOFF — an HTTP 429 (or the vendored bundle's thrown
//        `RateLimitError`) is detected, honours a `Retry-After` / `resetTime`
//        hint when present (else exponential backoff), retries a BOUNDED number
//        of times (default 3), and on exhaustion degrades to a clearly-labelled
//        partial review rather than crashing or silently truncating.
//     3. PAGINATION — a list response that signals more pages is followed to
//        exhaustion before the result is cached; a hard page ceiling makes an
//        unbounded loop structurally impossible.
//   See docs/ynab-read-path.md for the vendored-bundle investigation, the
//   `server_knowledge` delta decision, the request budget, and the separation
//   from the orchestrator's cold-start patience.
//
// WHO CALLS THIS
//   A node-side caller that injects `call` — the function that actually invokes
//   one YNAB list tool and returns its response. The driver is transport-
//   agnostic on purpose: the same policy backs the vendored third-party MCP
//   today and a future bundled-own MCP (Sprint 6) without an edit here. It is
//   also the canonical encoding of the read-path rules that the review skill's
//   prose protocol mirrors when Claude drives the vendored MCP directly. This
//   module NEVER hard-codes an MCP tool name (it takes `call` + a `resource`
//   string), so the tool-name guard does not apply to it.
//
// STDOUT / STDERR DISCIPLINE
//   This module emits NOTHING to stdout. It returns structured data (and, at the
//   cache boundary, degrades instead of throwing); direct callers of the lower
//   primitives get a typed throw. Keeping stdout clean means it is safe even on
//   an MCP / JSON-RPC path, where a single stray stdout byte corrupts the
//   handshake (see workbench-core/hooks/mcp-memory.sh, docs/mcp-capability-map.md).
//
// DEPENDENCY-FREE BY DESIGN
//   Imports nothing — only language built-ins (`setTimeout`, `Date.now`). The
//   plugin's "nothing to install" premise and the recorded "no node_modules,
//   ever" test-harness decision (docs/testing.md) mean the runtime path the
//   skills use must not assume any npm package is present.

// The literal annotation a section built from a rate-limited resource carries.
// Kept verbatim from the acceptance criteria so the review report and the tests
// reference one constant rather than re-typing the string.
export const ANNOTATION = '[YNAB rate limit hit — partial review]';

// The list resources the fetch-once cache holds. One `get` per resource per run
// feeds all 12 sections; the request budget in docs/ynab-read-path.md sizes the
// per-run call count against YNAB's ~200 requests/hour limit. Scheduled
// transactions are absent on purpose: the vendored bundle exposes no list tool
// for them (they ride only inside the heavyweight `get_budget` detail), so v1
// defers them rather than duplicating the per-resource pulls — see docs §1.
export const CACHEABLE_RESOURCES = Object.freeze([
  'transactions',
  'categories',
  'accounts',
  'payees',
]);

// Rate-limit backoff parameters. This is the read path's OWN timeout context —
// deliberately separate from the orchestrator's cold-start boot patience
// (agents/ynab-orchestrator.md: ~10×2s polls while the MCP spawns). The two
// never share state: boot patience waits for a server that is still starting;
// this waits out a live server's rate-limit window. `maxRetries` caps the retry
// loop so it can never run unbounded.
export const RATE_LIMIT_DEFAULTS = Object.freeze({
  maxRetries: 3, // total attempts ≤ maxRetries + 1
  baseDelayMs: 1000, // first backoff step; doubles each attempt
  maxDelayMs: 60_000, // ceiling on any single wait (also clamps a Retry-After hint)
});

// Default page size, matched to the vendored bundle's `limit` default (50). Five
// of the bundle's six list tools (accounts, categories, payees, transactions,
// months) page at this size via `limit`/`offset`; only `list_budgets` returns
// everything at once. See docs/ynab-read-path.md §1.
export const DEFAULT_PAGE_SIZE = 50;

// Pagination safety ceiling. The vendored bundle's list tools page with
// `limit`/`offset` and signal continuation via `has_more`/`next_offset`, so a
// resource with more rows than one page MUST be walked to exhaustion (a 300-row
// budget is six 50-row pages). `maxPages` is the structural guard: a misbehaving
// or future endpoint that never stops signalling "more" fails loud with a
// `PaginationBoundError` instead of looping forever.
export const PAGINATION_DEFAULTS = Object.freeze({ maxPages: 1000 });

// --- Errors -----------------------------------------------------------------

// Keep only a minimal, transport-safe descriptor of an upstream error — never the
// whole object. This module is transport-agnostic; a future HTTP-transport error
// could carry an Authorization header or a response body on its fields, so we copy
// just the diagnostic bits (name/message/status) and drop the rest.
function scrubCause(err) {
  if (err == null) return err;
  if (typeof err !== 'object') return { message: String(err) };
  const { name, message, status } = err;
  return { name, message, status };
}

// Raised when the bounded retry budget is exhausted. Carries a scrubbed
// descriptor of the originating rate-limit error plus any rows already collected,
// so the cache can degrade to a partial result instead of losing them.
export class RateLimitExhaustedError extends Error {
  constructor(cause, attempts) {
    super(`YNAB rate limit not cleared after ${attempts} attempt${attempts === 1 ? '' : 's'}`);
    this.name = 'RateLimitExhaustedError';
    this.cause = scrubCause(cause); // scrubbed: no headers/body leak across the boundary
    this.attempts = attempts; // total attempts actually made (initial + retries)
    this.partialItems = [];
    this.pages = 0;
  }
}

// Raised when pagination crosses the page ceiling — a structural guard against
// an unbounded loop, never expected on a well-behaved endpoint.
export class PaginationBoundError extends Error {
  constructor(resource, maxPages) {
    super(`pagination for '${resource}' exceeded the ${maxPages}-page ceiling`);
    this.name = 'PaginationBoundError';
    this.resource = resource;
    this.maxPages = maxPages;
  }
}

// --- Helpers ----------------------------------------------------------------

const defaultSleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Default response adapters, matched to the vendored bundle's structured list
// response (@dizzlkheinz/ynab-mcpb@0.26.10): rows are keyed by the resource name
// (`{ transactions: [...] }`, `{ accounts: [...] }`, …), and continuation is
// OFFSET-based — `has_more` is true while rows remain and `next_offset` is the
// offset of the following page (`offset + limit`). There is NO cursor. A
// transport with a different shape injects its own getItems/getNextParams; the
// driver itself stays transport-agnostic. See docs/ynab-read-path.md §1.
const defaultGetItems = (res, resource) =>
  res && Array.isArray(res[resource]) ? res[resource] : [];
const defaultGetNextParams = (res, params) => {
  if (!res || !res.has_more) return null;
  const pageSize = params.limit ?? DEFAULT_PAGE_SIZE;
  return { ...params, offset: res.next_offset ?? (params.offset ?? 0) + pageSize };
};

function resolveOpts(opts = {}) {
  return {
    maxRetries: opts.maxRetries ?? RATE_LIMIT_DEFAULTS.maxRetries,
    baseDelayMs: opts.baseDelayMs ?? RATE_LIMIT_DEFAULTS.baseDelayMs,
    maxDelayMs: opts.maxDelayMs ?? RATE_LIMIT_DEFAULTS.maxDelayMs,
    maxPages: opts.maxPages ?? PAGINATION_DEFAULTS.maxPages,
    sleep: opts.sleep ?? defaultSleep,
    now: opts.now ?? Date.now,
    getItems: opts.getItems ?? defaultGetItems,
    getNextParams: opts.getNextParams ?? defaultGetNextParams,
  };
}

/**
 * Classify whether an error is a YNAB rate-limit signal. Defensive across the
 * shapes that cross this trust boundary (the error comes from an external MCP /
 * HTTP layer we don't control): the vendored bundle throws an Error named
 * `RateLimitError`; an HTTP path may surface `status`/`statusCode` 429 or a
 * `RATE_LIMIT_EXCEEDED` code; and any of them may only carry a message string.
 * @param {unknown} err
 * @returns {boolean}
 */
export function isRateLimitError(err) {
  if (!err) return false;
  if (typeof err === 'string') return /\b429\b|too many requests|rate.?limit/i.test(err);
  if (err.name === 'RateLimitError') return true;
  if (err.code === 'RATE_LIMIT_EXCEEDED') return true;
  if (err.status === 429 || err.statusCode === 429 || err.code === 429) return true;
  const msg = typeof err.message === 'string' ? err.message : '';
  return /\b429\b|too many requests|rate.?limit|RATE_LIMIT_EXCEEDED/i.test(msg);
}

// Read an explicit "wait this long" hint off a rate-limit error, in ms, or null.
// Honours an HTTP `Retry-After` (seconds) first, then the vendored bundle's
// `RateLimitError.resetTime` — a `Date` for when the window clears (the bundle
// builds it as `new Date(now + windowMs)`), coerced to epoch-ms here. A past or
// malformed hint is ignored so a stale value never short-circuits the
// exponential fallback.
function retryHintMs(err, nowMs) {
  if (!err || typeof err !== 'object') return null;
  if (Number.isFinite(err.retryAfter) && err.retryAfter > 0) return err.retryAfter * 1000;
  // `+resetTime` coerces a Date → epoch-ms (and passes a numeric epoch through);
  // `Number.isFinite` does NOT coerce, so a bare `Number.isFinite(new Date())` is
  // always false and would silently discard the bundle's only reset signal.
  const reset = +err.resetTime;
  if (Number.isFinite(reset)) {
    const delta = reset - nowMs;
    if (delta > 0) return delta;
  }
  return null;
}

/**
 * The delay before the next retry: an explicit Retry-After / resetTime hint when
 * present (clamped to `maxDelayMs`), otherwise exponential backoff
 * (`baseDelayMs * 2^(attempt-1)`, clamped). `attempt` is 1-based.
 * @param {number} attempt 1-based retry number.
 * @param {unknown} err the rate-limit error (may carry retryAfter / resetTime).
 * @param {object} [opts] baseDelayMs, maxDelayMs, now.
 * @returns {number} delay in milliseconds.
 */
export function retryDelayMs(attempt, err, opts = {}) {
  const { baseDelayMs, maxDelayMs, now } = resolveOpts(opts);
  const hint = retryHintMs(err, now());
  if (hint != null) return Math.min(hint, maxDelayMs);
  return Math.min(baseDelayMs * 2 ** (attempt - 1), maxDelayMs);
}

/**
 * Run `fn`, retrying ONLY on a rate-limit error, with bounded backoff. Any other
 * error propagates untouched. After `maxRetries` exhausted retries it throws a
 * `RateLimitExhaustedError` carrying the last cause. The retry count is capped
 * by construction, so the loop can never run unbounded (AC #8).
 * @template T
 * @param {() => Promise<T>} fn the call to attempt.
 * @param {object} [opts] maxRetries, baseDelayMs, maxDelayMs, sleep, now.
 * @returns {Promise<T>}
 */
export async function withRateLimitRetry(fn, opts = {}) {
  const resolved = resolveOpts(opts);
  let attempt = 0;
  while (true) {
    try {
      return await fn();
    } catch (err) {
      if (!isRateLimitError(err)) throw err;
      attempt += 1;
      if (attempt > resolved.maxRetries) throw new RateLimitExhaustedError(err, attempt);
      await resolved.sleep(retryDelayMs(attempt, err, resolved));
    }
  }
}

/**
 * Fetch every page of a list resource and concatenate the rows. Each page fetch
 * is rate-limit-retried; pagination follows the response's continuation signal
 * (via `getNextParams`) until none remains, bounded by `maxPages`. If retries are
 * exhausted mid-walk, the already-collected rows are attached to the thrown
 * `RateLimitExhaustedError` so the caller can still degrade to a partial result.
 * @param {(resource: string, params: object) => Promise<object>} call
 * @param {string} resource the logical list resource (e.g. 'transactions').
 * @param {object} [params] initial query params.
 * @param {object} [opts] retry + pagination + adapter options.
 * @returns {Promise<{ items: any[], pages: number, serverKnowledge: number|undefined }>}
 */
export async function collectAllPages(call, resource, params = {}, opts = {}) {
  const resolved = resolveOpts(opts);
  let pageParams = params;
  let pages = 0;
  let items = [];
  let serverKnowledge;
  while (true) {
    if (pages >= resolved.maxPages) throw new PaginationBoundError(resource, resolved.maxPages);
    let res;
    try {
      res = await withRateLimitRetry(() => call(resource, pageParams), resolved);
    } catch (err) {
      if (err instanceof RateLimitExhaustedError) {
        err.partialItems = items;
        err.pages = pages;
      }
      throw err;
    }
    pages += 1;
    items = items.concat(resolved.getItems(res, resource));
    // Forward-compat hook for the delta milestone (docs §3): capture the cursor
    // if a transport surfaces it. The vendored bundle's list output does NOT —
    // it consumes server_knowledge internally — so for v1 this stays undefined.
    const sk = res && (res.server_knowledge ?? res.serverKnowledge);
    if (sk !== undefined) serverKnowledge = sk;
    const nextParams = resolved.getNextParams(res, pageParams);
    if (nextParams == null) break;
    pageParams = nextParams;
  }
  return { items, pages, serverKnowledge };
}

// Stable cache key for a resource + its params (param key order is normalized so
// `{a,b}` and `{b,a}` collide as the same pull). Params are always scalars
// (offset, limit, since_date, budget_id); a non-scalar is rejected loudly, because
// JSON.stringify silently drops function/symbol/undefined values and two distinct
// param sets could then collide on one key.
function cacheKey(resource, params) {
  const sorted = {};
  for (const k of Object.keys(params).sort()) {
    const v = params[k];
    if (v !== null && !['string', 'number', 'boolean'].includes(typeof v)) {
      throw new TypeError(`cacheKey: non-scalar param '${k}' (${typeof v}) for '${resource}'`);
    }
    sorted[k] = v;
  }
  return `${resource}::${JSON.stringify(sorted)}`;
}

/**
 * Build the per-run fetch-once read cache. `get(resource, params)` pulls a list
 * resource exactly once — paginated in full and rate-limit-retried — then
 * memoizes it; every later call for the same resource+params returns the cached
 * rows without touching the MCP. On exhausted retries it degrades: the
 * resource+params pull is recorded as partial, `annotationFor(resource, params)`
 * yields the `[YNAB rate limit hit — partial review]` label, and `get` returns
 * whatever rows were collected with `partial: true` rather than throwing.
 * @param {(resource: string, params: object) => Promise<object>} call
 * @param {object} [opts] retry + pagination + adapter options.
 * @returns {{
 *   get: (resource: string, params?: object) => Promise<{items:any[],pages:number,partial:boolean,serverKnowledge:number|undefined}>,
 *   annotationFor: (resource: string, params?: object) => string|null,
 *   partials: () => string[],
 *   stats: () => { calls: number, resources: number, partials: string[] }
 * }}
 */
export function createReadCache(call, opts = {}) {
  const resolved = resolveOpts(opts);
  const cache = new Map();
  // Keyed by the SAME cacheKey as `cache` (resource + params), mapping to the
  // resource name. Keying on resource alone would wrongly mark every param-set
  // of a resource partial when only one exhausted retries.
  const degraded = new Map(); // cacheKey -> resource
  let calls = 0;

  // Count every underlying MCP call so the request budget (docs/ynab-read-path.md)
  // can be asserted in tests and observed at runtime.
  const countedCall = (resource, params) => {
    calls += 1;
    return call(resource, params);
  };

  async function get(resource, params = {}) {
    const key = cacheKey(resource, params);
    if (cache.has(key)) return cache.get(key);

    let entry;
    try {
      const { items, pages, serverKnowledge } = await collectAllPages(
        countedCall,
        resource,
        params,
        resolved,
      );
      entry = Object.freeze({ items, pages, partial: false, serverKnowledge });
    } catch (err) {
      if (!(err instanceof RateLimitExhaustedError)) throw err;
      degraded.set(key, resource);
      entry = Object.freeze({
        items: err.partialItems,
        pages: err.pages,
        partial: true,
        serverKnowledge: undefined,
      });
    }
    cache.set(key, entry);
    return entry;
  }

  const partialResources = () => [...new Set(degraded.values())];
  return {
    get,
    annotationFor: (resource, params = {}) =>
      degraded.has(cacheKey(resource, params)) ? ANNOTATION : null,
    partials: partialResources,
    stats: () => ({ calls, resources: cache.size, partials: partialResources() }),
  };
}

export default createReadCache;
