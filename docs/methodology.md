# The review methodology — 12 analysis sections

> **Status: stub.** The full, runnable methodology — exact heuristics, tax math,
> and the frozen HTML report template — lands in **Sprint 3 (Review Engine, M2)**
> as a skill. This file is the high-level map of *what* the review covers; it
> deliberately holds no owner-specific numbers and no implementation detail.

> **Not tax advice.** This tool organizes financial data and surfaces
> tax-relevant signals to help you and your tax professional. It is not a
> substitute for professional tax advice.

The review is a productization of a proven, hand-run weekly financial review
that has run since April 2026. It reads a YNAB budget (read-only) and produces a
tax-aware report organized into twelve sections. The data-pull and analysis plan
are sized by the read-only [`ynab-orchestrator`](../agents/ynab-orchestrator.md)
agent; the report itself is composed by the Sprint 3 review skill.

| # | Section | What it surfaces |
|---|---|---|
| 1 | **Cashflow summary** | Inflow vs. outflow for the period; net movement. |
| 2 | **Category health** | Overspent and negative-balance categories; funding gaps. |
| 3 | **Ready-to-Assign** | Unallocated money waiting for a job. |
| 4 | **Needs attention** | Uncategorized, unapproved, and unusual transactions. |
| 5 | **Duplicate detection** | Likely double-entered transactions, flagged for a dedup fix. |
| 6 | **Reconciliation status** | Cleared-vs-reconciled drift per account. |
| 7 | **Accounts & balances** | On/off-budget account balances; net snapshot. |
| 8 | **Business expenses (Schedule C)** | Deductible business spend, mapped to Schedule C lines. |
| 9 | **Medical & dental (Schedule A)** | Spend tracked against the AGI medical threshold. |
| 10 | **Self-employment tax (Schedule SE)** | SE-tax exposure from business net income. |
| 11 | **Quarterly estimated taxes** | Estimated-tax due-date tracking and set-aside. |
| 12 | **Trends & recommendations** | Period-over-period movement and the prioritized action list. |

The tax-aware sections (8–11) are driven entirely by the **tax profile** — a
data-driven, shareable config instance, never hard-coded owner detail. See
[`assets/tax/README.md`](../assets/tax/README.md) for the tax-profile schema and
where the live profile lives.

Sections 2–6 are also where the review surfaces **write-back candidates**
(categorizations, Ready-to-Assign allocations, duplicate fixes, reconciliations)
as a proposed change-set — see the **read / propose / approve loop** in the
[top-level README](../README.md). The plugin never writes anything without
explicit human approval, and it never moves real money.
