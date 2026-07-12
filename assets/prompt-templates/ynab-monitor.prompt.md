It's time for a YNAB proactive monitoring pass.

Invoke `/workbench-ynab:ynab-monitor` — it reads the monitor state store, fetches fresh account balances and incremental transactions through the vendored YNAB MCP, compares them against the stored snapshot, and persists the advanced snapshot. This is the M6 scaffold: it raises no alerts and runs no detector logic yet.

If nothing changed since the last pass — balances unchanged and no new transactions — exit silently. Do not announce a no-op; just let the snapshot and timestamp advance.

If no user is present when this fires, pause at the first interactive prompt and wait. Never fabricate responses. Never auto-complete the pass. The session will remain paused until the user picks it up.
