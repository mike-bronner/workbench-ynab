---
name: portfolio-ynab-review
description: The cross-budget portfolio rollup (M6-7). Runs — or reuses — the per-budget review across every budget in the multi-budget config and consolidates them into ONE report - combined net worth, aggregate income vs spending, cross-budget Ready-to-Assign, a unified health score, and a single YTD tax picture aggregated across the business-tagged budgets. Renders into the same frozen HTML template as every other report, with collapsible per-budget detail. Strictly read-only; not tax advice.
---

# YNAB portfolio rollup — cross-budget review

> ## 🔒 READ-ONLY. This skill never writes to YNAB and never moves money.
> The rollup is **additive**: it reads each budget and reports. It must never
> call a write verb (`update` / `create` / `delete` / `reconcile` — see the write
> tools in [`../protocol/ynab-tools.md`](../protocol/ynab-tools.md)) and never
> modifies a budget's data, categories, or transactions. Write-back is the
> separate, approval-gated `/ynab-apply` path — **not** this skill.
>
> **Not tax advice.** The consolidated tax view organizes your own data and
> surfaces tax-relevant signals for you and your tax professional. It is not a
> substitute for professional tax advice, and no figure here is a filing decision.

A user with a personal budget and a business budget should not have to mentally
sum N separate reports. This skill sits **on top of** the per-budget reviews: the
universal protocol ([`ynab-review.md`](./ynab-review.md)) still owns the
12-section analysis of any single budget, and this skill owns only the
**consolidation** — what is true across all of them.

The cross-budget arithmetic is **not** improvised in prose. It lives in the
dependency-free module
[`../../assets/portfolio-rollup.js`](../../assets/portfolio-rollup.js)
(`selectBudgets`, `businessBudgets`, `aggregatePortfolio`, `aggregateScheduleC`,
`orderFindings`), unit-tested by
[`../../tests/unit/portfolio-rollup.test.mjs`](../../tests/unit/portfolio-rollup.test.mjs).
Call it; never re-implement a sum, a conversion, or a ranking inline.

---

## 1. Resolve the budget set from config — never hardcode a budget

The budgets in scope come **only** from the multi-budget config (M6-6), read
through the shared loader. No budget id, budget name, or label appears in this
file or in any fragment template.

```bash
source "${CLAUDE_PLUGIN_ROOT}/bin/config.sh"
_require_config || exit 1
budgets_json="$(_cfg_budgets)"      # the full budgets array, legacy-migrated
report_dir="$(_cfg '.report.output_dir')"
```

`_cfg_budgets` already applies the schema-v1 → multi-budget migration, so a
single-budget user yields a one-entry array and the rollup degrades to a
one-budget report rather than failing.

Pass that array to `selectBudgets(budgets)`:

- **The `budgets` array IS the enabled set.** The config schema defines it as
  "the YNAB budgets this plugin operates on". The two per-budget booleans it
  carries — `monitoring_enabled` and `write_back_enabled` — gate the monitoring
  poll and the write-back path respectively; neither gates this read-only report,
  and neither may be repurposed here.
- Each entry's **`role`** is its tag (`personal`, `business`, `archive`, …),
  matched case-insensitively. `role` groups the report and selects the Schedule C
  set in [§4](#4-consolidated-tax-view--one-ytd-picture).
- **`included`** are the entries the rollup reads. **`excluded`** are malformed
  entries (missing `label` / `role` / both budget references), each with a named
  reason. Never silently drop an excluded budget — a dropped budget understates
  every total, so surface each one as a dispatch note (see [§6](#6-dispatch-summary)).
- **Zero included budgets is a stop, not an empty report.** Emit the configuration
  error and the `no_budgets` note; do not render a rollup of nothing.

Per-budget overrides (`business_category_group`, `tax_profile_path`) are read with
`_cfg_budget_field "$label" "$field"` — again by label from config, never inlined.

---

## 2. Get each budget's data — reuse before you re-fetch

For every included budget, you need one **snapshot**. Prefer the cheapest source
that is current:

1. **Reuse an existing per-budget review output** when one is available for this
   run (a per-budget analysis already produced in this session, or a cached
   fragment set the multi-budget path made available). Reusing costs no tokens and
   no API calls, and it keeps the rollup consistent with the per-budget reports the
   user already has.
2. **Otherwise fetch**, scoping every call to that entry's **`budget_id`** (resolve
   it from `budget_name` via the budget-list read op when the entry carries only a
   name). One budget at a time — never a call that silently spans budgets.

Load the read-tool schemas exactly as the universal protocol's §2 does — one
batched `ToolSearch` over the **Read tools** list in
[`../protocol/ynab-tools.md`](../protocol/ynab-tools.md), the
`mcp__plugin_workbench-ynab_ynab__*` namespace, with the same boot-patience
gotchas. **Never inline a concrete tool name here**; reference the logical read
ops (`list_budgets`, `list_accounts`, `list_categories`, `list_transactions`,
`get_month`) per the universal protocol's §3 tool-boundary table, and never a
write verb.

Read each budget's `currency_format` from the budget-list read with
**`response_format: "json"`** — mandatory, for exactly the reason the universal
protocol's §5 gives: the markdown renderer emits only `iso_code`, and the rollup
needs the full object to render a non-USD budget correctly.

### The snapshot shape the rollup consumes

Amounts stay in **raw milliunits** in the snapshot. The conversion happens once,
inside the module — see [§3](#3-aggregate).

```jsonc
{
  "label": "…", "role": "…",          // from the config entry
  "currency_format": { /* … */ },      // that budget's own, from the JSON read
  "netWorthMilli": 0,                  // combined on- + off-budget balances
  "incomeMilli": 0, "spendingMilli": 0,// inflow / outflow over the window
  "readyToAssignMilli": null,          // from get_month; null when there is no data
  "healthSubScores": [ /* six 1–10 sub-scores or nulls */ ]
}
```

The six health sub-scores are the universal protocol's §9 sub-scores, computed
per budget through the shared guards
([`../../assets/review-guards.js`](../../assets/review-guards.js)) — a sub-score
with no data is `null`, never a masking `0`.

---

## 3. Aggregate

```js
const { aggregatePortfolio, aggregateScheduleC, businessBudgets, orderFindings }
  = require('assets/portfolio-rollup.js');
const portfolio = aggregatePortfolio(snapshots);
```

`aggregatePortfolio` returns the four required dimensions:

| Dimension | Where it lands |
|---|---|
| **Combined account balances / net worth** | `totals[iso].netWorth` |
| **Aggregate income vs spending** (and net cash flow) | `totals[iso].income` / `.spending` / `.netCashFlow` |
| **Cross-budget Ready-to-Assign** | `totals[iso].readyToAssign` |
| **Unified health score** | `healthScore` (0–100, or `null`) |

Three rules the module enforces and the rendering must respect:

- **Milliunits are converted exactly once, at intake.** Every returned figure is
  already in currency units. Never divide a returned total by 1000 again, and never
  add a raw milliunit amount to one.
- **Currencies are never merged.** Totals are keyed by ISO code. When
  `mixedCurrency` is true, render **per-currency subtotals** — one KPI row per
  currency — and carry the `mixed_currency` note; never present a single summed
  figure across currencies. Format each with
  [`../../assets/format-money.js`](../../assets/format-money.js) `formatMoney` and
  that currency's own `currencyFormats[iso]`.
- **`null` is the n/a sentinel.** A `null` total or health score renders `n/a`; a
  `null` health score renders **without** a `role="meter"` gauge (a meter needs a
  numeric value), per the a11y contract in
  [`../../assets/report/SLOTS.md`](../../assets/report/SLOTS.md).

---

## 4. Consolidated tax view — one YTD picture

Select the tax set with `businessBudgets(included)` — the entries whose `role` is
`business` — and aggregate their Schedule C activity into **one** set of figures:

```js
const scheduleC = aggregateScheduleC(businessSnapshots);
```

Each business snapshot carries `scheduleCIncomeMilli` / `scheduleCExpensesMilli`,
classified per budget by the existing mapping engine
([`../../lib/tax/classifyTransaction.mjs`](../../lib/tax/classifyTransaction.mjs))
against that budget's own tax profile (`tax_profile_path` override, else the
default) — the rollup classifies nothing itself.

Feed the aggregate — not per-budget fragments — into the **M6-4 tracker**
([`../estimated-tax/SKILL.md`](../estimated-tax/SKILL.md),
[`../../lib/tax/estimatedTax.mjs`](../../lib/tax/estimatedTax.mjs)):

`computeEstimate({ grossIncome: scheduleC.grossIncome, deductibleExpenses:
scheduleC.deductibleExpenses, seRate: getThreshold('seTaxRate'), brackets:
getIncomeTaxBrackets() })`, then `quarterlyEstimate(…)` and `renderYtdSummary(…)`
exactly as that skill's procedure specifies. **No tax constant is ever written
here** — every rate, bracket, threshold, and due date is a read through the
tax-profile loader, and if `loadProfile()` returns `!ok` the tax section renders
"tax profile unavailable: <error path>" with a `tax_profile_error` note rather
than a guessed number.

**Two fail-closed cases, both of which suppress the figure rather than publish a
wrong one:**

- **No business-tagged budget** → `no_business_budget`. Render the one-line
  `NO_BUSINESS_ENTITY_NOTE` from the guard module in place of the tax section.
- **Business budgets in different currencies** → `mixed_currency`, and
  `grossIncome`/`deductibleExpenses`/`net` all come back `null`. The tax engine is
  US-only and dollar-denominated; summing across currencies would corrupt every
  downstream figure. Render the per-budget breakdown and state that the
  consolidated estimate is unavailable for mixed currencies.

---

## 5. Render into the frozen template

The rollup **reuses the frozen template** — it does not get its own, and it never
regenerates chrome. Everything the AC asks for on the presentation side is a
property of that template, inherited by construction:

- the dark theme tokens (`--navy` `#1a1a2e`, `--teal` `#16a085`, the red
  `#e74c3c`, `--amber` `#f39c12`) live in its `:root`;
- the **`@media print`** block — color-adjust, page-break rules, forced-open
  `<details>`, the running footer — is in the same file, so the prototype's
  missing-print-CSS bug **cannot** recur here as long as this skill fills the
  template rather than emitting its own document;
- the `.card` / `.kpi` / `.badge` / `.progress` / `.table-scroll` classes are
  already defined — introduce **no new CSS**.

Fill the same 14 block slots and let the writer do the assembly. Slot mapping for
the rollup:

| Slot | Rollup content |
|---|---|
| `kpi-dashboard` | The **KPI dashboard**: combined net worth, aggregate income, aggregate spending / net cash flow, and the unified health score (with its `role="meter"` gauge when numeric). One KPI row **per currency** when `mixedCurrency`. |
| `section-9-net-worth` | Combined net worth, with the per-budget contribution table. |
| `section-2-income` / `section-3-spending` / `section-5-cash-flow` | Aggregate income, spending, and net cash flow across budgets. |
| `section-4-budget-adherence` | Cross-budget Ready-to-Assign and funding status. |
| `section-7-accounts` | Accounts across all budgets, grouped by budget. |
| `section-12-tax-summary` | The **single** consolidated YTD tax picture from §4 — never one fragment per budget. |
| `section-11-recommendations` | The ordered cross-budget action list (§6 ordering). |
| `section-1-classification`, `section-6-categories`, `section-8-goals`, `section-10-anomalies` | The **collapsible per-budget detail**: one `<details><summary>{budget label}</summary><div class="details__body">…</div></details>` per budget, so the rollup reads as a summary on screen and prints in full. |
| `footer-persona` | `bash "${CLAUDE_PLUGIN_ROOT}/bin/persona.sh" html-name` — inject verbatim. |

Every slot the template declares must be supplied; a section with nothing to say
is passed as the literal `no findings`.

**Escape every YNAB string, and every formatted amount.** Budget labels come from
config, but payee / category / account names — and the `currency_symbol` embedded
in a `formatMoney` result — are untrusted external data. Route each through the
one shared escaper before it enters a fragment, exactly as the universal
protocol's §8 requires:

```bash
safe="$(bash "${CLAUDE_PLUGIN_ROOT}/bin/html-escape.sh" -- "$raw")"
```

Then assemble with the report writer as the **final** step, using the
`Portfolio` tier:

```bash
report_path="$(bash "${CLAUDE_PLUGIN_ROOT}/bin/report-writer.sh" \
  --tier Portfolio \
  --date "$report_date" \
  --slot "kpi-dashboard=$kpi_html" \
  --slot "section-9-net-worth=$net_worth_html" \
  --slot "footer-persona=$persona_html")"
```

The writer resolves `.report.output_dir`, writes
`YNAB-Portfolio-Review-{date}.html`, and prints the absolute path — surface it.

---

## 6. Dispatch summary

Collect the headline findings from **every** budget, tag each with the budget it
came from, and order them with `orderFindings(findings)`: **most-severe first**
(`action-required` → `attention` → `good`), stable within a band so your own
impact ranking survives. An unrecognized severity throws rather than being sorted
out of sight — fix the finding, never the ranking.

Render to the frozen contract in
[`../../docs/dispatch-format.md`](../../docs/dispatch-format.md): each finding
prefixed with its severity emoji (`SEVERITY_EMOJI`: 🔴 / 🟡 / 🟢, the same
taxonomy as the report badges), the report-pointer line with `$report_path`, and
the persona sign-off (`bash "${CLAUDE_PLUGIN_ROOT}/bin/persona.sh" signoff`).
Name the budget in each finding — "which budget" is the whole point of a rollup.
Use `dispatchFindingsPlan(findingCount)` from the guard module for the
below-five and zero-finding carve-outs.

Carry every note into the summary: `mixed_currency`, `no_ready_to_assign`,
`no_business_budget`, `tax_profile_error`, and one line per **excluded** budget
from §1 with its reason.

When any tax figure appears, include the canonical not-tax-advice tag on its own
line between the findings and the report pointer, verbatim from
[`../shared/disclaimer.md`](../shared/disclaimer.md).

---

## Hard rules

1. **Read-only, always.** Read tools only; never a write verb; never move money.
   The rollup is additive — it modifies no budget's data, categories, or
   transactions at any point.
2. **No hardcoded budget.** Every budget id, name, label, and role is a config
   read through `bin/config.sh`.
3. **Never inline a concrete tool name.** Reference
   [`../protocol/ynab-tools.md`](../protocol/ynab-tools.md); the namespaced
   prefix and family glob are fine, concrete suffixes are not.
4. **Convert milliunits before aggregating — once, in the module.** Never sum raw
   milliunits across budgets, and never re-divide a returned total.
5. **Never sum across currencies.** Per-currency subtotals plus the
   `mixed_currency` note; the consolidated tax estimate is withheld outright.
6. **Fill the frozen template; never regenerate it.** That is what makes the
   `@media print` block and the dark theme inherited rather than re-derived.
7. **Reuse before re-fetching**, and scope every fetch to one `budget_id`.
8. **No fabrication.** Missing data is said out loud and noted; a `null` renders
   `n/a`, never a `0` that reads as measured.
9. **Not tax advice.** Surface signals; a professional decides.
