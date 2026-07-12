---
name: annual-ynab-review
description: Run the annual YNAB review. Thin wrapper — all mechanics live in the universal `ynab-review` protocol; this sets `tier = annual` and defers. Full-tax-year readiness — YTD totals, the final itemize-vs-standard call, and a potential-missed-deductions sweep. Strictly read-only; not tax advice.
---

# YNAB Annual Review

This review follows the universal, read-only YNAB review protocol defined in
`${CLAUDE_PLUGIN_ROOT}/skills/review/ynab-review.md`. Every tier (weekly /
monthly / quarterly-tax / annual) runs **that** protocol; this wrapper only sets
the tier and notes the annual framing. No methodology lives here.

## Annual framing

The **full tax year**. The emphasis is end-of-year tax readiness: **YTD totals**,
the **final itemize-vs-standard** determination against `getStandardDeduction`,
and a **potential-missed-deductions sweep** across the year's classified spend.
All tax math is config-driven through the loaders — no hardcoded constants. See
the `annual` row of the protocol's tier matrix for exactly which of the 12
sections run (every section runs at full depth, including the tax summary).

## How to run this review

1. **Read the universal protocol** at `${CLAUDE_PLUGIN_ROOT}/skills/review/ynab-review.md`.
2. **Set `tier = annual`** when following the tier matrix in the protocol.
3. **Expect a plan block** from the `/ynab-review` router (M2-8), OR run the
   `ynab-orchestrator` agent yourself if invoked ad-hoc and filter its output to
   the **annual** tier only.
4. Follow every step in the universal protocol using the `annual` row of the
   tier matrix.

## Non-negotiables (reaffirmed, not redefined)

- **Read-only, always.** This review calls **read tools only** and never moves
  money. Write-back is the separate, approval-gated Sprint-4 path — not here.
- **Not tax advice.** This review surfaces tax-relevant signals for you and your
  tax professional; never present a classification or figure as a filing
  decision.
- **Namespaced tools only.** Every YNAB call goes through the
  `mcp__plugin_workbench-ynab_ynab__*` namespaced tools, resolved per the
  protocol's tool-loading step.

No additional annual-specific rules live here. If something feels like it should,
it belongs in the universal protocol.
