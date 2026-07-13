# The dispatch-summary format — the post-report TL;DR contract

After the universal review skill
([`skills/review/ynab-review.md`](../skills/review/ynab-review.md), M2-3) writes the
full HTML report through the report-writer
([`bin/report-writer.sh`](../bin/report-writer.sh), M2-9), it emits a short
**dispatch summary** to the session — the human-facing headline that follows a
token-heavy report. This file is the frozen contract for *how* that summary is
shaped: the fixed count, the severity emoji, the per-finding structure, the
report pointer, and the persona sign-off.

> **Presentation contract only.** This spec defines **how** the dispatch is
> rendered, never **what** the findings are or how they are ranked. The findings
> come from the 12 analysis sections
> ([`docs/methodology.md`](./methodology.md), M2-3) and arrive here **already
> ranked** by the review. The dispatch contains **no analysis logic and no
> ranking algorithm** — it is the final formatting step over a pre-ranked list.

## Why a fixed contract

The prototype emitted an implicit, inconsistent dispatch. Codifying it as a
reusable contract lets the review skill render the same deterministic shape
across every tier, and keeps the dispatch view and the HTML report view in
agreement (same severity taxonomy — see below). This mirrors `workbench-bujo`'s
pattern of a tight, human-readable summary held distinct from the machine
structure that produced it.

## The shape

A dispatch is these four fixed parts, in order — plus one **conditional** line (a
not-tax-advice tag) that appears only when the output carries tax figures:

1. A one-line **header** naming the review (tier + report date).
2. Exactly **five (5) findings**, one per line, ranked by severity/impact
   **descending** — no more, no fewer.
2b. A **not-tax-advice disclaimer tag** — *conditional*: present only when tax
   figures, quarterly estimates, or Schedule amounts appear in the findings (see
   [Not-tax-advice disclaimer](#6-not-tax-advice-disclaimer-conditional) below). It
   is not a finding and never counts toward the fixed five.
3. A **report pointer** line to the saved report path.
4. A **persona sign-off** line.

### 1. Exactly five findings

Every dispatch renders **exactly five findings — never more, never fewer**. The
review always surfaces its top five candidates ranked highest-severity/impact
first; the dispatch takes that pre-ranked list verbatim. The count is fixed so
the summary stays a scannable TL;DR rather than a second report.

### 2. Severity emoji prefix

Each finding opens with one of three severity emoji. The one-line semantics:

| Emoji | Severity | Meaning |
|-------|----------|---------|
| 🔴 | **action required** | A problem that needs a decision or fix now. |
| 🟡 | **attention needed** | Worth a look; drifting or approaching a threshold. |
| 🟢 | **good / informational** | Healthy state or a positive signal — no action. |

These three emoji **must** match the report's status-badge taxonomy — the frozen
HTML template ([`assets/report/template.html`](../assets/report/template.html),
M2-5) defines the `.badge` classes `is-good` (🟢), `is-attention` (🟡), and
`is-warning` (🔴). The dispatch and the report are two views of the same review,
so their severity signals **must agree**:

| Dispatch emoji | Report badge class (M2-5) |
|----------------|---------------------------|
| 🟢 | `badge is-good` |
| 🟡 | `badge is-attention` |
| 🔴 | `badge is-warning` |

### 3. Per-finding structure

Each finding is a single line in exactly this shape:

```
{emoji} **Bold one-line statement.** 1–2 sentence action.
```

- **`{emoji}`** — the severity prefix from the table above.
- **Bold one-line statement** — the finding itself, as one bolded sentence.
- **1–2 sentence action** — what to do about it, in plain, action-oriented
  language. One or two sentences, no more.

### 4. Report pointer

A single line points the reader at the saved HTML report, using the absolute
path the report-writer returns on stdout (`$report_path`, the `{{output_path}}`
scalar — filename `YNAB-{Tier}-Review-{date}.html` under the configured
`.report.output_dir`, see [`docs/report-writer.md`](./report-writer.md)):

```
📄 Full report: {output_path}
```

### 5. Persona sign-off

The dispatch is signed off in the configured persona's voice, via
`bash "${CLAUDE_PLUGIN_ROOT}/bin/persona.sh" signoff` — which renders
`— {persona}, your financial assistant`. The name is resolved at runtime through
the persona precedence ([`docs/persona.md`](./persona.md), M2-1) and is **never
hard-coded** in the dispatch; the tone follows the configured persona (warm,
plain-spoken, action-oriented — no jargon-as-drama).

Any run-level warnings or notes (`empty_budget`, `tax_profile_error`,
`ynab_mcp_offline`, plan `warnings`) are carried into the dispatch as findings or
an appended note line — they are surfaced, never dropped.

### 6. Not-tax-advice disclaimer (conditional)

Whenever the dispatch surfaces **tax figures, quarterly estimates, or Schedule
amounts** — an SE-tax number, an estimated-tax due amount, a Schedule C/A total, an
AGI-threshold figure — it carries a single compact **not-tax-advice tag** on its own
line, placed **between the five findings and the report pointer**:

```
⚠️ Estimates only — not tax advice. Consult a qualified professional before filing or paying.
```

This is the **canonical compact tag** — the exact, invariant wording defined once in
[`../skills/shared/disclaimer.md`](../skills/shared/disclaimer.md) and shared verbatim
with the report, the README, and the setup output. It is **content, not analysis**: the
string never varies by tax profile, Schedule, currency, or persona, and it is emitted
**only when tax content is present** (a weekly or monthly dispatch with no tax figures
omits it — see those worked examples). The tag is **not a finding**: it never counts
toward the fixed five and never carries a severity emoji.

## Tier-agnostic by construction

This contract is **identical for every tier** — weekly, monthly, quarterly-tax,
and annual all render the exact same shape. The dispatch has
**no tier-specific sections and no branching logic**: the header names the tier
and the *candidate findings differ per tier* (a weekly review surfaces different
top findings than an annual one), but the count, the severity taxonomy, the
per-finding structure, the report pointer, and the sign-off never change. The
worked examples below differ only in their placeholder findings, never in shape.

## Worked examples

Each example shows a complete, rendered five-finding dispatch with **placeholder
data**. They illustrate the single contract above — the shape is identical
across all four; only the candidate findings differ.

#### Weekly tier

```
YNAB Weekly Review — 2026-06-19

🔴 **Groceries is overspent by $142 this week.** Cover it from Ready-to-Assign or trim next week's plan before it compounds into the monthly bucket.
🔴 **Three transactions are still uncategorized.** Categorize them so this week's cashflow and any deduction tracking stay accurate.
🟡 **Dining is at 88% of its weekly target with three days left.** Ease off or move a little funding over to avoid a red category by Sunday.
🟡 **The checking account has 5 uncleared transactions older than 6 days.** Reconcile against the bank so the cleared balance can be trusted.
🟢 **Ready-to-Assign is $0 — every dollar has a job.** Nothing to do; the budget is fully allocated for the week.

📄 Full report: ~/Documents/Claude/Reports/YNAB-Weekly-Review-2026-06-19.html

— {persona}, your financial assistant
```

#### Monthly tier

```
YNAB Monthly Review — 2026-06-30

🔴 **Net cashflow was −$620 for June.** Outflow outran inflow; review the two largest discretionary categories and set a July guardrail.
🔴 **Two categories ended the month negative.** Fund them back to zero from Ready-to-Assign before they roll a debt into July.
🟡 **Subscriptions rose 18% versus May.** A likely price change or a new recurring charge — scan the payee list and cancel anything stale.
🟡 **A likely duplicate pair of $54.00 transactions was detected on 06-14.** Confirm and delete the double-entry so the month reconciles cleanly.
🟢 **Savings hit its monthly funding goal.** On track — no action needed this cycle.

📄 Full report: ~/Documents/Claude/Reports/YNAB-Monthly-Review-2026-06-30.html

— {persona}, your financial assistant
```

#### Quarterly-Tax tier

```
YNAB Quarterly-Tax Review — 2026-06-30

🔴 **Q2 estimated tax of $3,400 is due 2026-06-15 and not yet set aside.** Move the amount to the tax hold now to avoid an underpayment penalty.
🔴 **Self-employment tax exposure is $2,100 on Q2 business net income.** Confirm the set-aside covers both SE tax and income tax before filing the estimate.
🟡 **Schedule C expenses are 12% below last quarter.** Check for business spend sitting in personal categories so deductions aren't understated.
🟡 **Medical spend is at 61% of the AGI deduction threshold.** Track remaining qualifying costs this half-year in case itemizing beats the standard deduction.
🟢 **All business income is categorized and mapped to Schedule C lines.** Clean books — no reclassification needed for the estimate.

⚠️ Estimates only — not tax advice. Consult a qualified professional before filing or paying.

📄 Full report: ~/Documents/Claude/Reports/YNAB-Quarterly-Tax-Review-2026-06-30.html

— {persona}, your financial assistant
```

#### Annual tier

```
YNAB Annual Review — 2026-12-31

🔴 **Total spending outpaced income by $1,900 for the year.** Set one structural cut for next year rather than trimming across every category.
🔴 **Q4 estimated tax of $3,200 is due 2027-01-15 and not yet funded.** Set it aside now so the year closes without an underpayment penalty.
🟡 **Three sinking funds are underfunded heading into January.** Top them up or reset their goals so next year's known costs are already covered.
🟡 **Discretionary spend grew 9% year-over-year, ahead of income.** Worth a category-level look before it becomes next year's baseline.
🟢 **Net worth rose 14% over the year.** Solid trajectory — the current allocation is working.

⚠️ Estimates only — not tax advice. Consult a qualified professional before filing or paying.

📄 Full report: ~/Documents/Claude/Reports/YNAB-Annual-Review-2026-12-31.html

— {persona}, your financial assistant
```

## Boundary — what this contract is not

- It is **not analysis logic.** The 12 sections (M2-3) decide *what* the findings
  are and *how severe* each is. The dispatch only formats a list handed to it.
- It is **not a ranking algorithm.** Findings arrive **pre-ranked**
  (severity/impact descending); the dispatch renders them in the order given and
  takes the top five. Where the ranking comes from is the review skill's
  concern, not this contract's.
- It is **not a second report.** It is the human-facing TL;DR — a fixed five
  lines plus a pointer and a sign-off — that sits above the full HTML report.
