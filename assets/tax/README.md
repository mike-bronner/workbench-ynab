# Tax profile

The **tax profile** is the data-driven, shareable description of a taxpayer's
filing situation that the workbench-ynab review skills use to produce a
tax-aware report (Schedule C / A / 1 / SE awareness, medical-threshold tracking,
quarterly estimated taxes).

This directory holds the **schema and types** — the generic, shareable shape.
It deliberately contains **no real taxpayer data**. A real taxpayer's numbers
become one *instance* of this schema, stored outside the repo (see
[Where the live profile lives](#where-the-live-profile-lives)).

| File | Purpose |
| --- | --- |
| [`tax-profile.schema.json`](./tax-profile.schema.json) | Canonical JSON Schema (draft 2020-12). Source of truth for the shape. |
| [`tax-profile.d.ts`](./tax-profile.d.ts) | TypeScript declaration (`TaxProfile` + supporting types) for the engine to import. Zero runtime overhead. |
| [`tax-profile.example.json`](./tax-profile.example.json) | A valid instance built entirely from placeholder values. |
| [`us-tax-lines.json`](./us-tax-lines.json) | The **default US ruleset**: the Schedule C / A / 1 / SE line catalog the mapping engine maps onto, plus the default `standardDeductionByYear` table and `thresholds`. Purely declarative data; no per-taxpayer numbers. |
| [`mapping-rules.schema.json`](./mapping-rules.schema.json) | Canonical JSON Schema (draft 2020-12) for the payee/category → tax-line **mapping ruleset** (issue #23). |
| [`mapping-rules.json`](./mapping-rules.json) | The **default US mapping ruleset**: generic, ordered rules that classify a YNAB transaction to a tax line by payee keyword, category, account, or amount. Purely declarative data; no owner-specific names. |

## The mapping engine — payee/category → tax line

[`lib/tax/classifyTransaction.mjs`](../../lib/tax/classifyTransaction.mjs)
(issue #23) turns an already-fetched YNAB transaction into a suggested tax line.
It evaluates the bundled [`mapping-rules.json`](./mapping-rules.json) defaults,
overlaid by the user's own rules, in ascending `priority`; the first matching
rule wins, and nothing matching yields an explicit `unclassified` result (never
a wrong guess). Users add, disable, or re-prioritize rules by putting them under
`overrides.mappingRules` in their profile instance — a user rule with the same
`id` as a bundled rule replaces it (set `enabled: false` to disable a default),
a new `id` is appended. See
[`docs/mapping-engine.md`](../../docs/mapping-engine.md) for the precedence,
tie-breaking, milliunit handling, and the `$profile` business-scoping mechanism.

> **YNAB namespacing.** The transactions the engine classifies are fetched by
> the consuming skill with the vendored MCP tools namespaced
> `mcp__plugin_workbench-ynab_ynab__*` (e.g. `ynab_list_transactions`) — **not**
> `mcp__ynab__*`. The engine itself is MCP-agnostic: it only reads plain objects.

## Generic and shareable — a locked decision

Nothing in this schema, its defaults, or the bundled example may be specific to
one user. Display names are placeholders (`"Business A"`); there are no real
person, lender, bank, business, or account names or numbers anywhere. The
owner's real numbers are migrated into a *config instance* (issue M3-5), never
into the schema or any prompt.

## Money units — dollars, not milliunits

Every monetary amount in a tax profile is in **dollars**.

The vendored YNAB MCP returns amounts in **milliunits** (1000 milliunits = $1).
**Divide YNAB milliunits by 1000 to get dollars** before comparing them against
anything in a tax profile. Conflating the two is a classic, expensive bug — the
schema's `description` fields restate this on every dollar field.

Rates (`thresholds.medicalAgiPercent`, `thresholds.seTaxRate`) are **fractions**,
not dollars and not percentages: `0.075` means 7.5%.

## Where the live profile lives

The tax profile is read by the **skills**, never by the vendored third-party
YNAB MCP (the MCP only receives the token and its package-native env from the
launcher — it cannot read plugin config). The profile therefore lives alongside
the plugin's other config **outside the repo**, so it survives plugin updates:

```
~/.claude/plugins/data/workbench-ynab-claude-workbench/tax-profile.json
```

This follows the same data-dir convention `workbench-core` uses — for example
`hooks/mcp-memory.sh` there reads
`~/.claude/plugins/data/workbench-core-claude-workbench/config.json` via `jq`.
The tax profile is a sibling `tax-profile.json` in the workbench-ynab data dir.

To create one, copy [`tax-profile.example.json`](./tax-profile.example.json) to
that path and replace the placeholder values with your own:

```sh
mkdir -p ~/.claude/plugins/data/workbench-ynab-claude-workbench
cp assets/tax/tax-profile.example.json \
   ~/.claude/plugins/data/workbench-ynab-claude-workbench/tax-profile.json
# then edit tax-profile.json with your real numbers — it stays on your machine,
# outside this repo, and is never committed.
```

## Defaults and overrides

The bundled **default US ruleset** supplies the standard deductions,
thresholds, schedule-line data, and estimated-tax due dates. Its line catalog,
`standardDeductionByYear` table, and `thresholds` are checked in as
[`us-tax-lines.json`](./us-tax-lines.json) (issue #21); the profile loader
(issue M3-3) merges that data with any user `overrides`. The line `id` scheme
(`schedC.27a`, `schedA.medical`, `sched1.studentLoanInterest`, `schedSE`),
filing-status keys, and `thresholds` keys there are kept consistent with this
schema. A live profile only needs to specify what differs: the `overrides`
object is deep-merged **on top of** the defaults by the profile loader, so
users change individual values without restating the whole ruleset. See
[`docs/tax-profile-loader.md`](../../docs/tax-profile-loader.md) for the loader's
precedence, path resolution, provenance, and accessor contract.

Adding a new tax year to the default standard deductions is a pure **data
edit** of `us-tax-lines.json` — add a new four-digit year key with its dollar
amount under each filing status; no code change.

## Shape overview

| Field | Type | Notes |
| --- | --- | --- |
| `schemaVersion` | string \| integer | Targets a schema version so migrations are detectable. **Required.** |
| `filingStatus` | enum | `single` \| `mfj` \| `mfs` \| `hoh` \| `qw`. **Required.** |
| `taxYear` | integer | The profile is year-aware. **Required.** |
| `standardDeductionByYear` | object | `filingStatus → year → dollars`. |
| `businessEntities[]` | array | Each has `id`, `displayName`, `schedule`, `scheduleLineMap` (inner shape owned by M3-2). |
| `itemized` | object | Schedule A: `medical`, `salt` (with `saltCap`), `interest`, `charitable`. |
| `adjustments` | object | Schedule 1: `seTaxHalfDeduction`, `studentLoanInterest`, `iraContributions`. |
| `thresholds` | object | `medicalAgiPercent` (0.075), `seTaxRate` (0.153), `saltCap` (10000). |
| `quarterlyEstimatedDueDates[]` | array | `{ quarter, month, day }` due-date parts (Q4 falls in January of the following year) plus optional `period*` income-attribution boundaries (Q1 Jan–Mar, Q2 Apr–May, Q3 Jun–Aug, Q4 Sep–Dec). |
| `incomeTaxBracketsByYear` | object | `filingStatus → year → [{ upTo?, rate }]` marginal brackets; the top bracket omits `upTo`. Used by the estimated-tax tracker (#82). |
| `estimatedTaxPayments` | object | Detection matchers (`payeeKeywords`, `categoryNames`, `categoryGroups`, `accounts`) for estimated-tax payments already recorded in YNAB (#82). |
| `overrides` | object | User-override layer merged over the default ruleset by M3-3. |

The **estimated-tax tracker** that consumes the last three fields is documented
in [`docs/estimated-tax-tracker.md`](../../docs/estimated-tax-tracker.md).

The schema is the authoritative reference — see
[`tax-profile.schema.json`](./tax-profile.schema.json) for every field's
constraints and `description`.

## Validating an instance

The schema is JSON Schema **draft 2020-12**. Validate any instance against it
with [`ajv`](https://ajv.js.org/) (or any draft-2020-12 validator):

```sh
npx ajv-cli@5 validate --spec=draft2020 \
  -s assets/tax/tax-profile.schema.json \
  -d assets/tax/tax-profile.example.json
```

A passing run exits `0` with no validation errors.

> **Not tax advice.** This tool organizes financial data and surfaces
> tax-relevant signals. It is not a substitute for professional tax advice.
