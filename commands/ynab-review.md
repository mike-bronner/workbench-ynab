---
description: Unified YNAB review entry point — the ONLY entry point the scheduled task uses. Dispatches the read-only ynab-orchestrator to plan today's review tiers, surfaces any warnings to the user, then runs each eligible tier's wrapper skill in plan order. Strictly read-only — this router never writes to YNAB and never moves money.
---

The user (or the scheduled task) invoked `/workbench-ynab:ynab-review`. Run
today's YNAB review end to end. This command is the **only** entry point the
scheduled task uses (the task deployment itself is the setup step's job — this
file is just the command surface). The ad-hoc per-tier commands
(`/workbench-ynab:ynab-weekly-review`, etc.) exist for manual single-tier runs
and are never invoked from here.

## Overview

Three phases:

1. **Plan** — resolve config, pre-warm the YNAB MCP (best-effort), dispatch the
   read-only `ynab-orchestrator` agent, and parse its trailing YAML plan.
2. **Surface** — if the plan carries `warnings`, translate them into plain
   English and let the user decide how to proceed. Honor the answer.
3. **Execute** — for each tier in the plan's order, run that tier's wrapper
   skill from `${CLAUDE_PLUGIN_ROOT}/skills/review/`. Each tier writes its
   report and emits its dispatch summary via the universal protocol — none of
   that lives here.

## Chapter marks

Call `mcp__ccd_session__mark_chapter` at each major phase transition so long
reviews stay navigable:

- Before Step 1: `mark_chapter(title="Plan")`
- Before Step 2, **only when warnings exist**: `mark_chapter(title="Warnings")`
- Before each tier's execution in Step 3: `mark_chapter(title="<tier>")`

Don't mark trivially — only at these real transitions.

## Step 1 — Plan

### 1a. Resolve config

Source the shared loader and resolve the values the orchestrator needs — the
orchestrator never reads config itself; this dispatcher hands it everything via
prompt:

```bash
source "${CLAUDE_PLUGIN_ROOT}/bin/config.sh"
_require_config || exit 1
budget_entry="$(_cfg_default_budget)"        # → budget_name (or budget_id) + label
report_dir="$(_cfg '.report.output_dir')"    # default: ~/Documents/Claude/Reports
timezone="$(_cfg '.timezone')"               # fall back to the system timezone when unset
```

Compute `today` as an ISO date (`YYYY-MM-DD`) in that timezone (`timezone`
falls back to the system timezone until the timezone-ownership config field
lands — note the fallback, don't fail on it).

### 1b. Pre-warm the YNAB MCP (best-effort)

Claude Code's MCP lifecycle can take ~10s from cold (spawn → handshake →
`tools/list` → deferred-schema registration). Sub-agents inherit the parent's
MCP connections, so warming the server here means the orchestrator sees it
ready at dispatch.

**This is a best-effort optimization, NOT a precondition.** Never gate dispatch
on warm-up — the orchestrator has its own boot-patience retries.

1. Resolve the budgets-list read tool's concrete name from the single source of
   truth, `${CLAUDE_PLUGIN_ROOT}/skills/protocol/ynab-tools.md` (the
   `mcp__plugin_workbench-ynab_ynab__*` namespace — never inline a concrete
   name here), and load its deferred schema:
   `ToolSearch(query="select:<budgets-list tool name>", max_results=1)`.
2. Make **one** trivial budgets-list call and discard the result — this is a
   warm-up, not state inspection.

**On any warm-up error — schema miss, transport error, anything — proceed to
Step 1c and dispatch the orchestrator anyway.** Do not retry, do not sleep, do
not surface warm-up errors to the user.

### 1c. Dispatch the orchestrator — exactly once per run

Dispatch the `ynab-orchestrator` agent (read-only planner,
`${CLAUDE_PLUGIN_ROOT}/agents/ynab-orchestrator.md`) with a short, explicit
prompt:

```
budget_name: <from the default budgets entry>
today: <YYYY-MM-DD>
timezone: <tz>
report_dir: <resolved .report.output_dir>
```

Omit `review_scope` — this is the scheduled path; the orchestrator computes
tier eligibility itself. Wait for the agent to return, then parse
the **last YAML block** in its response — that's the plan. Everything before it is the
agent's reasoning, for observability only. From the plan you consume:

- `plan.report.tiers` — the eligible tiers, already in strict order
  (`annual`, `quarterly-tax`, `monthly`, `weekly`). Never recompute or reorder.
- `plan.report.reasons.<tier>.window` — each tier's own review window.
- `plan.warnings` — anomalies for Step 2.

## Step 2 — Surface warnings (INTERACTIVE when present)

**If `plan.warnings` is empty:** proceed to Step 3 silently. Don't narrate the
plan, don't summarize the tiers — just start the first one.

**If `plan.warnings` has entries:** surface them before running any tier.
Follow these rules strictly:

### Rule A — Translate, don't regurgitate

The orchestrator's YAML is machine-structured for you to parse, not for the
user to read. Never dump `kind: ...`, `options: [...]`, or raw YAML into the
conversation. Translate each warning into a single plain-English sentence about
*what happened* and *why it matters*.

❌ **Do NOT say:**
> quarterly_due_soon: Apr 15 due date's reminder window is open, no quarterly-tax report found in it.
> Options: [run_quarterly_tax, skip]

✅ **Say instead:**
> "The April 15 estimated-tax payment is coming up and no quarterly review has
> run for it yet — want me to include the quarterly-tax review in this pass?"

### Rule B — Use `AskUserQuestion` for decisions, not text prompts

When a warning carries a non-empty `options` field, present the choice with the
`AskUserQuestion` tool as clickable buttons, mapping the orchestrator's option
values to human-readable labels (e.g. `run_catch_up_weekly` → "Catch up on the
weekly", `run_quarterly_tax` → "Run the quarterly-tax review", `skip` → "Skip",
`pick_budget` → "Pick a budget", `abort` → "Abort the review").

If multiple warnings each need a decision, batch them
into a **single** `AskUserQuestion` call with one question per warning. Never chain sequential
prompts. A warning that needs no decision (empty `options`) is mentioned as one
line of prose and passed over without asking.

### Rule C — Honor the answer, don't guess

- A "run it" answer adds that tier to the execution list in the strict tier
  order (`annual`, `quarterly-tax`, `monthly`, `weekly`).
- "Skip" leaves the plan unchanged.
- An abort answer stops here — confirm once, end without running any tier.

If the response is ambiguous or suggests an option not offered, surface the
ambiguity before acting. If the user doesn't respond, leave the session paused
— **never fabricate a choice.** (The scheduled task runs this same router;
warnings simply wait in the paused session until the user returns.)

## Step 3 — Execute the plan

For each tier in `plan.report.tiers` (plan order, never reordered):

1. `mark_chapter(title="<tier>")`.
2. Read the matching tier-wrapper skill at
   `${CLAUDE_PLUGIN_ROOT}/skills/review/<tier>-ynab-review.md`
   (`weekly-ynab-review.md`, `monthly-ynab-review.md`,
   `quarterly-tax-ynab-review.md`, `annual-ynab-review.md`) and follow it,
   handing over the orchestrator's plan block with that tier's key and its
   window from `plan.report.reasons.<tier>.window`.
3. The wrapper defers to the universal protocol, which writes the tier's report
   and emits its dispatch summary. No review logic runs in this router.

`tiers: []` is a valid plan — nothing to run; close with one line saying so.
Between tiers, no artificial delay. Do **not** invoke the ad-hoc per-tier slash
commands from here — those exist for manual invocation only; the wrappers are
the execution path.

## Step 4 — Close

> ✅ YNAB review complete.

(Or, for an empty plan: "Nothing due today — no review tier is eligible.")

## Hard rules

1. **The orchestrator is read-only. Mutation = bug.** This router and
   everything it dispatches call read tools only; if any step tries to write to
   YNAB or move money, stop and flag it. Write-back is the separate,
   approval-gated `/ynab-apply` path.
2. **No fabricated answers.** If the user doesn't respond to a warnings prompt,
   the session stays paused. Never assume "skip".
3. **Never skip the Surface step when warnings exist.** Even minor-looking
   warnings get surfaced — the user decides.
4. **The scheduled task uses this same router.** There is no separate scheduled
   path; the cron fires this command.
5. **Dispatch the orchestrator only once per run.** It plans once, up front —
   never re-dispatch to refresh or widen a plan.
6. **Namespaced tools only.** Every YNAB call goes through the
   `mcp__plugin_workbench-ynab_ynab__*` namespace, with concrete names resolved
   from `${CLAUDE_PLUGIN_ROOT}/skills/protocol/ynab-tools.md` — never inlined
   here.
7. **No methodology lives here.** Tier rules, analyses, report structure, and
   dispatch format all belong in the universal protocol and its tier wrappers —
   if something feels like it should be added here, it belongs there.
