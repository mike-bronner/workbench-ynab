# The review methodology — 12 analysis sections

This is the human-readable map of the tax-aware review methodology: the twelve
analyses every review runs, what each surfaces, and where its output lands.

> ⚠️ Estimates only — not tax advice. Consult a qualified professional before filing or paying.
> (Canonical wording: [`skills/shared/disclaimer.md`](../skills/shared/disclaimer.md).)

> **The skill is the source of truth.** The runnable methodology — the exact
> heuristics, config reads, tier matrix, and slot-fill contract — is the
> universal protocol skill
> [`skills/review/ynab-review.md`](../skills/review/ynab-review.md) (issue #40).
> If anything here diverges from the skill, **the skill wins** and this doc must
> be corrected to match it.

The methodology productizes a proven, hand-run weekly financial review that ran
as a scheduled prototype since April 2026. Every tier (weekly / monthly /
quarterly-tax / annual) runs the **same** protocol skill; thin tier wrappers
just set the tier. The read-only
[`ynab-orchestrator`](../agents/ynab-orchestrator.md) plans the data pull; the
skill runs the analyses and fills the frozen HTML report template; the dispatch
summary ([`docs/dispatch-format.md`](./dispatch-format.md)) is the TL;DR.

**The methodology is generic.** The skill holds zero owner-specific facts and
zero hardcoded tax constants — every owner detail (budget, business structure,
filing status, rates, thresholds, due dates) is a **config instance** read
through the shared loaders: the persona loader ([`docs/persona.md`](./persona.md)),
the config loader ([`docs/config-loader.md`](./config-loader.md)), and the tax
profile ([`docs/tax-mapping.md`](./tax-mapping.md)). The prototype hard-wired
one user's situation into its text; that is exactly what this productization
removed.

**Milliunits.** Every YNAB monetary amount arrives in **milliunits — divide by
1000** before any display or comparison (`-12340` is `-12.34`). The divisor is
always 1000 regardless of currency; display formatting is owned by the shared
money helper (`assets/format-money.js`).

## The twelve sections

As implemented in [`skills/review/ynab-review.md`](../skills/review/ynab-review.md)
§6 — same order and, with two deliberate exceptions, the same names: rows 9 and
12 keep the prototype's fuller names — **Financial Health Score** and
**Tax Summary (YTD)** — where the skill abbreviates them to *Health Score* and
*Tax Summary YTD*.

| # | Section | What it does |
|---|---|---|
| 1 | **Transaction Classification (tax-aware)** | Classifies each transaction in the window against the tax profile's mapping rules and Schedule **C / A / SE / 1** line maps; rolls up deductible spend by schedule and tax line. Low-confidence classifications are marked as guesses, never presented as settled. |
| 2 | **Duplicate Detection** | Flags likely double-entries (same/near amount + payee + date proximity). Transfer legs are excluded from the candidate set — a linked inflow/outflow pair is legitimate, and deleting one leg would corrupt the linked ledger. Surfaces only; fixes are proposed via write-back. |
| 3 | **Cost-Cutting** | Surfaces recurring/subscription and high-frequency spend where a cut is plausible, quantifying the monthly/annual saving. |
| 4 | **Uncategorized** | Lists transactions with no category (plus carryover uncategorized from before the window on the weekly tier). |
| 5 | **Stale Uncleared** | Flags uncleared transactions older than the staleness window — likely missed or duplicated. |
| 6 | **Budget Health** | Overspent / negative-balance categories, funding gaps, Ready-to-Assign, and goal/target progress. |
| 7 | **Unusual / Large** | Transactions that are outliers for their category or payee — large vs. the period norm, first-time large payees. |
| 8 | **Reconciliation Status** | Cleared-vs-reconciled drift per account; flags accounts overdue for reconciliation. |
| 9 | **Financial Health Score** | Six 1–10 sub-scores rolled into one overall score: Budget Adherence, Cash-Flow Health, Categorization Completeness, Reconciliation Currency, Spending Discipline, Tax Readiness. Each sub-score derives from the sections above, so the score is auditable, not a black box. |
| 10 | **Forecast** | Projects period-end and near-term cash flow / net worth from the period's run-rate and known scheduled transactions. |
| 11 | **Recommended Actions** | The prioritized action list — every actionable finding above, highest-impact first (categorize these, fund that, dedup these, reconcile that). |
| 12 | **Tax Summary (YTD)** | Year-to-date roll-up by schedule: Schedule C P&L, Schedule A itemizables vs. the standard deduction, medical spend against the AGI threshold, SE-tax exposure, and quarterly estimated-tax status — every rate, deduction, and due date read from the tax profile. Tier-dependent (skipped on the weekly tier). |

Which sections run — and over what lookback window — is set per tier by the
skill's tier matrix (`skills/review/ynab-review.md` §7): weekly is the fast
7-day hygiene pass, monthly deepens budget health and forecast, quarterly-tax
anchors on the estimated-tax due dates, annual runs the full tax year.

Sections 2–6 are also where the review surfaces **write-back candidates**
(categorizations, Ready-to-Assign allocations, duplicate fixes,
reconciliations) as a proposed change-set. The review itself is strictly
read-only — it proposes, never applies. The full safety model, including the
batch-approval gate, is [`docs/write-back-safety.md`](./write-back-safety.md).

## Provenance — divergences from the prototype, called out

The prototype (`~/Documents/Claude/Scheduled/ynab-financial-review/SKILL.md`)
defined these twelve analyses; the productized skill keeps their order and
intent, and — the two abbreviated section names noted above aside — their
names. The deliberate divergences:

- **Owner facts became config.** The prototype's inline employment structure,
  business category groups, filing status, deduction amounts, rates, and due
  dates are now one tax-profile/config instance
  ([`docs/tax-mapping.md`](./tax-mapping.md)) — the methodology text carries
  none of them.
- **Health-score sub-scores were re-derived.** The prototype scored budgeting
  discipline, debt management, savings rate, cash flow, emergency preparedness,
  and tax readiness by judgment; the skill's six sub-scores (section 9 above)
  are each computed from a named section's output so the overall score is
  auditable.
- **Duplicate detection excludes transfer legs** (GAP-19 / issue #49) — the
  prototype had no transfer-leg guard.
- **The report chrome is frozen.** The prototype regenerated the entire HTML
  document each run; the skill fills injection slots in the frozen template
  ([`assets/report/SLOTS.md`](../assets/report/SLOTS.md)) and hands assembly to
  the report writer ([`docs/report-writer.md`](./report-writer.md)).
- **Write-back exists — behind a gate.** The prototype was read-only by
  instruction; the plugin adds an approval-gated, ledger-only write path as a
  separate flow ([`docs/write-back-safety.md`](./write-back-safety.md)). The
  review protocol itself remains read-only.

---

> ⚠️ Estimates only — not tax advice. Consult a qualified professional before filing or paying.
