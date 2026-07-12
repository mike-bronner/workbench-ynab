---
description: Run a single proactive between-run YNAB monitoring pass on demand — reads the monitor state store, fetches fresh account balances and incremental transactions through the vendored YNAB MCP, advances the snapshot, and exits silently when nothing changed. Scaffold only (M6-1): no alerts, no detectors.
---

The user invoked `/workbench-ynab:ynab-monitor` to run one monitoring pass now.

## Execution

1. Read the `ynab-monitor` skill at `${CLAUDE_PLUGIN_ROOT}/skills/monitor/SKILL.md`
   and follow the monitoring-pass protocol end to end.
2. Run exactly **one** pass: read the prior snapshot → fetch fresh YNAB data via
   the read tools named in `${CLAUDE_PLUGIN_ROOT}/skills/protocol/ynab-tools.md`
   (the `mcp__plugin_workbench-ynab_ynab__*` namespace) → `computeNextState` →
   `writeState`.
3. **Exit silently when nothing changed.** A no-op pass advances
   `lastPollTimestamp` and the cursor but produces no output.

## Hard rules

- **Scaffold only.** This pass dispatches **no alerts** and runs **no detector
  logic** — it updates the state store and surfaces the structured observation.
  Alerts are M6-2; detectors are M6-3.
- **Resolve YNAB tool names from the protocol skill** — never inline a concrete
  `mcp__plugin_workbench-ynab_ynab__ynab_*` name here.
- **One pass per invocation.** Re-invoke for another pass; the scheduled
  `ynab-monitor` task runs it on the configured cadence.
