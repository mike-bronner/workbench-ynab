---
name: monthly-ynab-review
description: Run the monthly YNAB financial review. Thin wrapper — all mechanics live in the universal `ynab-review` protocol; this sets `tier = monthly` and defers. Covers the full prior calendar month with deeper budget-health and forecast emphasis plus a condensed tax roll-up. Strictly read-only.
---

# YNAB Monthly Review

This review follows the universal, read-only YNAB review protocol defined in
`${CLAUDE_PLUGIN_ROOT}/skills/review/ynab-review.md`. Every tier (weekly /
monthly / quarterly-tax / annual) runs **that** protocol; this wrapper only sets
the tier and notes the monthly framing. No methodology lives here.

## Monthly framing

The full **prior calendar month**. Where weekly is a fast hygiene pass, monthly
goes deeper on **budget health and forecast** — overspend and funding gaps,
goal/target progress, and the cash-flow/net-worth projection — with a condensed
tax roll-up. See the `monthly` row of the protocol's tier matrix for exactly
which of the 12 sections run and over what window.

## How to run this review

1. **Read the universal protocol** at `${CLAUDE_PLUGIN_ROOT}/skills/review/ynab-review.md`.
2. **Set `tier = monthly`** when following the tier matrix in the protocol.
3. **Expect a plan block** from the `/ynab-review` router (M2-8), OR run the
   `ynab-orchestrator` agent yourself if invoked ad-hoc and filter its output to
   the **monthly** tier only.
4. Follow every step in the universal protocol using the `monthly` row of the
   tier matrix.

## Non-negotiables (reaffirmed, not redefined)

- **Read-only, always.** This review calls **read tools only** and never moves
  money. Write-back is the separate, approval-gated Sprint-4 path — not here.
- **Namespaced tools only.** Every YNAB call goes through the
  `mcp__plugin_workbench-ynab_ynab__*` namespaced tools, resolved per the
  protocol's tool-loading step.

No additional monthly-specific rules live here. If something feels like it
should, it belongs in the universal protocol.
