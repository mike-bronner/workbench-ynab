---
description: Run the quarterly estimated-tax YNAB review ad-hoc — orchestrator plans first, then the quarterly-tax tier-wrapper skill runs, forced to the quarterly-tax tier only. Strictly read-only. NOT tax advice.
---

The user invoked `/workbench-ynab:ynab-quarterly-tax-review`. Run the
**quarterly-tax** tier of the YNAB review on demand, regardless of what today's
schedule says.

## Phase 1 — Plan (orchestrator)

Resolve config and pre-warm the YNAB MCP exactly as the `/ynab-review` router's
Step 1 does: source `${CLAUDE_PLUGIN_ROOT}/bin/config.sh`, resolve the default
budget / `report_dir`, resolve the **required** `timezone` fail-closed via
`_cfg_timezone` (`timezone="$(_cfg_timezone)" || exit 1` — never the host clock),
and compute the authoritative `today` in that timezone via `_today_in_tz`, then best-effort pre-warm —
load the budgets-list read tool's deferred schema via `ToolSearch` (concrete
name from `${CLAUDE_PLUGIN_ROOT}/skills/protocol/ynab-tools.md`, the
`mcp__plugin_workbench-ynab_ynab__*` namespace) and make one discardable call.
Proceed on any warm-up error — never gate dispatch on it.

Dispatch the `ynab-orchestrator` agent **once**, ad-hoc, with:

```
budget_name: <from the default budgets entry>
today: <YYYY-MM-DD>
timezone: <tz>
report_dir: <resolved .report.output_dir>
review_scope: quarterly-tax
```

Parse the orchestrator's trailing YAML plan block. **Ad-hoc override:** ignore
the returned `plan.report.tiers` list and
force the execution tier to `quarterly-tax` — whatever the plan lists, this
command runs exactly one tier.
Keep everything else: the quarterly-tax `window` from `plan.report.reasons`,
`warnings`, and the rest of the plan block.

## Phase 2 — Surface warnings

If `plan.warnings` is non-empty, surface them exactly as the `/ynab-review`
router's Step 2 does: translate each into plain English (never dump raw YAML),
batch decisions into a single `AskUserQuestion`, honor the answer, and
never fabricate one if the user doesn't respond. If `warnings` is empty, proceed
silently.

## Phase 3 — Execute the quarterly-tax review

Read the quarterly-tax tier wrapper at
`${CLAUDE_PLUGIN_ROOT}/skills/review/quarterly-tax-ynab-review.md` and follow
it, handing over the plan block with `tier = quarterly-tax` and the plan's
quarterly-tax window. The wrapper defers to the universal protocol, which
writes the report and emits the dispatch summary.

## Hard rules

- **Read-only, always.** The orchestrator and the review call read tools only —
  mutation = bug. Write-back is the separate, approval-gated `/ynab-apply` path.
- **Namespaced tools only** — `mcp__plugin_workbench-ynab_ynab__*`, concrete
  names resolved from the protocol's tool list, never inlined here.
- **Quarterly-tax only.** Do not run other tiers, whatever the plan block
  lists — the unified `/ynab-review` router owns multi-tier runs.
- **Dispatch the orchestrator only once per run.**
- **No methodology lives here** — it all belongs in the universal protocol and
  the tier wrapper. That includes every tax figure: the review organizes data
  and surfaces signals; it is **not** tax advice.
