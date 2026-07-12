---
name: ynab-monitor
description: Run one proactive between-run monitoring pass — read the monitor state store, fetch fresh YNAB account balances and incremental transactions through the vendored MCP, compare against the stored snapshot, and persist the advanced snapshot. The scaffold (M6-1) only updates state and surfaces a structured observation for future detectors; it dispatches no alerts and contains no detector logic. Use for the scheduled ynab-monitor task or an on-demand /workbench-ynab:ynab-monitor pass.
---

# YNAB proactive-monitor pass (M6-1 scaffold)

The weekly review (`/workbench-ynab:ynab-review`) runs once a week; between runs,
problems can go unnoticed for days. This skill runs a **single, cheap monitoring
pass** on a more frequent cadence (default daily). It is the **scaffold**: it
advances the monitor state store and surfaces a structured observation for the
detectors that land in **M6-3**. It **dispatches no alerts and contains no
detector logic** — a pass where nothing changed produces **no output at all**.

State primitives live in [`lib/monitor/state.mjs`](../../lib/monitor/state.mjs)
(read / compute-next / write / dedupe), and concrete YNAB tool names live in
[`skills/protocol/ynab-tools.md`](../protocol/ynab-tools.md) — resolve them from
there, never inline a name (see the one rule in
[`skills/protocol/SKILL.md`](../protocol/SKILL.md)).

## The state store

A single JSON snapshot, kept in the **plugin data dir** (NOT the repo) so it
survives plugin updates:

```
~/.claude/plugins/data/workbench-ynab-claude-workbench/monitor-state.json
```

It carries exactly these top-level fields (see `defaultState()` in the module):

| Field | Type | Meaning |
|---|---|---|
| `lastPollTimestamp` | ISO-8601 string \| null | When the last pass ran. |
| `accounts` | `{ [accountId]: { cleared, uncleared } }` | Per-account balances in **milliunits (integers)**. |
| `serverKnowledge` | integer \| null | YNAB delta cursor for cheap incremental transaction fetches. |
| `firedAlerts` | object keyed by stable condition key | Dedupe ledger so a condition is announced once. **M6-3 populates it**; the scaffold only carries the field and skips a key that already exists. |

**Money is stored in milliunits (integers); divide by 1000 only for display.**

## The pass — step by step

1. **Read the prior snapshot.** Invoke the module's `readState()`
   (`node` against `lib/monitor/state.mjs`). An absent file is a normal first run.

2. **Fetch fresh YNAB data through the vendored MCP.** Resolve the concrete tool
   names from [`skills/protocol/ynab-tools.md`](../protocol/ynab-tools.md) — all
   under the `mcp__plugin_workbench-ynab_ynab__*` namespace (never `mcp__ynab__*`):
   - the **`list_accounts`** read tool → current `cleared`/`uncleared` balances
     (milliunits) keyed by account id;
   - the **`list_transactions`** read tool → the incremental transaction window:
     - when `serverKnowledge` is present, pass it as the delta cursor so the MCP
       returns only what changed, and **persist the new cursor it returns**;
     - on a **first run** (no state file) or when `serverKnowledge` is `null`,
       fall back to fetching transactions **since `lastPollTimestamp`** (or a
       recent window on the very first run).

   The target budget comes from config (`budget.name` / `budget.id`) via
   `bin/config.sh`; monitor settings are never passed through the MCP.

3. **Compute the next snapshot.** Build the observation
   `{ timestamp, accounts, serverKnowledge?, recentTransactionCount }` (use the
   current time as `timestamp`) and call `computeNextState(prior, observation)`.
   It returns `{ state, changed, observation }`, where `observation` is the
   structured object — `{ accounts, recentTransactionCount }` — that **M6-3
   detectors will consume**.

4. **Persist** with `writeState(next)` — always, even on a no-op, so
   `lastPollTimestamp` and the cursor advance. The write is atomic (temp +
   rename).

5. **Decide output:**
   - `changed === false` → **exit silently.** No notification, no output. The
     snapshot and timestamp are already advanced.
   - `changed === true` → the scaffold still **does not alert**. It may surface
     the structured observation for a human or a future detector, but it raises
     no condition and writes no `firedAlerts` key. Detector + alert behaviour is
     **M6-2 / M6-3**, out of scope here.

## Hard rules for this scaffold

- **No detectors, no alerts.** This pass only updates state and surfaces the
  observation object. Do not add threshold/anomaly logic or notifications — those
  are M6-2 / M6-3.
- **Dedupe ledger is reserved.** `firedAlerts` exists from the start. The scaffold
  never writes a key; when M6-3 does, it must use `recordFiredAlert()`, which
  **skips a key that already exists** so a condition is never re-announced.
- **Milliunits everywhere in state.** Only divide by 1000 (`milliunitsToDollars`)
  for display/log output.
- **stdout discipline.** Any helper invoked on an MCP/JSON-RPC path sends
  diagnostics to **stderr only** — one stray stdout byte corrupts the handshake.

## Scheduled deployment (setup step)

The recurring `ynab-monitor` task is deployed by the **setup step** — today a
`/workbench-ynab:setup` re-run, following the unified-task pattern in
`workbench-bujo` (one task, cadence from config). Cadence is **config-driven**:
read `schedules.monitor` from `config.json` via `bin/config.sh`, applying the
defaults `cron = "0 8 * * *"` (daily 08:00) and `enabled = true` when absent.

- **When `schedules.monitor.enabled` is `true`:** deploy via
  `mcp__scheduled-tasks__create_scheduled_task` with
  - `taskId`: `ynab-monitor`
  - `description`: `YNAB proactive between-run monitoring poll`
  - `cronExpression`: `schedules.monitor.cron`
  - `prompt`: the resolved
    [`assets/prompt-templates/ynab-monitor.prompt.md`](../../assets/prompt-templates/ynab-monitor.prompt.md)

  If a task with id `ynab-monitor` already exists, call
  `mcp__scheduled-tasks__update_scheduled_task` to sync the cron and prompt —
  **idempotent on re-runs.**

- **When `schedules.monitor.enabled` is `false`:** remove the task with
  `mcp__scheduled-tasks__delete_scheduled_task` (or disable it if delete is
  unavailable).

In **all** cases the weekly-review task (`ynab-review`) is **never touched** —
`ynab-monitor` is a distinct task id.
