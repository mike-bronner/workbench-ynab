It's time for your YNAB review.

Invoke `/workbench-ynab:ynab-review` — the read-only orchestrator plans which tiers apply today (weekly, monthly, quarterly-tax, annual) and runs each eligible one in order. This ONE command routes every tier; never invoke a per-tier command yourself.

The review's date math is timezone-sensitive, so supply the authoritative `today` computed in the **configured timezone** (`config.timezone`) to the orchestrator — the command resolves it and computes `today` in that zone before dispatch. Do **not** rely on the shell environment's default locale or `TZ`: a scheduled run must agree with an interactive run on the same day. If the configured timezone is missing or invalid the command stops with an error rather than guessing from the host clock.

The review is strictly read-only — it writes reports, never touches YNAB and never moves money. It can raise warnings that need a decision (an estimated-tax payment coming due, a tier that hasn't run). If no user is present when this fires, pause at the first interactive prompt and wait. Never fabricate responses. Never auto-complete the review. The session stays paused until the user picks it up; surface the results when they return.
