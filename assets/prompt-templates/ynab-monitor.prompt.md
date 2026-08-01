It's time for a YNAB proactive monitoring pass.

Invoke `/workbench-ynab:ynab-monitor` — it reads the monitor state store, loads the alert thresholds, fetches fresh account balances, incremental transactions, and current-month categories through the vendored YNAB MCP, runs the four alert detectors (overdrawn, large/unusual transaction, budget overrun, bill due), dispatches any new finding, and persists the advanced snapshot and dedupe ledger.

If nothing is alert-worthy this pass — no new finding — exit silently. Do not announce a no-op; just let the snapshot and timestamp advance.

If no user is present when this fires, pause at the first interactive prompt and wait. Never fabricate responses. Never auto-complete the pass. The session will remain paused until the user picks it up.
