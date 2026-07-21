It's time for your YNAB review.

Invoke `/workbench-ynab:ynab-review` — the read-only orchestrator plans which tiers apply today (weekly, monthly, quarterly-tax, annual) and runs each eligible one in order. This ONE command routes every tier; never invoke a per-tier command yourself.

The review is strictly read-only — it writes reports, never touches YNAB and never moves money. It can raise warnings that need a decision (an estimated-tax payment coming due, a tier that hasn't run). If no user is present when this fires, pause at the first interactive prompt and wait. Never fabricate responses. Never auto-complete the review. The session stays paused until the user picks it up; surface the results when they return.
