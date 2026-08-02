# Cross-budget portfolio rollup

> ⚠️ Estimates only — not tax advice. Consult a qualified professional before filing or paying.

The contract for the **portfolio rollup** (M6-7, issue #85): one consolidated
report across every configured budget, instead of N per-budget reviews the user
has to mentally sum.

| Piece | File |
|---|---|
| Slash command | [`../commands/ynab-portfolio.md`](../commands/ynab-portfolio.md) |
| Skill (orchestration half) | [`../skills/review/portfolio-ynab-review.md`](../skills/review/portfolio-ynab-review.md) |
| Aggregation math (compute half) | [`../assets/portfolio-rollup.js`](../assets/portfolio-rollup.js) |
| Unit tests | [`../tests/unit/portfolio-rollup.test.mjs`](../tests/unit/portfolio-rollup.test.mjs) |
| Surface + rendered-HTML tests | [`../tests/unit/portfolio-report.test.sh`](../tests/unit/portfolio-report.test.sh) |

The rollup sits **on top of** the per-budget review: the universal protocol
([`../skills/review/ynab-review.md`](../skills/review/ynab-review.md)) still owns
the 12-section analysis of any single budget; the rollup owns only what is true
*across* budgets.

## Which budgets are in scope

The `budgets` array in the user's config **is** the enabled set — the config
schema defines it as "the YNAB budgets this plugin operates on". Entries are read
through [`../bin/config.sh`](../bin/config.sh) (`_cfg_budgets`, which applies the
schema-v1 → multi-budget migration), then filtered by `selectBudgets`.

The two per-budget booleans are **not** filters for this report:

| Field | Gates | Used by the rollup? |
|---|---|---|
| `monitoring_enabled` | the monitoring poll | No |
| `write_back_enabled` | the write-back path | No — the rollup never writes |

An entry is **included** only when it carries a non-empty `label`, a non-empty
`role`, and at least one of `budget_id` / `budget_name` (the schema's own
requirements). Anything else is **excluded with a named reason**
(`not_an_object`, `missing_label`, `missing_role`, `missing_budget_ref`) and
surfaced as a dispatch note — a silently dropped budget would understate every
total. Zero included budgets is a stop, not an empty report.

`role` is free-form and matched case-insensitively; `business` selects the
Schedule C set.

## What is aggregated

`aggregatePortfolio(snapshots)` returns the four required dimensions, plus the
per-budget breakdown that feeds the collapsible detail sections:

| Dimension | Field |
|---|---|
| Combined account balances / net worth | `totals[iso].netWorth` |
| Aggregate income vs spending | `totals[iso].income` / `.spending` / `.netCashFlow` |
| Cross-budget Ready-to-Assign | `totals[iso].readyToAssign` |
| Unified health score | `healthScore` (0–100, or `null`) |

**Ready-to-Assign absence is per currency.** `totals[iso].readyToAssign` stays at
the `null` sentinel — rendering `n/a`, never a masking `0` — exactly when no budget
in *that* currency supplied the data, and the `no_ready_to_assign` note fires when
*any* currency lacks it. Judging it globally would leave one currency's `n/a`
column unexplained whenever another currency happened to have the data.

The **unified health score** is the mean of each budget's own 0–100 overall score
(via `overallHealthScore` in [`../assets/review-guards.js`](../assets/review-guards.js)),
so each budget counts once regardless of how many sections it could measure. A
budget whose sub-scores are all `null` — nothing measurable — is excluded; when no
budget is measurable the score is `null`, which renders `n/a` with **no**
`role="meter"` gauge.

## Two invariants worth stating twice

**Milliunits are converted exactly once, at intake.** `milliToCurrency` is the
only division in the module, and every per-budget amount passes through it before
it reaches a sum. Every figure the module returns is already in currency units —
never re-divide one, never add a raw milliunit amount to one.

Which is why rendering goes through **`formatRollupMoney(amount, currencyFormat)`**,
the module's display boundary — *not* `formatMoney` directly. The tree-wide money
helper takes **raw milliunits** and divides internally ("only DISPLAY divides"),
but this module's outputs were already converted at intake; handing one straight
to `formatMoney` divides a second time and renders every figure 1000× too small.
`formatRollupMoney` converts back and formats in one step, so no call site ever
writes a `* 1000`, and it renders the `null` sentinel as `n/a` rather than
`formatMoney`'s non-finite fallback of `$0.00` — "nothing was measured" must not
read as "there is nothing".

**Currencies are never merged.** Totals are keyed by ISO code. When budgets
disagree on currency, the rollup reports per-currency subtotals and the
`mixed_currency` note; it never emits a single cross-currency figure
(the rule in [`../skills/review/ynab-review.md`](../skills/review/ynab-review.md)
§5). A budget with no readable `currency_format` groups under `UNKNOWN` rather
than silently joining the USD pile.

## The consolidated tax view

`aggregateScheduleC(businessSnapshots)` sums the `business`-tagged budgets'
Schedule C income and deductible expenses into **one** figure set, which feeds
`computeEstimate(…)` in [`../lib/tax/estimatedTax.mjs`](../lib/tax/estimatedTax.mjs)
— the M6-4 tracker — producing a single YTD picture rather than per-budget
fragments. The module performs no tax math and holds no tax constants; every
rate, bracket, threshold, and due date is a read through the tax-profile loader
([`tax-profile-loader.md`](tax-profile-loader.md)).

Two cases withhold the figure instead of publishing a wrong one:

- **No business-tagged budget** → `no_business_budget`; the tax section renders
  the `NO_BUSINESS_ENTITY_NOTE` one-liner.
- **Business budgets in different currencies** → `mixed_currency`, and
  `grossIncome` / `deductibleExpenses` / `net` all return `null`. The tax engine
  is US-only and dollar-denominated; summing across currencies would corrupt
  every downstream figure.

## Rendering — the frozen template, reused

The rollup fills the **same frozen template** every other report uses
([`../assets/report/template.html`](../assets/report/template.html), contract in
[`../assets/report/SLOTS.md`](../assets/report/SLOTS.md)) and is assembled by the
**same writer** ([`report-writer.md`](report-writer.md)) under the `Portfolio`
tier, producing `YNAB-Portfolio-Review-{date}.html`.

That reuse is what makes the presentation guarantees **inherited rather than
re-derived**: the dark-theme tokens live in the template's `:root`, and the
`@media print` block — color-adjust, page-break rules, forced-open `<details>`,
`@page` margin, running footer — comes with it. The prototype's
missing-print-CSS bug cannot recur here as long as the skill fills the template
instead of emitting its own document; `tests/unit/portfolio-report.test.sh`
renders a real Portfolio report and asserts the print block, the tokens, the KPI
dashboard, and the collapsible per-budget sections survived into the HTML.

> **Palette note.** The template's warning token is `--coral: #ef6e5e`, not the
> prototype's `#e74c3c`: same hue family, lightened in place to clear WCAG 2.1 AA
> contrast (issue #29) and pinned by `tests/unit/report-contrast.test.mjs`. The
> rollup inherits the shipped token rather than reverting a gated a11y fix.

Per-budget detail goes in `<details>/<summary>` blocks so the report reads as a
summary on screen and prints in full.

> **The budget `label` is escaped, not trusted.** It comes from the user's own
> config, but config is a **trust boundary** in this repo, not a safe input —
> `persona.name` is bounded and pre-escaped for precisely this reason (issue #28
> / GAP-13, [`../bin/persona.sh`](../bin/persona.sh)). The label lands inside a
> `<summary>`, and the writer treats every block slot as an opaque, pre-escaped
> fragment it never re-processes, so the skill's escaping rule is the only thing
> between a label and the browser. Every label therefore goes through
> [`../bin/html-escape.sh`](../bin/html-escape.sh) like any YNAB-sourced string;
> its default sanitize mode byte-gates and truncates before it scans, so an
> unbounded config value is safe to pass. `tests/unit/portfolio-report.test.sh`
> renders a hostile `</summary><script>…` label and asserts it arrives as inert
> text.
>
> **The same rule covers the tax-profile loader's error message.** On the
> `loadProfile()` failure path the tax section renders "tax profile unavailable:
> …", and that message can quote the `tax_profile_path` override or
> `$YNAB_TAX_PROFILE_FILE`. `redact()` ([`../lib/containment.mjs`](../lib/containment.mjs))
> masks home-directory spellings only — it neutralizes no HTML metacharacter — so
> the message is escaped exactly like a label before it reaches
> `section-12-tax-summary`. The escaping rule names four sources and exempts
> none.

## Dispatch ordering

`orderFindings(findings)` ranks cross-budget findings **most-severe first**
(`action-required` → `attention` → `good`), stable within a band so the skill's
own impact ranking survives inside each severity. The emoji (`SEVERITY_EMOJI`:
🔴 / 🟡 / 🟢) match the frozen contract in
[`dispatch-format.md`](dispatch-format.md) and the report's badge classes.

An **unrecognized severity throws** rather than sorting to the end: a finding the
ranker cannot place would be buried below the healthy ones, which is exactly the
fail-open behaviour a severity ranking must not have.

## Read-only

The rollup is additive. It calls **read tools only**, through the namespaced
`mcp__plugin_workbench-ynab_ynab__*` family (concrete names resolved from
[`../skills/protocol/ynab-tools.md`](../skills/protocol/ynab-tools.md)), and
modifies no budget's data, categories, or transactions at any point. Both
surfaces are enumerated in
[`../scripts/check-readonly.sh`](../scripts/check-readonly.sh), so a callable
write verb on either one fails CI.
