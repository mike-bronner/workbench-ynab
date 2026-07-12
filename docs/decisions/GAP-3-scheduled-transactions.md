# GAP-3 — Scheduled transactions are not exposed by the vendored MCP; v1 forecast falls back to history

> **Type:** Decision record (investigation + fallback contract — **no production code, template, or skill is modified**).
> **Issue:** [#32](https://github.com/mike-bronner/workbench-ynab/issues/32) · Sprint 3 — Review Engine.
> **Design ref:** GAP-3. Depends on M1-7, M2-1.
> **Status:** Decided — **Path B (tool absent)**. Fallback contract defined; wiring deferred to M2-1.
> **Related:** [#42](https://github.com/mike-bronner/workbench-ynab/issues/42) (frozen report template), M2-1 (review-engine wiring — consumes this record), M6-3 (v-Next richer forecast — consumes this record).

## TL;DR — Verdict: **tool absent**

The frozen, SHA-256-verified vendored bundle (`vendor/ynab-mcp/index.cjs`,
`@dizzlkheinz/ynab-mcpb@0.26.10`) registers **exactly 28 `ynab_`-prefixed MCP
tools, and none surfaces scheduled transactions.** The YNAB REST endpoint
`GET /budgets/{id}/scheduled_transactions` exists, and the SDK inside the bundle
carries the client method and the full `ScheduledTransaction*` type set — but no
MCP **tool** wraps it, so the review skill cannot call it. This is a real v1
functional gap for the forecast (§10) and bill-due logic, not a v-Next nicety.

The v1 forecast therefore **degrades to a history-derived estimate** (recurring
spend + prior-month patterns), rendered with an explicit uncertainty label, and
renders a **`forecast unavailable`** slot rather than a confident wrong number
when even that source is empty or errors. The contract for that behaviour is
defined in [§2](#2-v1-fallback-contract) below; wiring it into the review engine
is M2-1 work (see [§3](#3-scope--deferral)).

---

## 1. Investigation — how "tool absent" was confirmed

Verification is against the **real vendored bundle**, not the npm docs — the
registered, namespaced tool set is what the skill can actually call.

- **Artifact:** `vendor/ynab-mcp/index.cjs`
- **Source package:** `@dizzlkheinz/ynab-mcpb@0.26.10`
- **Bundle SHA-256:** `65cf53b8cac5…ebcaedb5`
- **Provenance:** `signature_status: verified` (`npm audit signatures`); tarball
  SHA-256 `f41e18ab4c9a…a3409ac3`. The bundle is **frozen** — it must not be
  hand-edited, and Path B does not require editing it.
- **Canonical digests:** `vendor/ynab-mcp/vendored.json` holds the full,
  authoritative values (`bundle_sha256`, `tarball_sha256`, `tarball_integrity`).
  Digests are shown truncated here on purpose: the repo secret scanner
  (`bin/secret-scan.sh`, rule 1) rejects a standalone 64-char hex run — the YNAB
  PAT shape — anywhere outside `vendor/`, and `vendored.json` is the single
  source of truth for these hashes anyway.

Every registered tool name was extracted directly from the bundle:

```sh
grep -oE 'name:"ynab_[a-z_]+"' vendor/ynab-mcp/index.cjs \
  | sed -E 's/name:"(ynab_[a-z_]+)"/\1/' | sort -u    # → 28 tools
```

### The 28 registered tools (complete list)

Grouped by capability area (28 total — none for scheduled transactions):

| Area | Tools |
|------|-------|
| **Budget / user / meta** (7) | `ynab_list_budgets`, `ynab_get_budget`, `ynab_get_default_budget`, `ynab_set_default_budget`, `ynab_get_user`, `ynab_diagnostic_info`, `ynab_clear_cache` |
| **Accounts** (4) | `ynab_list_accounts`, `ynab_get_account`, `ynab_create_account`, `ynab_reconcile_account` |
| **Categories** (3) | `ynab_list_categories`, `ynab_get_category`, `ynab_update_category` |
| **Months** (2) | `ynab_list_months`, `ynab_get_month` |
| **Payees** (2) | `ynab_list_payees`, `ynab_get_payee` |
| **Transactions — read** (4) | `ynab_list_transactions`, `ynab_get_transaction`, `ynab_export_transactions`, `ynab_compare_transactions` |
| **Transactions — write** (6) | `ynab_create_transaction`, `ynab_create_transactions`, `ynab_create_receipt_split_transaction`, `ynab_update_transaction`, `ynab_update_transactions`, `ynab_delete_transaction` |

For an unambiguous machine-checkable copy, the full sorted list is:

```
ynab_clear_cache
ynab_compare_transactions
ynab_create_account
ynab_create_receipt_split_transaction
ynab_create_transaction
ynab_create_transactions
ynab_delete_transaction
ynab_diagnostic_info
ynab_export_transactions
ynab_get_account
ynab_get_budget
ynab_get_category
ynab_get_default_budget
ynab_get_month
ynab_get_payee
ynab_get_transaction
ynab_get_user
ynab_list_accounts
ynab_list_budgets
ynab_list_categories
ynab_list_months
ynab_list_payees
ynab_list_transactions
ynab_reconcile_account
ynab_set_default_budget
ynab_update_category
ynab_update_transaction
ynab_update_transactions
```

None contains `scheduled` (`grep 'name:"[a-z_]*scheduled[a-z_]*"'` → no match).

### Why the SDK's `scheduled_transactions` code is a red herring

The string `scheduled_transactions` **does** appear in the bundle, but every
occurrence is internal SDK plumbing, never a registered MCP tool:

- JSON (de)serializers — `ScheduledTransactionBaseFromJSON` / `…ToJSON` and the
  `scheduled_transactions:` object mappers.
- The raw request path template — `"/plans/{plan_id}/scheduled_transactions"`.
- A cache-TTL constant — `SCHEDULED_TRANSACTIONS: 300*1e3`.
- Internal client fetch methods that build the delta options.

A tool is only reachable when it is registered with a `name:"ynab_…"` handler.
The capability path is **client method → MCP tool → namespaced skill call**; the
bundle stops at the first arrow for scheduled transactions. The capability map's
approximate "~30 tools" is the source of the earlier mismatch — the **registered
count is 28**.

**Verdict:** the review skill has **no** call that returns scheduled/upcoming
transactions. Path B (fallback) is required for any forecast or bill-due logic.

---

## 2. v1 fallback contract

This is the **contract** the forecast must honour — *what* the fallback produces
and how it must degrade — for whoever wires §10 (M2-1). It is deliberately not an
implementation.

### Data source (derive, don't fetch)

Because no scheduled-transactions tool exists, "upcoming bills" are **derived**
from data the review already computes with the 28 available tools:

1. **Recurring / subscription spend** — the output of the review methodology's
   recurring-spend detection (`skills/review/ynab-review.md` §3 *Cost-Cutting*,
   the "Section 3 equivalent" in the issue AC): payees/categories that recur on a
   monthly-ish cadence become the expected upcoming bills.
2. **Prior-month transaction patterns** — the same-window history from
   `ynab_list_transactions` (+ `ynab_get_month` for budgeted amounts): a bill
   that hit in each of the last N periods is expected to recur, at roughly its
   historical amount, near its historical day-of-month.

Both sources use only tools present in the 28-tool set — the contract is
buildable without any bundle change.

### Labelling — the estimate must never masquerade as authoritative

- **Every** forecast figure derived from this fallback must carry the exact
  label **`estimated from history (scheduled-transactions data unavailable)`**
  in the rendered HTML fragment (the forecast slots — see below). The number is
  an estimate, and the report must say so at the point of the number.

### Degradation — degrade loudly, never silently

- When the fallback source returns **empty** (no recurring spend detected, no
  prior-month history in the window) **or errors**, the forecast must render a
  **`forecast unavailable`** state in its slot — an explicit "we can't forecast
  this period" message — **never** a confident number, a zero, or a blank that
  reads as "nothing due."

### Where it renders (the real consumer)

In the current review engine, §10 *Forecast*
(`skills/review/ynab-review.md`) is the consumer. It feeds two frozen-template
block slots (`assets/report/SLOTS.md`):

- `SLOT:section-5-cash-flow` — §10 Forecast (cash flow)
- `SLOT:section-9-net-worth` — §10 Forecast (net worth)

§10 currently states it projects from "the period's run-rate and **known
scheduled transactions**." This investigation proves that second source does not
exist in v1; the fallback above is what §10 must actually consume. There is **no
dedicated forecast slot** in the frozen #42 template — the forecast surfaces
through the cash-flow and net-worth slots — so honouring this contract requires
**no new template slot**.

---

## 3. Scope & deferral

**This PR is scoped to investigation + this decision record only.** It creates
`docs/decisions/GAP-3-scheduled-transactions.md` and touches **no** source files,
templates, methodology skill, orchestrator tool list, or pre-approval globs.

The **wiring** of the contract above is explicitly deferred to the **M2-1
review-engine** work, which consumes this record. M2-1 owns:

- Implementing the history-derived fallback in §10 *Forecast* of
  `skills/review/ynab-review.md` (and correcting §10's "known scheduled
  transactions" premise to the fallback).
- Emitting the `estimated from history (scheduled-transactions data unavailable)`
  label on every fallback figure in the `SLOT:section-5-cash-flow` /
  `SLOT:section-9-net-worth` fragments.
- The `forecast unavailable` degradation path on empty/error.
- A **degradation test** proving the forecast never renders a confident number
  when the fallback source is empty or errors.

Nothing above is done in this PR.

---

## 4. v-Next handoff (M6-3)

This record is sufficient for M6-3 to scope a richer v-Next scheduled-transactions
forecast **without re-running the bundle investigation**:

- The gap is a **missing MCP tool**, not a missing API. The upstream YNAB API
  exposes `GET /budgets/{id}/scheduled_transactions` and the vendored SDK already
  carries the client method + `ScheduledTransaction*` types — only the MCP tool
  registration is absent.
- **Two v-Next paths to real scheduled data:** (a) upstream/patched bundle that
  registers a `ynab_list_scheduled_transactions` tool (revisit on any
  `@dizzlkheinz/ynab-mcpb` bump past `0.26.10` — re-run the §1 grep to check),
  or (b) the bundled-own MCP direction tracked in the spike
  `docs/spike-bundled-ynab-mcp.md` (#86), which could register the tool directly.
- When real scheduled-transactions data lands, the v-Next forecast should
  **supersede** the history-derived estimate defined in §2 and drop the
  `estimated from history …` label — the fallback is the floor, not the ceiling.

_Last verified against `@dizzlkheinz/ynab-mcpb@0.26.10`, bundle SHA-256
`65cf53b8…ebcaedb5`. Re-verify (§1 grep) on any bundle bump._
