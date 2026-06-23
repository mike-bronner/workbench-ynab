# Estimated-tax tracker

The **estimated-tax tracker** (issue #82, M6-4) promotes the prototype's
regenerated "quarterly estimated tax" paragraph into a first-class, **stateful**
record: a running YTD estimate of what is owed on side-hustle (Schedule C)
earnings, the estimated payments already made, and the resulting remaining
liability per quarter. The tax logic is **generic and data-driven** — every rate,
bracket, due date, and payment matcher comes from the tax profile
([`assets/tax/`](../assets/tax/)), never from one taxpayer's hard-coded numbers.

> **Not tax advice.** This estimates side-hustle estimated taxes from your own
> YNAB data and your own tax profile. It is not a substitute for professional
> tax advice.

## Pieces

| Piece | Path | Role |
| --- | --- | --- |
| Engine | [`lib/tax/estimatedTax.mjs`](../lib/tax/estimatedTax.mjs) | Pure tax math + tracker state I/O. |
| Skill | [`skills/estimated-tax/SKILL.md`](../skills/estimated-tax/SKILL.md) | Orchestrates: fetch YNAB → compute → reconcile → persist. |
| Command | [`commands/ynab-tax.md`](../commands/ynab-tax.md) | `/workbench-ynab:ynab-tax` entry point. |
| Profile loader | [`lib/tax/loadProfile.mjs`](../lib/tax/loadProfile.mjs) | Supplies brackets, SE rate, due dates, payment matchers. |
| Mapping engine | [`lib/tax/classifyTransaction.mjs`](../lib/tax/classifyTransaction.mjs) | Decides which transactions are business income vs deductible expense. |

## Where the state lives

The tracker is read and written by the **skill**, never by the vendored YNAB MCP,
so — like the tax profile — it lives outside the repo and survives plugin
updates:

```
~/.claude/plugins/data/workbench-ynab-claude-workbench/tax-tracker.json
```

The file is **created on first run** of `/ynab-tax`. Path resolution mirrors the
profile loader: `options.trackerPath` → env `YNAB_TAX_TRACKER_FILE` →
`<dataDir>/tax-tracker.json`, where `dataDir` is `options.dataDir` → env
`YNAB_DATA_DIR` → the canonical plugin-data dir.

## State shape

One object per tax year; each year holds the Q1–Q4 entries:

```jsonc
{
  "schemaVersion": 1,
  "years": {
    "2025": {
      "1": {
        "estimated_liability": 1234.56,        // this quarter's MARGINAL liability (USD)
        "payments": [
          { "date": "2025-04-15", "amount_usd": 1000.00, "ynab_transaction_id": "abc-123" }
        ],
        "remaining_due": 234.56,               // max(0, liability − payments)
        "computed_inputs": {                   // the snapshot that produced the estimate
          "grossIncome": 40000, "deductibleExpenses": 10000,
          "scheduleCNet": 30000, "seTaxRate": 0.153, "seTax": 4590,
          "halfSeDeduction": 2295, "incomeTaxBase": 27705, "incomeTax": 2847.6,
          "totalLiability": 7437.6,
          "priorCumulativeLiability": 0, "quarterLiability": 7437.6,
          "taxYear": 2025, "filingStatus": "mfj"
        }
      }
      // "2", "3", "4"
    }
  }
}
```

`computed_inputs` is kept in full **so the estimate is explainable straight from
stored data** — the report and any reminder can show the work without
recomputing.

## The estimate model

All inputs are data-driven (profile/config); the engine hardcodes none of them.

```
scheduleCNet    = grossIncome − deductibleExpenses
seTax           = max(0, scheduleCNet) × seTaxRate          (profile thresholds.seTaxRate)
halfSeDeduction = seTax ÷ 2                                  (applied BEFORE income tax)
incomeTaxBase   = max(0, scheduleCNet − halfSeDeduction)
incomeTax       = marginal brackets applied to incomeTaxBase (profile incomeTaxBracketsByYear)
totalLiability  = seTax + incomeTax
```

Per-quarter, the **marginal** liability is the cumulative liability through that
quarter's income-attribution period minus the cumulative liability through the
prior quarter's — exactly what a quarterly estimated payment covers. The uneven
quarter boundaries (Q1 Jan–Mar, Q2 Apr–May, Q3 Jun–Aug, Q4 Sep–Dec) are stored
as `period*` fields on `quarterlyEstimatedDueDates`, adjustable for IRS calendar
shifts.

The **standard deduction is intentionally not subtracted** here: this estimates
the tax on side-hustle earnings stacked on top of other (already
deduction-absorbing) household income, so the brackets apply from the first
dollar of net. It is a conservative working estimate, not a filed return.

## Idempotency & reconciliation

- **Re-running `/ynab-tax` in the same quarter overwrites that quarter's
  estimate** (`estimated_liability` + `computed_inputs`) rather than appending a
  duplicate, while **preserving the recorded payments**.
- **Estimated-tax payments already in YNAB are auto-detected** from the profile's
  `estimatedTaxPayments` matchers (an outflow whose payee contains a configured
  keyword — IRS / EFTPS by default — or whose category / group / account matches
  a configured name) and reconciled into the quarter they pay toward by the
  **due-date schedule** (a payment on or before a quarter's due date belongs to
  that quarter — including the Jan-15 rollover that attributes to the prior tax
  year's Q4, which the income windows alone would miss), **deduped by
  `ynab_transaction_id`** so re-running never double-counts.
- **Payments are bounded to their own tax year.** Each detected payment is tagged
  with the `tax_year` it belongs to (a Jan 1–15 payment rolls back to the prior
  year's Q4), and a reconcile run files **only** the payments matching that run's
  year. So a year's transaction pull spilling across the calendar boundary never
  contaminates one tax year with the next year's (or prior year's) payments.

## The `## YTD Tax Summary` export

`renderYtdSummary(state, { year })` returns a markdown table read **purely from
the state file** — no YNAB query, no tax math. It is the read-only export the
weekly-review skill can embed by reference so that, once wired in (that report
change is deferred M2/M3 work), the review need never recompute the estimate (the
token waste the brief flagged). Run `/ynab-tax` to refresh the tracker; the review
reads whatever is current.
