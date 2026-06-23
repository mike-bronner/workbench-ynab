---
name: quarterly-tax-ynab-review
description: Run the quarterly tax YNAB review. Thin wrapper — all mechanics live in the universal `ynab-review` protocol; this sets `tier = quarterly-tax` and defers. Quarter-to-date Schedule C P&L and estimated-payment focus anchored on the config's quarterly due dates, with a running itemize-vs-standard comparison. Strictly read-only; not tax advice.
---

# YNAB Quarterly Tax Review

This review follows the universal, read-only YNAB review protocol defined in
`${CLAUDE_PLUGIN_ROOT}/skills/review/ynab-review.md`. Every tier (weekly /
monthly / quarterly-tax / annual) runs **that** protocol; this wrapper only sets
the tier and notes the quarterly-tax framing. No methodology lives here.

## Quarterly-tax framing

The **quarter to date**, anchored on the configured quarterly due dates. The
emphasis is tax: **Schedule C YTD P&L** (business net) and **estimated-payment
focus** aligned to `getQuarterlyDueDates(year)`, plus a **running
itemize-vs-standard comparison** against `getStandardDeduction`. All tax math is
config-driven through the loaders — no hardcoded constants. See the
`quarterly-tax` row of the protocol's tier matrix for exactly which of the 12
sections run (the tax summary is mandatory here; the hygiene sections condense).

## How to run this review

1. **Read the universal protocol** at `${CLAUDE_PLUGIN_ROOT}/skills/review/ynab-review.md`.
2. **Set `tier = quarterly-tax`** when following the tier matrix in the protocol.
3. **Expect a plan block** from the `/ynab-review` router (M2-8), OR run the
   `ynab-orchestrator` agent yourself if invoked ad-hoc and filter its output to
   the **quarterly-tax** tier only.
4. Follow every step in the universal protocol using the `quarterly-tax` row of
   the tier matrix.

## Non-negotiables (reaffirmed, not redefined)

- **Read-only, always.** This review calls **read tools only** and never moves
  money. Write-back is the separate, approval-gated Sprint-4 path — not here.
- **Not tax advice.** This review surfaces tax-relevant signals for you and your
  tax professional; never present a classification or figure as a filing
  decision.
- **Namespaced tools only.** Every YNAB call goes through the
  `mcp__plugin_workbench-ynab_ynab__*` namespaced tools, resolved per the
  protocol's tool-loading step.

No additional quarterly-tax-specific rules live here. If something feels like it
should, it belongs in the universal protocol.
