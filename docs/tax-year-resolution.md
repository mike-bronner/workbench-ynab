# Active tax-year resolution

How the plugin decides **which tax year a review reports on**, and what happens in
early January when two tax years are live at once. Issue #17 (GAP-15).

The rule lives in [`lib/tax/taxYear.mjs`](../lib/tax/taxYear.mjs) and is re-exported
from the engine facade [`lib/tax/index.mjs`](../lib/tax/index.mjs). Tests:
[`tests/unit/tax-year.test.mjs`](../tests/unit/tax-year.test.mjs).

## The rule

```js
resolveTaxYear(reviewDate, timezone, taxYearOverride?) → 2025
```

The active tax year is the **calendar year of the review date, converted to the
configured timezone** — or `config.tax_year` when the user pinned one.

Two inputs, and no others:

| Input | Source |
|---|---|
| `reviewDate` | the review window's end date (`plan.data_pull.transactions.until_date`), a `Date`, or a date-time carrying an explicit UTC offset |
| `timezone` | `config.timezone` — required, never defaulted to the host zone |
| `taxYearOverride` | `config.tax_year` — optional |

### The budget name is never a source

The prototype budget is named `Personal 2024`. A year parsed out of a budget's
display name is wrong twice over: it keeps answering `2024` forever, and it breaks
the moment the user renames the budget. The name is **display-only** — no function
in `lib/tax` accepts it, receives it, or parses it, and a test pins that.

### Why the timezone is required

Near midnight on Dec 31 / Jan 1 the host clock and the configured zone disagree
about the calendar **year**, not just the day — the difference is a whole tax year
of figures. So an absent or unknown zone **throws**; it never falls back to the
host zone. This is the tax-year seam of the same fail-closed rule
[`bin/config.sh`](config-loader.md) applies at load time (issue #31), including the
same deny-list: the `right/` and `posix/` mirror subtrees and the `Factory` /
`posixrules` build artifacts all resolve to a UTC-equivalent date, so accepting one
would re-leak exactly the host-clock answer the configured zone exists to prevent.

### The override

`config.tax_year` is an optional four-digit integer, for setups that do not follow
the calendar year. Absent — the normal case — the year is derived from the review
date. A malformed value **fails closed** at both layers (`_cfg_tax_year` in the
shell, `resolveTaxYear` in the engine) rather than being ignored: silently falling
back to the review date would report a different year than the user asked for, with
no signal.

#### How the override reaches a run

`config.tax_year` sits in a file no engine function reads, so every hop between
the file and `resolveTaxYear` is explicit. Breaking any one of them makes the key
inert — set by the user, ignored by the run — with nothing to signal it:

| Hop | Who | What it does |
|---|---|---|
| 1 | `bin/config.sh` `_cfg_tax_year` | Reads `.tax_year`, checks it is a four-digit JSON **number**, echoes it (or nothing when the key is absent or `null`). Fails closed on anything else — including the falsy values `false` and `""`, because "is the key set?" is decided from the JSON **type**, not the rendered text. |
| 2 | the entry command — `commands/ynab-review.md` Step 1a and each ad-hoc tier command's Phase 1 | `tax_year="$(_cfg_tax_year)" \|\| exit 1`. The dispatcher is the only layer that reads config. |
| 3 | the same command's orchestrator prompt | Sends `tax_year: <value>`, and **omits the line** when the value is empty. |
| 4 | [`agents/ynab-orchestrator.md`](../agents/ynab-orchestrator.md) | Copies that prompt field into `plan.tax_year.override` unread, or `null` when the line is absent. It never reads `config.json` itself. |
| 5 | [`skills/review/ynab-review.md`](../skills/review/ynab-review.md) §12 | Passes `taxYearOverride: plan.tax_year.override` to `computeTaxSummary`, which calls `resolveTaxYear`. |

The `/ynab-tax` tracker takes a shorter path to the same rule: its skill
([`skills/estimated-tax/SKILL.md`](../skills/estimated-tax/SKILL.md)) sources the
loader directly and passes the resolved override straight to `resolveTaxYear`,
using hops 1 and 5 only, so the tracker and the report always count the same year.

The chain is pinned end to end by
[`tests/unit/tax-year-wiring.test.sh`](../tests/unit/tax-year-wiring.test.sh) —
each hop has its own assertion, because a hop that silently stops forwarding is
invisible in the output of every other hop.

**The quarterly reminder is not on this chain, by design.**
`commands/ynab-review.md` Step 1d sizes its due-date window from the **calendar**
year of `today`, never the resolved tax year: a reminder answers "which deadlines
land soon", so a pinned `tax_year: 2031` must not send it hunting for 2031 and
2030 deadlines while the calendar sits in 2026.

## Quarterly due dates and the Q4 rollover

A single tax year's four estimated-tax due dates span **two calendar years**. For
the bundled US federal schedule, tax year N is due:

| Quarter | Due | Calendar year |
|---|---|---|
| Q1 | Apr 15 | N |
| Q2 | Jun 15 | N |
| Q3 | Sep 15 | N |
| Q4 | Jan 15 | **N + 1** |

Every one of those dates is **derived from the tax-year integer** by
`getQuarterlyDueDates(year)`; the month/day pairs come from the profile's
`quarterlyEstimatedDueDates`. No year literal appears anywhere in the engine, and a
test greps for one.

**Attribution.** A payment is attributed to the quarter it *pays toward* — the
first due date on or after the payment date — and to the tax year that quarter
belongs to. So a payment made **Jan 1–15 of year N+1 belongs to tax year N's Q4**,
and `detectPayments` tags it `tax_year: N`. Jan 16 onward belongs to year N+1's Q1.
This keeps one year's tracker from being contaminated by the next year's payments
when a transaction pull spills across the calendar boundary.

## The year-boundary (changeover) window

Between **Jan 1 and the day before the prior year's final due date**, two tax years
are live at once: year N is not finished (its Q4 payment has not cleared) while
year N+1 has already begun. In that window a review surfaces **both**.

The window's end is derived from the profile's own schedule — the quarter whose due
date falls earlier in the calendar than Q1's has rolled into the next year, and the
last such quarter is the year's final payment. For the federal schedule that is
Jan 15. A schedule whose quarters all fall inside their own tax year has no
changeover window at all.

`computeTaxSummary` behaves as follows during the changeover:

- the summary body is the **new year's opening state** — year N+1's figures so far;
- `ytdData.priorYearClose` is **required**, and carries year N's YTD figures plus
  its own `asOfDate` (where that year's books were cut). Omitting it throws. A
  summary that quietly dropped the close-out would look complete while hiding a
  whole tax year;
- `summary.yearBoundary.priorYearClose` returns year N's Schedule C / Schedule A /
  medical / SE figures in the **same shape** as the main body, computed against
  year N's own standard deduction and brackets.

Outside the window, `priorYearClose` is not required and `yearBoundary.inChangeover`
is `false`.

## The report header

`summary.meta.taxYearLabel` is the header string, and it names **both** years during
the changeover:

| Situation | Label |
|---|---|
| Ordinary review | `Tax Year 2025` |
| Changeover (Jan 1–14) | `Tax Year 2026 (2025 close-out through 2026-01-15)` |

The review skill passes it to `bin/report-writer.sh --tax-year`, which fills the
`{{tax_year}}` scalar slot in the report header (see
[`assets/report/SLOTS.md`](../assets/report/SLOTS.md)). The writer accepts **only**
those two shapes, so a year written by hand — or read off a budget name — cannot
reach the rendered report. A tier with no tax section passes nothing and the slot
renders empty.
