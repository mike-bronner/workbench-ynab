---
description: Update and show the quarterly estimated-tax tracker — pull YTD business income/expense from YNAB, compute the Schedule C net + SE tax + income-tax estimate from your tax profile, reconcile estimated payments already recorded in YNAB, persist the running YTD state, and print a per-quarter summary of estimated liability, payments made, and remaining due. Data-driven and idempotent. NOT tax advice.
---

The user has invoked `/workbench-ynab:ynab-tax`. Update the stateful quarterly
estimated-tax tracker for their side-hustle (Schedule C) earnings and print the
current YTD summary.

Run the **`estimated-tax` skill** ([`skills/estimated-tax/SKILL.md`](../skills/estimated-tax/SKILL.md))
end-to-end — it is canonical for the procedure, the libraries to call, the YNAB
tool namespacing, the milliunit→dollar discipline, and the idempotent
persistence. Do not re-implement the tax math here; the skill orchestrates the
tested `lib/tax/loadProfile.mjs` and `lib/tax/estimatedTax.mjs` modules.

## What this command does

1. Loads the effective tax profile; stops with the structured error if it is
   invalid (never produce a silently-wrong tax number).
2. Determines the target quarter (the quarter **today** falls in, unless the
   user names one — e.g. "Q2" or "second quarter" in `$ARGUMENTS`).
3. Fetches YTD business transactions via the namespaced YNAB tools, computes the
   cumulative Schedule C net / SE tax / marginal-bracket income tax, and derives
   the quarter's marginal liability.
4. Detects estimated-tax payments already in YNAB and reconciles them into the
   tracker (deduped by transaction id).
5. Idempotently upserts the quarter's estimate (re-running overwrites that
   quarter, preserving recorded payments) and saves
   `~/.claude/plugins/data/workbench-ynab-claude-workbench/tax-tracker.json`.
6. Prints the `## YTD Tax Summary` table: per-quarter estimated liability,
   payments made, and remaining due, with YTD totals.

## Rules

- **Read-only against YNAB.** This command only READS YNAB (list transactions /
  categories). It never writes to the budget; the only write is the local
  tracker state file.
- **Idempotent.** Running it twice in the same quarter overwrites that quarter's
  estimate rather than appending a duplicate, and never double-counts a payment
  already recorded.
- **Generic and data-driven.** Every rate, bracket, due date, and payment matcher
  comes from the tax profile — surface, don't invent, any value the profile is
  missing.
- **Not tax advice.** Close the summary with the standing reminder that this is
  an estimate from the user's own data, not professional tax advice.
