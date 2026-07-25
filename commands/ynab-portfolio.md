---
description: Run the cross-budget portfolio rollup — one consolidated report across every budget in your config - combined net worth, aggregate income vs spending, cross-budget Ready-to-Assign, a unified health score, and a single YTD tax picture across the business-tagged budgets. Strictly read-only. NOT tax advice.
---

The user invoked `/workbench-ynab:ynab-portfolio`. Produce **one consolidated
report across all configured budgets**, instead of N separate per-budget reviews
the user has to mentally sum.

## Phase 1 — Resolve the budget set and plan

Resolve config and pre-warm the YNAB MCP exactly as the `/ynab-review` router's
Step 1 does: source `${CLAUDE_PLUGIN_ROOT}/bin/config.sh`, resolve
`report_dir` / timezone, compute `today`, then best-effort pre-warm — load the
budgets-list read tool's deferred schema via `ToolSearch` (concrete name from
`${CLAUDE_PLUGIN_ROOT}/skills/protocol/ynab-tools.md`, the
`mcp__plugin_workbench-ynab_ynab__*` namespace) and make one discardable call.
Proceed on any warm-up error — never gate dispatch on it.

Then resolve the **budget set**, which is what makes this command different from
the single-budget tier commands:

- Read the full budgets array with `_cfg_budgets` and pass it through
  `selectBudgets` from `${CLAUDE_PLUGIN_ROOT}/assets/portfolio-rollup.js`.
- The `budgets` array **is** the enabled set. Never hardcode a budget id, name,
  or label here, and never repurpose `monitoring_enabled` / `write_back_enabled`
  (which gate the monitor and the write-back path) as a filter for this
  read-only report.
- **Zero included budgets** → stop and report the configuration problem; never
  render a rollup of nothing.

Dispatch the `ynab-orchestrator` agent **once per included budget** — never more
than once for the same budget — with:

```
budget_name: <that entry's budget_name, or the name resolved from its budget_id>
today: <YYYY-MM-DD>
timezone: <tz>
report_dir: <resolved .report.output_dir>
review_scope: portfolio
```

Parse each returned trailing YAML plan block and keep its `window`, `warnings`,
and `data_pull` — the orchestrator owns each budget's schedule and window; do not
recompute them.

## Phase 2 — Surface warnings

Pool the `plan.warnings` from every budget's plan block, plus the **excluded**
budgets `selectBudgets` reported (each with its named reason). If the pooled set
is non-empty, surface them exactly as the `/ynab-review` router's Step 2 does:
translate each into plain English (never dump raw YAML), tagged with the budget it
came from, batch decisions into a single `AskUserQuestion`, honor the answer, and
never fabricate one if the user doesn't respond. If the pooled set is empty,
proceed silently.

## Phase 3 — Execute the rollup

Read the rollup skill at
`${CLAUDE_PLUGIN_ROOT}/skills/review/portfolio-ynab-review.md` and follow it,
handing over the included budget entries and their plan blocks. The skill reuses
each budget's existing review output where one is available and fetches only what
is missing, aggregates through `assets/portfolio-rollup.js`, renders into the
frozen report template via `bin/report-writer.sh --tier Portfolio`, and emits the
dispatch summary.

## Hard rules

- **Read-only, always.** The orchestrator and the rollup call read tools only —
  mutation = bug. The rollup is additive: it modifies no budget's data,
  categories, or transactions. Write-back is the separate, approval-gated
  `/ynab-apply` path.
- **Namespaced tools only** — `mcp__plugin_workbench-ynab_ynab__*`, concrete
  names resolved from the protocol's tool list, never inlined here.
- **Every fetch is scoped to one `budget_id`.** Reuse an existing per-budget
  review output before re-fetching it.
- **Never sum across currencies.** Mixed-currency budgets get per-currency
  subtotals; the consolidated tax estimate is withheld rather than guessed.
- **One report, not N.** The whole point is a single consolidated view — the
  per-budget detail belongs in collapsible sections of that one report.
- **No methodology lives here** — it all belongs in the rollup skill, the
  universal protocol, and `assets/portfolio-rollup.js`. That includes every tax
  figure: the rollup organizes data and surfaces signals; it is **not** tax
  advice.
