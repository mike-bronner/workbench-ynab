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
fires `list_transactions` / `list_categories` / `list_accounts` / `list_payees`
across **12 sections**; re-querying per section would multiply calls and can
exhaust the hourly budget. The orchestrator's cold-start *boot patience* covers a
server that is still spawning — it does **not** cover a live server's rate-limit
window. This is the read path's reliability layer for that gap.

## 1. Vendored-bundle behaviour (investigation)

Findings from reading the vendored bundle `@dizzlkheinz/ynab-mcpb@0.26.10`
(`vendor/ynab-mcp/index.cjs` — the frozen copy of record; `bin/ynab-mcp` execs
it). These are the behaviours the skill must build on; re-confirm them on any
re-vendor or MCP swap (see the capability map's swap procedure).

| Concern | What the bundle does | What the skill must therefore do |
|---|---|---|
| **HTTP 429 / rate limit** | Ships a **client-side preemptive limiter** — a sliding window `{ maxRequests: 200, windowMs: 3600000 }`. On `tryAcquire`, when the window is full it **throws** a `RateLimitError` (an `Error` subclass carrying `resetTime` — a **`Date`** for when the window clears, built as `new Date(now + windowMs)` — and `remaining`). It also classifies a real HTTP 429 (`message.includes("429") \|\| "Too Many Requests"` → `RATE_LIMIT_EXCEEDED`). **It does *not* retry or back off** — it surfaces the error. | Catch the rate-limit error and back off ourselves: honour `resetTime` (coerce its `Date` to epoch-ms) or an HTTP `Retry-After`, else exponential backoff; cap the retries; degrade to a labelled partial review. The bundle gives us no retry, so the skill owns it. |
| **Pagination** | **The list tools paginate — 5 of the 6 do.** `ynab_list_accounts`, `ynab_list_categories`, `ynab_list_payees`, `ynab_list_transactions`, and `ynab_list_months` each register `limit (int, optional, **default 50**)` and `offset (int, optional, zero-based)`. Each list response carries `total_count`, `returned_count`, `offset`, `has_more`, and `next_offset` (`= offset + limit` when `has_more`, else absent), with rows keyed by the resource name (`{ transactions: [...] }`). Only `ynab_list_budgets` returns its whole collection in one shot. Continuation is **offset-based**, not cursor-based — the `cursor`/`hasMore`/`nextCursor` symbols elsewhere in the bundle are the MCP framework's internal *task-listing*, unrelated to YNAB data. | **Walk every page** before caching: re-issue the list call advancing `offset` by the page size while `has_more` is true (following `next_offset`). The default page size is 50, so any resource with >50 rows — a routine weekly transaction set — is multiple calls. Failing to do this silently truncates the review to the first 50 rows, exactly what AC #4 forbids. The driver does this with an offset-based default adapter, bounded by a page ceiling so a misbehaving endpoint fails loud instead of looping. |
| **`server_knowledge` deltas** | **Supported internally, not surfaced on list output.** The bundle threads `lastKnowledgeOfServer` into the raw YNAB API calls (whose REST responses carry `server_knowledge`) and maintains a `knowledgeStore` + `cacheManager` (with TTLs) for incremental pulls. But the MCP **list tool's structured output does not echo `server_knowledge`** to the client — it ends at `…has_more, next_offset, cached, cache_info`. | v1 does **full pulls** and does **not** persist a cursor — see §3. The driver carries a forward-compat hook that records `server_knowledge` from any response that surfaces it; against the vendored bundle that is always undefined, so a later delta milestone must switch to a transport that exposes the cursor (and own persistence + invalidation) without a shape change here. |

**Scheduled transactions have no list tool.** The bundle's complete `ynab_list_*`
set is `accounts, budgets, categories, months, payees, transactions` — confirmed
against `vendor/ynab-mcp/index.cjs` and the repo's canonical registry
[`skills/protocol/ynab-tools.md`](../skills/protocol/ynab-tools.md). Scheduled
transactions are exposed only **inside the full `get_budget` BudgetDetail** — and
the bundle's `ynab_get_budget` handler **strips `scheduled_transactions[]` at the
tool boundary**, projecting the detail down to counts, so a `get_budget` call
yields no scheduled transactions either. The vendored MCP therefore exposes **no
read path** to them. Sourcing them requires an architecture change (patch the
frozen bundle or add a raw-REST path); that is the **authorized follow-up
[#157](https://github.com/mike-bronner/workbench-ynab/issues/157)**, carved out of
this read-path-reliability layer. They are therefore not a cacheable list resource
here (absent from `CACHEABLE_RESOURCES` and §4); `createReadCache` carries the
forward-compat hook so #157 slots a source in without a shape change.

## 2. The read strategy (fetch-once)

Each list resource is fetched **at most once per review run** and held in an
in-memory cache; all 12 sections derive from that cache rather than re-querying
the MCP per section. This is [`createReadCache`](../lib/ynab/readPath.mjs):
`get(resource, params)` pulls once (paginated in full, rate-limit-retried), then
memoizes by `resource + params`; every later read is served from memory with no
further MCP traffic. What is memoized is the **in-flight promise** (set before
the pull resolves), so even concurrent `get` calls for the same key share one
underlying pull — the fetch-once guarantee holds under concurrency, not just in
the sequential fetch-then-derive flow (#158). The cacheable resources are
`transactions, categories, accounts, payees` (scheduled transactions are deferred
— they have no list tool; see §1).

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
  driver carries a forward-compat hook that records `server_knowledge` from any
  response surfacing it — but the vendored bundle's list output does not expose
  it (§1), so that milestone must adopt a transport that does, then own the
  cursor-persistence + invalidation, without changing this shape.

## 4. Request budget for a typical weekly review

One fetch-once pull per list resource, plus the planner's resolve/sizing reads.
The bundle's list tools paginate at a **default page size of 50** (§1), so a
resource of `N` rows costs `ceil(N / 50)` calls — not 1. The counts below size a
heavier-than-typical budget so the total is a true ceiling, not a best case.

| Call | Rows (example) | Calls = ⌈N/50⌉ | Notes |
|---|---|---|---|
| `list_budgets` | — | 1 | resolve the target budget (planner); not paginated |
| `list_accounts` | ~10 | 1 | fetch-once |
| `list_categories` | ~120 | 3 | fetch-once (groups + categories) |
| `list_transactions` | ~300 | 6 | fetch-once; `since_date`-scoped to the review period |
| `list_payees` | ~200 | 4 | fetch-once; a mature budget accrues many payees |
| `get_month` | 1 per month | 1–3 | one per in-scope month (weekly review ⇒ 1) |
| **Total** | | **≈ 16 (≈ 18 worst-case)** | **well under the ~200 requests/hour limit** |

Scheduled transactions are **not** in this budget — the vendored MCP exposes no
read path to them, so they are carved into the authorized follow-up #157 (§1). The
page count scales with budget size, but even a large budget
lands near ~16 calls — roughly **10×** headroom against 200/hr, and a re-run inside
the same hour stays well within it. The 12 sections add **zero** calls beyond this
set — they read the cache, which is the point of fetch-once.

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
  stops signalling `has_more` raises a `PaginationBoundError` instead of looping
  forever. The vendored bundle paginates at 50 rows/page (§1), so multi-page
  walks are the normal path; at 1000 pages the ceiling is ~50,000 rows — far
  above any real budget, so it bounds a misbehaving endpoint without ever
  clipping a legitimate pull.
