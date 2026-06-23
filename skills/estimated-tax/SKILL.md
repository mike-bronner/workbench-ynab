---
name: estimated-tax
description: The M6-4 quarterly estimated-tax tracker — a stateful, data-driven YTD estimate of what is owed on side-hustle (Schedule C) earnings, plus the record of estimated payments already made and the resulting remaining liability per quarter. Pulls YTD business income/expense from YNAB, computes Schedule C net + SE tax + marginal-bracket income tax entirely from the tax profile (no hardcoded rates), detects estimated-tax payments already recorded in YNAB and reconciles them, and persists everything to an out-of-repo tax-tracker.json that survives plugin updates. Exposes a read-only "## YTD Tax Summary" the weekly review embeds without re-running any YNAB query or tax math. Invoked by the /ynab-tax command. NOT tax advice.
---

# Estimated-tax tracker — workbench-ynab (M6-4)

Promotes the prototype's regenerated "quarterly estimated tax" paragraph into a
**first-class, stateful tracker**. One run computes a running YTD estimate of the
tax owed on Schedule C earnings, reconciles the estimated payments already in
YNAB, and writes the result to a persistent state file. Everything is **generic
and data-driven**: every rate, bracket, threshold, due date, and payment-matcher
comes from the tax profile — nothing about one taxpayer is hardcoded here.

> **Not tax advice.** This estimates side-hustle estimated taxes from your own
> YNAB data and your own tax profile. It is not a substitute for professional
> tax advice.

## The two libraries this skill orchestrates

This skill is the **orchestration half** — it fetches YNAB data and calls the
tested compute libraries; it does not re-implement tax math inline.

- [`lib/tax/loadProfile.mjs`](../../lib/tax/loadProfile.mjs) — the effective tax
  profile (bundled US defaults merged with the user's instance), with accessors
  `getThreshold('seTaxRate')`, `getIncomeTaxBrackets(year, status)`,
  `getQuarterlyDueDates(year)`, and `getEstimatedTaxPaymentMatchers()`.
- [`lib/tax/estimatedTax.mjs`](../../lib/tax/estimatedTax.mjs) — the tax math
  (`summarizeBusinessActivity`, `computeEstimate`, `quarterlyEstimate`) plus the
  tracker state (`loadTracker`, `upsertQuarterEstimate`, `detectPayments`,
  `reconcilePayments`, `saveTracker`, `renderYtdSummary`). It REUSES the mapping
  engine ([`classifyTransaction.mjs`](../../lib/tax/classifyTransaction.mjs)) to
  decide which transactions are business income vs deductible expense.

## YNAB namespacing — read this first

Every YNAB read uses the **vendored, namespaced** `mcp__plugin_workbench-ynab_ynab__*`
tool family — NOT a bare `mcp__ynab__*`. The concrete tool names live in their
single source of truth, [`../protocol/ynab-tools.md`](../protocol/ynab-tools.md)
(see the [capability map](../../docs/mcp-capability-map.md) for the why); this
skill references the **logical read operations** — list-transactions,
list-categories, get-month — and reads their concrete names from there rather
than inlining them.

The third-party YNAB MCP **cannot read the tax profile** — this skill reads it
directly from the data dir via `loadProfile`.

## Money units — dollars, not milliunits

YNAB returns amounts in **milliunits** (1000 milliunits = $1). The compute
library divides by 1000 to dollars before any arithmetic; every figure stored in
the tracker and read from the profile is already in dollars. Never compare a raw
milliunit amount against a profile or tracker number.

## Procedure

1. **Load the tax profile.** Run `loadProfile()`. If it returns `ok: false`,
   stop and surface the structured error (a half-valid profile must never
   produce a silently-wrong tax number). Note `taxYear` and `filingStatus`.

2. **Pick the target quarter.** Default to the quarter that **today** falls in,
   resolved via `quarterForDate(today, profile.quarterlyEstimatedDueDates)`. The
   command may pass an explicit quarter.

3. **Fetch YTD business transactions** for the tax year with the list-transactions
   read tool (since `${taxYear}-01-01`; concrete name in
   [`../protocol/ynab-tools.md`](../protocol/ynab-tools.md)). Pass the raw
   transactions straight into the library — it normalizes YNAB's snake_case
   fields itself.

4. **Compute the cumulative estimate at two cutoffs** using
   `summarizeBusinessActivity(transactions, profile, { sinceISO, throughISO })`
   and `computeEstimate({ grossIncome, deductibleExpenses, seRate, brackets, meta })`:
   - `seRate` = `getThreshold('seTaxRate')`; `brackets` = `getIncomeTaxBrackets()`.
   - `throughISO` for the **target quarter's** income-period end (capped at
     today), and again for the **prior quarter's** period end.
   - Derive the quarter figure with
     `quarterlyEstimate(cumulativeThis, cumulativePrior)` — its `quarterLiability`
     is the marginal tax on that quarter's income; the full snapshot rides along
     as the explainable `computed_inputs`.

5. **Detect & reconcile estimated-tax payments.**
   `detectPayments(transactions, getEstimatedTaxPaymentMatchers(), profile.quarterlyEstimatedDueDates)`
   finds outflows that look like estimated-tax payments (IRS/EFTPS payee or a
   configured category/account) and attributes each to the quarter it pays toward
   by the **due-date schedule** (a payment on or before a quarter's due date
   belongs to that quarter, including the Jan-15 rollover to the prior tax year's
   Q4 — not the income window). Each detected payment also carries its own
   `tax_year`, so a Jan 1–15 payment is tagged as the **prior** year's Q4.
   `reconcilePayments(state, { year, payments })` then files **only** the payments
   whose `tax_year` matches `year`, **deduped by `ynab_transaction_id`**, and
   recomputes `remaining_due` — so the unbounded `since`-only pull (step 3) never
   contaminates one tax year with the next year's payments.

6. **Upsert idempotently and save.**
   `upsertQuarterEstimate(state, { year, quarter, estimate })` overwrites that
   quarter's estimate (re-running never appends a duplicate) while **preserving
   recorded payments**, then `saveTracker(state)` writes
   `~/.claude/plugins/data/workbench-ynab-claude-workbench/tax-tracker.json`
   (created on first run, survives plugin updates).

7. **Render the summary.** Return `renderYtdSummary(state, { year })` — a
   human-readable per-quarter table of estimated liability, payments, and
   remaining due, plus the YTD totals.

## The "## YTD Tax Summary" export contract

`renderYtdSummary` reads **only** the state file — no YNAB query, no tax math. It
is the read-only export the weekly-review skill
([`skills/review/ynab-review.md`](../review/ynab-review.md)) can embed by calling
`renderYtdSummary` against the saved tracker, so that once that wiring lands (the
report-side change is deferred M2/M3 work) the review need not recompute the
estimate (the token-waste the brief called out). Run `/ynab-tax` to refresh the
tracker; the review reads whatever is current.

## Tracker state shape

```jsonc
{
  "schemaVersion": 1,
  "years": {
    "2025": {
      "1": {
        "estimated_liability": 0,              // this quarter's marginal liability (USD)
        "payments": [                          // estimated payments reconciled from YNAB
          { "date": "2025-04-15", "amount_usd": 0, "ynab_transaction_id": "…" }
        ],
        "remaining_due": 0,                    // liability − payments (never below 0)
        "computed_inputs": { /* scheduleCNet, seTax, halfSeDeduction, incomeTax, brackets snapshot, … */ }
      }
      // "2", "3", "4" …
    }
  }
}
```

Keeping the full `computed_inputs` is deliberate — the estimate must be
explainable straight from stored data, so the report and any reminder can show
the work without recomputing.
