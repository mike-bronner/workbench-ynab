---
description: Run a single proactive between-run YNAB monitoring pass on demand — reads the monitor state store, fetches fresh account balances, incremental transactions, and current-month categories through the vendored YNAB MCP, runs the four alert detectors (overdrawn, large/unusual transaction, budget overrun, bill due), dispatches any new finding, advances the snapshot, and exits silently when nothing is alert-worthy.
---

The user invoked `/workbench-ynab:ynab-monitor` to run one monitoring pass now.

## Execution

1. Read the `ynab-monitor` skill at `${CLAUDE_PLUGIN_ROOT}/skills/monitor/SKILL.md`
   and follow the monitoring-pass protocol end to end.
2. Run exactly **one** pass: read the prior snapshot → load the alerts config →
   fetch fresh YNAB data via the read tools named in
   `${CLAUDE_PLUGIN_ROOT}/skills/protocol/ynab-tools.md` (the
   `mcp__plugin_workbench-ynab_ynab__*` namespace) → run the four detectors →
   reconcile against the dedupe ledger → dispatch any new finding →
   `computeNextState` → `writeState`.
3. **Exit silently when nothing is alert-worthy.** A pass with no new finding
   advances `lastPollTimestamp` and the cursor but produces no notification and no
   alert-log append.

## Hard rules

- **Thresholds come from config only.** Every threshold the detectors apply is
  read from the `alerts` block of `config.json` — never hard-coded here.
- **Resolve YNAB tool names from the protocol skill** — never inline a concrete
  `mcp__plugin_workbench-ynab_ynab__ynab_*` name here.
- **One pass per invocation.** Re-invoke for another pass; the scheduled
  `ynab-monitor` task runs it on the configured cadence.
