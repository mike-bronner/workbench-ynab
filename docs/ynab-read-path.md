# YNAB read path — rate limits, pagination, and `server_knowledge` deltas

> **What this covers.** How a financial-review run reads YNAB safely under the
> API's ~200 requests/hour limit: fetch each list resource once, handle an HTTP
> 429 with bounded backoff, paginate to completion, and the recorded decision on
> `server_knowledge` deltas. The policy is implemented and tested in
> [`lib/ynab/readPath.mjs`](../lib/ynab/readPath.mjs) /
> [`tests/unit/ynab-read-path.test.mjs`](../tests/unit/ynab-read-path.test.mjs);
> this note is the human-readable contract and the rationale.
>
> **Issue:** [#35](https://github.com/mike-bronner/workbench-ynab/issues/35) ·
> GAP-6 · Sprint 3 — Review Engine. **Design refs:** the read-only orchestrator
> ([`agents/ynab-orchestrator.md`](../agents/ynab-orchestrator.md)) and the
> swap-ready capability map ([`docs/mcp-capability-map.md`](mcp-capability-map.md)).

## Why this exists

YNAB enforces **200 requests/hour per token** (rolling window). A heavy review
fires `list_transactions` / `list_categories` / `list_accounts` / `list_payees` /
`list_scheduled_transactions` across **12 sections**; re-querying per section
would multiply calls and can exhaust the hourly budget. The orchestrator's
cold-start *boot patience* covers a server that is still spawning — it does
**not** cover a live server's rate-limit window. This is the read path's
reliability layer for that gap.

## 1. Vendored-bundle behaviour (investigation)

Findings from reading the vendored bundle `@dizzlkheinz/ynab-mcpb@0.26.10`
(`vendor/ynab-mcp/index.cjs`, the prebuilt `dist/bundle/index.cjs`). These are
the behaviours the skill must build on; re-confirm them on any re-vendor or MCP
swap (see the capability map's swap procedure).

| Concern | What the bundle does | What the skill must therefore do |
|---|---|---|
| **HTTP 429 / rate limit** | Ships a **client-side preemptive limiter** — a sliding window `{ maxRequests: 200, windowMs: 3600000 }`. On `tryAcquire`, when the window is full it **throws** a `RateLimitError` (an `Error` subclass carrying `resetTime` — an epoch-ms timestamp for when the window clears — and `remaining`). It also classifies a real HTTP 429 (`message.includes("429") \|\| "Too Many Requests"` → `RATE_LIMIT_EXCEEDED`). **It does *not* retry or back off** — it surfaces the error. | Catch the rate-limit error and back off ourselves: honour `resetTime` (or an HTTP `Retry-After`), else exponential backoff; cap the retries; degrade to a labelled partial review. The bundle gives us no retry, so the skill owns it. |
| **Pagination** | YNAB's REST **list endpoints are not page-paginated** — `GET /transactions`, `/categories`, `/accounts`, `/payees`, `/scheduled_transactions` return the **full collection** in one response (optionally filtered by `since_date`). The bundle exposes no `offset`/`page`/`per_page`/cursor for these. (The `cursor`/`hasMore`/`nextCursor` symbols in the bundle are the MCP framework's internal *task-listing*, unrelated to YNAB data.) | A single pull is complete for the vendored bundle, so there is no first-page-only truncation risk today. The driver still follows any continuation signal to exhaustion (and is bounded by a page ceiling) so a future endpoint or bundled-own MCP that *does* paginate is handled without a rewrite. |
| **`server_knowledge` deltas** | **Supported.** The bundle threads `lastKnowledgeOfServer` into the raw list calls, list responses carry `server_knowledge`, and it maintains a `knowledgeStore` + `cacheManager` (with TTLs) for incremental pulls. | v1 does **full pulls** and does **not** persist a cursor — see §3. The driver records the latest `server_knowledge` so a later milestone can opt into deltas without a shape change. |

## 2. The read strategy (fetch-once)

Each list resource is fetched **at most once per review run** and held in an
in-memory cache; all 12 sections derive from that cache rather than re-querying
the MCP per section. This is [`createReadCache`](../lib/ynab/readPath.mjs):
`get(resource, params)` pulls once (paginated in full, rate-limit-retried), then
memoizes by `resource + params`; every later read is served from memory with no
further MCP traffic. The cacheable resources are
`transactions, categories, accounts, payees, scheduled_transactions`.

We keep our own in-memory cache rather than leaning on the bundle's internal
`cacheManager` TTLs: the fetch-once guarantee is then explicit and observable
(call count, partial flags) instead of depending on opaque TTL behaviour that
could change across a re-vendor.

## 3. `server_knowledge` delta decision — **v1: full pulls, no persisted cursor**

**Decision:** v1 does a **full pull** of each list resource on every run and
**does not persist** a `server_knowledge` cursor between runs.

**Rationale:**

- **Statelessness.** A persisted cursor is durable state that can desync (a
  cursor from a different budget/token, a server reset, a partially-applied
  delta) and silently yield an incomplete view — exactly the kind of
  hard-to-debug correctness bug a financial review must not have.
- **The budget allows it.** A weekly review's full pull is a handful of calls
  (§4) — far under 200/hour. Deltas optimize a constraint v1 is nowhere near.
- **Deltas pay off only for frequent polling.** The win is for the M6-1
  between-run *monitor* (cheap, frequent polls), not a once-weekly review. The
  driver already surfaces `server_knowledge`, so that milestone can adopt deltas
  (and own the cursor-persistence + invalidation) without changing this shape.

## 4. Request budget for a typical weekly review

One fetch-once pull per list resource, plus the planner's resolve/sizing reads.
Each YNAB list endpoint returns its full collection in a single response (§1), so
pages-per-resource is **1** for the vendored bundle.

| Call | Count | Notes |
|---|---|---|
| `list_budgets` | 1 | resolve the target budget (planner) |
| `list_accounts` | 1 | fetch-once |
| `list_categories` | 1 | fetch-once |
| `list_transactions` | 1 | fetch-once; `since_date`-scoped to the review period |
| `list_payees` | 1 | fetch-once |
| `list_scheduled_transactions` | 1 | fetch-once |
| `get_month` | 1–3 | one per in-scope month (weekly review ⇒ 1) |
| **Total** | **≈ 7–9** | **well under the ~200 requests/hour limit** |

Even a re-run inside the same hour stays in the single digits. The 12 sections
add **zero** calls beyond this set — they read the cache, which is the point of
fetch-once. Headroom against 200/hr is roughly **20×**.

## 5. Two separate timeout contexts (they must not interfere)

Rate-limit backoff and the orchestrator's cold-start patience are **distinct
contexts with no shared state** — required by the issue so neither masks the
other:

| | Trigger | Budget | Lives in |
|---|---|---|---|
| **Cold-start boot patience** | MCP still spawning (zero-match `ToolSearch` / transport error) | ~10 × 2s = 20s, then `ynab_mcp_offline` | [`agents/ynab-orchestrator.md`](../agents/ynab-orchestrator.md) |
| **Rate-limit backoff** | a live server returns 429 / throws `RateLimitError` | `maxRetries` (default 3) × exp/`Retry-After` backoff, then a labelled partial review | [`lib/ynab/readPath.mjs`](../lib/ynab/readPath.mjs) (`RATE_LIMIT_DEFAULTS`) |

Boot patience waits for a server that has not started; rate-limit backoff waits
out a started server's quota. A 429 never triggers boot patience (it is not a
transport error), and a cold start never triggers rate-limit backoff (no 429 is
in flight). Their parameters are independent constants, so tuning one never
moves the other.

## 6. Bounded retries (no unbounded loops)

Every loop in the read path is bounded by construction:

- **Retries** are capped at `maxRetries` (default 3): the attempt counter is
  compared to the cap and, once exhausted, the read **degrades** — the resource
  is recorded as partial and any section built from it is annotated
  `[YNAB rate limit hit — partial review]`. No data is silently truncated; the
  partial state is explicit.
- **Pagination** is capped at `maxPages` (default 1000): an endpoint that never
  stops signalling "more" raises a `PaginationBoundError` instead of looping
  forever. The vendored bundle returns a single page, so this is a guard, not a
  hot path.
