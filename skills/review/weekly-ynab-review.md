---
name: weekly-ynab-review
description: Run the weekly YNAB financial review. Thin wrapper — all mechanics live in the universal `ynab-review` protocol; this sets `tier = weekly` and defers. The proven default: a fast 7-day hygiene pass plus carryover uncategorized, the validated baseline the prototype has run since April 2026. Strictly read-only.
---

# YNAB Weekly Review

This review follows the universal, read-only YNAB review protocol defined in
`${CLAUDE_PLUGIN_ROOT}/skills/review/ynab-review.md`. Every tier (weekly /
monthly / quarterly-tax / annual) runs **that** protocol; this wrapper only sets
the tier and notes the weekly framing. No methodology lives here.

## Weekly framing

The proven default — the validated baseline the prototype has run since April
2026. A fast hygiene pass over the **past 7 days plus carryover uncategorized**
(uncategorized transactions from before the window still surface): catch
uncategorized, stale-uncleared, duplicates, and overspend early. Depth is
condensed and the tax roll-up is skipped — see the `weekly` row of the protocol's
tier matrix for exactly which of the 12 sections run.

## How to run this review

1. **Read the universal protocol** at `${CLAUDE_PLUGIN_ROOT}/skills/review/ynab-review.md`.
2. **Set `tier = weekly`** when following the tier matrix in the protocol.
3. **Expect a plan block** from the `/ynab-review` router (M2-8), OR run the
   `ynab-orchestrator` agent yourself if invoked ad-hoc and filter its output to
   the **weekly** tier only.
4. Follow every step in the universal protocol using the `weekly` row of the
   tier matrix.

## Non-negotiables (reaffirmed, not redefined)

- **Read-only, always.** This review calls **read tools only** and never moves
  money. Write-back is the separate, approval-gated Sprint-4 path — not here.
- **Namespaced tools only.** Every YNAB call goes through the
  `mcp__plugin_workbench-ynab_ynab__*` namespaced tools, resolved per the
  protocol's tool-loading step.

No additional weekly-specific rules live here. If something feels like it should,
it belongs in the universal protocol.
