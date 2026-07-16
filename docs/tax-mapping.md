# Tax mapping — the tax-engine reference

This is the single entry-point reference for the workbench-ynab **tax engine**:
the data-driven machinery that turns already-fetched YNAB transactions into
suggested tax lines (Schedule C / A / 1 / SE), tracks thresholds, and feeds the
tax-aware review report. It ties together the schema, the default US ruleset,
the mapping engine, and the customization story; the per-module docs it links
to stay authoritative for their edge-case detail.

> ⚠️ Estimates only — not tax advice. Consult a qualified professional before filing or paying.
> (Canonical wording: [`skills/shared/disclaimer.md`](../skills/shared/disclaimer.md), issue #18.)

> **The code is the source of truth.** This doc describes the behavior the
> M3-1..M3-6 modules actually implement. If anything here diverges from
> [`lib/tax/`](../lib/tax/index.mjs) or the data files under
> [`assets/tax/`](../assets/tax/README.md), **the code wins** and this doc must
> be corrected to match it.

**The coherent path:** install with
[`/workbench-ynab:setup`](../commands/setup.md) (issue #15) → configure your
tax profile ([section 5](#5-customizing-your-profile) below) → run a review
([`skills/review/ynab-review.md`](../skills/review/ynab-review.md)).

Contents:

1. [Concept and split](#1-concept-and-split)
2. [Schema reference](#2-schema-reference)
3. [The default US ruleset](#3-the-default-us-ruleset)
4. [The mapping engine](#4-the-mapping-engine)
5. [Customizing your profile](#5-customizing-your-profile)
6. [Privacy](#6-privacy)
7. [How the review skill consumes the engine](#7-how-the-review-skill-consumes-the-engine)

## 1. Concept and split

The tax engine runs **entirely within the skills layer** — plain Node modules
under [`lib/tax/`](../lib/tax/index.mjs) that the plugin's skills and commands
import. It never runs inside the vendored YNAB MCP.

The split is deliberate and strict:

- **All tax / budget / profile config is read by the skills**, from the
  plugin's data directory:

  ```
  ~/.claude/plugins/data/workbench-ynab-claude-workbench/
  ```

  Config there lives **outside the repo and outside the plugin cache**, so it
  **survives plugin updates** — an update replaces the plugin's code, never
  your profile. The live tax profile is
  `~/.claude/plugins/data/workbench-ynab-claude-workbench/tax-profile.json`.

- **The vendored YNAB MCP receives only the Keychain token and its
  package-native env** from the launcher. It cannot read plugin config, and no
  tax configuration is ever passed to it. Its only job is the YNAB API
  read/write surface, exposed as tools namespaced
  `mcp__plugin_workbench-ynab_ynab__*`.

So the flow is: a skill fetches transactions through the MCP tools, then hands
those plain objects to the engine, which resolves everything tax-shaped from
the data-dir profile. The engine performs no fetch, no MCP call, and no
network I/O of its own.

The engine is composed of four modules behind one facade
([`lib/tax/index.mjs`](../lib/tax/index.mjs), issue #27):

| Module | Issue | Job |
| --- | --- | --- |
| [`lib/tax/loadProfile.mjs`](../lib/tax/loadProfile.mjs) | #22 (M3-3) | Resolve the **effective profile**: bundled defaults ⊕ user profile ⊕ overrides. |
| [`lib/tax/classifyTransaction.mjs`](../lib/tax/classifyTransaction.mjs) | #23 (M3-4) | Map one transaction to a suggested tax line. |
| [`lib/tax/confidence.mjs`](../lib/tax/confidence.mjs) | #19 | Turn a confidence score into a routing band. |
| [`lib/tax/estimatedTax.mjs`](../lib/tax/estimatedTax.mjs) | #25/#82 (M3-6) | Threshold math and quarterly estimated-tax dates. |

## 2. Schema reference

The tax profile's shape is defined by the canonical JSON Schema
([`assets/tax/tax-profile.schema.json`](../assets/tax/tax-profile.schema.json),
draft 2020-12, issue #20 / M3-1), with a matching TypeScript declaration in
[`assets/tax/tax-profile.d.ts`](../assets/tax/tax-profile.d.ts). The schema is
the authoritative reference for every constraint; this section documents each
field, its type, and its unit.

### Money units — dollars, never milliunits

**Every monetary amount in a tax profile is in US dollars.** YNAB's API (and
the vendored MCP) returns amounts in **milliunits** (1000 milliunits = $1);
the engine divides by 1000 internally before comparing anything against the
profile. Never put a milliunit figure in a profile.

**Rates are fractions**, not percentages and not dollars: `0.075` means 7.5%,
`0.153` means 15.3%.

### Field-by-field

Top-level fields (`schemaVersion`, `filingStatus`, and `taxYear` are
**required**; everything else is optional; unknown top-level keys are
rejected):

| Field | Type | Unit / notes |
| --- | --- | --- |
| `$readme` | `string[]` | Optional human-facing onboarding note (the bundled example carries one). `$`-prefixed annotation: the loader strips it before merging, so it never reaches a tax calculation. |
| `schemaVersion` | `string` \| `integer` | **Required.** Schema version the instance targets, so future migrations can detect older instances. |
| `filingStatus` | enum | **Required.** `single` \| `mfj` \| `mfs` \| `hoh` \| `qw`. |
| `taxYear` | `integer` (1900–9999) | **Required.** The profile is year-aware; year-keyed lookups use this. |
| `standardDeductionByYear` | object | `filingStatus → "YYYY" → number`. Values are **dollars**. |
| `businessEntities[]` | array of objects | Sole-prop / pass-through entities. Each requires `id` (stable string), `displayName` (placeholder text in anything committed), `schedule` (e.g. `"C"`), and `scheduleLineMap` (open object owned by the mapping engine; its `categoryGroups[]` / `accounts[]` arrays declare the entity's business YNAB structure). |
| `itemized` | object | Schedule A config. `medical.categoryGroups[]`, `salt.saltCap` (**dollars**, default `10000`) + `salt.categoryGroups[]`, `interest.categoryGroups[]`, `charitable.categoryGroups[]`. |
| `adjustments` | object | Schedule 1 config. `seTaxHalfDeduction.enabled` (boolean, default `true` — the amount is derived from computed SE tax, so no dollar figure here), `studentLoanInterest.amount` (**dollars**), `iraContributions.amount` (**dollars**). |
| `thresholds` | object | `medicalAgiPercent` (**fraction**, default `0.075`), `seTaxRate` (**fraction**, default `0.153`), `saltCap` (**dollars**, default `10000`; `itemized.salt.saltCap` overrides it when present). |
| `quarterlyEstimatedDueDates[]` | array of objects | Each requires `quarter` (1–4), `month` (1–12), `day` (1–31) as **date parts** — parts, not ISO strings, because Q1–Q3 due dates fall in the tax year while **Q4 falls in January of the following year**. Optional `periodStartMonth`/`periodStartDay`/`periodEndMonth`/`periodEndDay` carry the (uneven) income-attribution boundaries: Q1 Jan–Mar, Q2 Apr–May, Q3 Jun–Aug, Q4 Sep–Dec. |
| `incomeTaxBracketsByYear` | object | `filingStatus → "YYYY" → [{ upTo?, rate }]` **marginal** brackets, ascending; the top bracket omits `upTo` (unbounded). `upTo` is **dollars**; `rate` is a **fraction**. Consumed by the estimated-tax tracker (issue #82, [`docs/estimated-tax-tracker.md`](estimated-tax-tracker.md)). |
| `estimatedTaxPayments` | object | Detection matchers for estimated-tax payments already recorded in YNAB: `payeeKeywords[]` (case-insensitive **substring**), `categoryNames[]` / `categoryGroups[]` / `accounts[]` (case-insensitive **exact**). |
| `overrides` | object (open) | User-override layer, deep-merged **on top of** the defaults and the profile body by the loader — the highest-precedence tier. Any subset of the ruleset may be patched (including ruleset-only keys like `lines` and `mappingRules`); leaves are still type-checked. See [`docs/tax-profile-loader.md`](tax-profile-loader.md#merge-semantics-deterministic). |

### Minimal example

The smallest valid profile is just the three required fields:

```json
{
  "schemaVersion": "1",
  "filingStatus": "single",
  "taxYear": 2025
}
```

Everything else falls back to the bundled defaults
([section 3](#3-the-default-us-ruleset)).

### Full example

A fuller (fully anonymized — every name below is a placeholder) instance:

```json
{
  "schemaVersion": "1",
  "filingStatus": "mfj",
  "taxYear": 2025,
  "businessEntities": [
    {
      "id": "biz-a",
      "displayName": "Business A",
      "schedule": "C",
      "scheduleLineMap": {
        "categoryGroups": ["Category Group Placeholder 1"],
        "accounts": ["Account Placeholder — Business Checking"]
      }
    }
  ],
  "itemized": {
    "medical": { "categoryGroups": ["Category Group Placeholder — Medical"] },
    "salt": { "saltCap": 10000, "categoryGroups": ["Category Group Placeholder — Taxes"] },
    "interest": { "categoryGroups": ["Category Group Placeholder — Mortgage Interest"] },
    "charitable": { "categoryGroups": ["Category Group Placeholder — Charity"] }
  },
  "adjustments": {
    "seTaxHalfDeduction": { "enabled": true },
    "studentLoanInterest": { "amount": 0 },
    "iraContributions": { "amount": 0 }
  },
  "thresholds": {
    "medicalAgiPercent": 0.075,
    "seTaxRate": 0.153,
    "saltCap": 10000
  },
  "estimatedTaxPayments": {
    "payeeKeywords": ["irs", "us treasury", "estimated tax", "1040-es", "eftps"],
    "categoryNames": ["Estimated Taxes Placeholder"]
  },
  "overrides": {
    "thresholds": { "saltCap": 10000 },
    "mappingRules": [
      {
        "id": "my-accountant-fees",
        "match": { "payeeKeywords": ["bookkeeping placeholder"], "amountSign": "outflow" },
        "taxLineId": "schedC.17",
        "businessEntityId": "biz-a",
        "priority": 40,
        "confidence": 0.9,
        "reason": "Payee '{payee}' is my bookkeeper; classifying as Schedule C legal and professional services."
      }
    ]
  }
}
```

The committed template
[`assets/tax/tax-profile.example.json`](../assets/tax/tax-profile.example.json)
is the maintained version of this — copy it, don't retype it
([section 5](#5-customizing-your-profile)).

## 3. The default US ruleset

The bundled default US ruleset lives in
[`assets/tax/us-tax-lines.json`](../assets/tax/us-tax-lines.json) (issue #21 /
M3-2): the tax-line catalog the mapping engine maps onto, plus the default
`standardDeductionByYear` table, `thresholds`, `incomeTaxBracketsByYear`, and
`quarterlyEstimatedDueDates`. Purely declarative data — no code, no
per-taxpayer numbers.

### The line catalog

Line `id`s follow the `schedC.<line>` / `schedA.<bucket>` / `sched1.<key>` /
`schedSE` scheme, kept consistent with the profile schema's `itemized.*` and
`adjustments.*` keys:

| Line id | Schedule | Label |
| --- | --- | --- |
| `schedC.1` | C line 1 | Gross receipts or sales (income) |
| `schedC.8` | C line 8 | Advertising |
| `schedC.10` | C line 10 | Commissions and fees |
| `schedC.11` | C line 11 | Contract labor |
| `schedC.13` | C line 13 | Depreciation and section 179 expense deduction |
| `schedC.17` | C line 17 | Legal and professional services |
| `schedC.18` | C line 18 | Office expense |
| `schedC.22` | C line 22 | Supplies |
| `schedC.25` | C line 25 | Utilities |
| `schedC.27a` | C line 27a | Other expenses (catch-all, e.g. software/subscriptions) |
| `schedA.medical` | A | Medical and dental expenses |
| `schedA.salt` | A | State and local taxes (SALT) |
| `schedA.interest` | A | Home mortgage interest |
| `schedA.charitable` | A | Gifts to charity |
| `sched1.seTaxHalfDeduction` | 1 | Deductible part of self-employment tax |
| `sched1.studentLoanInterest` | 1 | Student loan interest deduction |
| `sched1.iraContributions` | 1 | IRA deduction |
| `schedSE` | SE | Self-employment tax (12.4% Social Security + 2.9% Medicare = 15.3%) |

Schedule C lines carry `appliesToBusinessEntities: true` (they attach to a
business entity); Schedule A / 1 / SE lines are household-level.

### How defaults are selected

- **Standard deduction:** `standardDeductionByYear` is keyed by filing status,
  then by four-digit year. The loader's
  `getStandardDeduction(year, filingStatus)` accessor selects the value using
  the profile's resolved `taxYear` and `filingStatus`. Values are dollars.
- **Thresholds:** `thresholds` supplies `medicalAgiPercent` (0.075),
  `seTaxRate` (0.153), and `saltCap` (10000). The federal SALT cap of $10,000
  is halved to $5,000 for MFS **by the engine downstream, by filing status** —
  the catalog stores the single base scalar.
- **Income-tax brackets:** `incomeTaxBracketsByYear` ships 2024 and 2025
  marginal brackets for every filing status (2024 per IRS Rev. Proc. 2023-34,
  2025 per Rev. Proc. 2024-40).
- **Quarterly due dates:** Apr 15 / Jun 15 / Sep 15 / **Jan 15 of the
  following year**, with the uneven income-attribution periods stored as data.

### Year keying

Everything year-sensitive is keyed by a **four-digit year string** under each
filing status. The profile's `taxYear` picks the row. **Adding a new tax year
is a pure data edit** — add a `"2026"` key with its dollar amount under each
filing status (or override just your own status/year in your profile,
[section 5](#5-customizing-your-profile)); no code change is involved.

## 4. The mapping engine

The mapping engine
([`lib/tax/classifyTransaction.mjs`](../lib/tax/classifyTransaction.mjs),
issue #23 / M3-4) takes one **already-fetched** YNAB transaction plus the
resolved profile and returns a suggestion:

```js
{ taxLineId: 'schedC.27a', businessEntityId: 'biz-a', confidence: 0.6,
  band: 'medium', matchedRuleId: 'dev-tools-saas-hosting', reason: "Payee 'DigitalOcean' …" }
```

Rules live in the bundled default ruleset
([`assets/tax/mapping-rules.json`](../assets/tax/mapping-rules.json), schema
[`assets/tax/mapping-rules.schema.json`](../assets/tax/mapping-rules.schema.json)),
overlaid by the user's own rules from the profile.
[`docs/mapping-engine.md`](mapping-engine.md) is the deep reference for the
engine; this section is the working summary.

### How rules match

A rule's `match` object holds one or more criteria; **every criterion present
must match (AND)**. Across a keyword *list*, ANY entry matching suffices.

| Criterion | Matches on | Semantics |
| --- | --- | --- |
| `payeeKeywords: [...]` | payee (`payee_name`) | ANY keyword. A plain string is a **case-insensitive substring**; a slash-wrapped string (`"/aws\|gcp/"`) is a **case-insensitive regex** (the `i` flag is always applied). A malformed regex — or one rejected by the ReDoS bound (issue #170) — degrades to a non-match, never a throw. |
| `categoryName` | category (`category_name`) | case-insensitive **exact** match |
| `categoryGroup` | category group (`category_group_name`) | case-insensitive **exact** match |
| `accountName` | account (`account_name`) | case-insensitive **exact** match |
| `amountSign` | amount | `"outflow"` (negative) or `"inflow"` (positive); a zero amount is neither |
| `amountThresholdDollars` | amount | `\|amount in dollars\| ≥ threshold` |
| `businessSignal: true` | category group / account | the transaction posts to a business category-group or account the profile declares (see `$profile` below) |

**All text matching is case-insensitive** — keywords, exact names, and regexes
alike. The difference between substring and regex is purely the slash
wrapping: `"github"` is a substring; `"/github|gitlab/"` is a regex.

**Amounts arrive in YNAB milliunits and are compared in dollars** — the engine
divides by 1000 first, so `amountThresholdDollars: 50` matches a `-100000`
milliunit (−$100) transaction but not a `-40000` (−$40) one.

### Priority and precedence

1. The **effective ruleset** is built: bundled defaults overlaid by user rules
   (matched by `id`), with `enabled: false` rules dropped.
2. Rules are evaluated in **ascending sort order**, and the **first matching
   rule wins**. The sort key, in order:
   1. `priority` (ascending — lower number wins)
   2. **source** — a user rule beats a bundled default at the same priority
   3. **match-type strength** — `categoryName` > `categoryGroup` ≈
      `businessSignal` > `accountName` > `payeeKeywords` > amount-only criteria
   4. **declaration order** (stable)

Full tie-breaking detail:
[`docs/mapping-engine.md`](mapping-engine.md#evaluation-order-precedence-and-tie-breaking).

### Confidence and the `unclassified` outcome

Each rule carries a `confidence` in `[0, 1]` (default `0.5`) — the rule
author's prior that a match really belongs on that line. Every result is then
annotated with a routing **band** by the confidence policy
([`lib/tax/confidence.mjs`](../lib/tax/confidence.mjs), contract in
[`docs/confidence-contract.md`](confidence-contract.md#the-bands)):

| Band | Rule (default thresholds) | Downstream behaviour |
| --- | --- | --- |
| `high` | `confidence ≥ 0.85` | Eligible to **pre-fill** a proposal op — still human-gated. |
| `medium` | `0.6 ≤ confidence < 0.85` | Rendered as "review suggested"; never pre-fills. |
| `low` | `0 < confidence < 0.6` | Flagged for human attention only. |
| `unclassified` | `confidence === 0` or the sentinel | Human attention only. |

When **no rule matches** — or the best match's confidence is below
`options.minConfidence` — the engine returns the explicit **`unclassified`
sentinel** (`taxLineId: "unclassified"`, `confidence: 0`,
`matchedRuleId: null`) rather than ever guessing a wrong line. Split
transactions and transfer legs are hard-coded to `band: 'unclassified'`
regardless of any computed score.

No band ever bypasses the human approval gate — confidence governs proposal
*composition* only.

### Worked example — a hosting vendor lands on `schedC.27a`

Say the review skill fetched this transaction (fields abridged; the payee is a
generic hosting vendor, not anyone's real ledger):

```json
{ "payee_name": "DigitalOcean", "amount": -24000, "category_name": null, "account_name": "Personal Checking" }
```

1. `-24000` milliunits → **−$24**, an outflow.
2. Priority 10, `business-category-or-account` (`businessSignal` +
   `amountSign: outflow`): the account/category-group is not one the profile's
   business entities declare → **no match**.
3. Priority 50, `dev-tools-saas-hosting`: `amountSign: outflow` ✓, and
   `payeeKeywords` contains `"digitalocean"` — a case-insensitive substring
   match against `DigitalOcean` ✓. **First match wins.**
4. The rule's `businessEntityId` is the `$profile` sentinel. This is a
   non-structural match, so it resolves to the **sole** business entity when
   the profile declares exactly one (here `biz-a`), and stays unset when zero
   or several exist — the engine never guesses *which* business.

Result:

```json
{
  "taxLineId": "schedC.27a",
  "businessEntityId": "biz-a",
  "confidence": 0.6,
  "band": "medium",
  "matchedRuleId": "dev-tools-saas-hosting",
  "reason": "Payee 'DigitalOcean' matches developer-tools / SaaS / hosting / domain keywords (matched 'digitalocean'); classifying as Schedule C other expenses."
}
```

`medium` band → the report shows it as "review suggested"; it never pre-fills
a write-back proposal.

### User rules override defaults

User rules live under `overrides.mappingRules` in the profile instance and are
overlaid **by `id`**:

- **Add** — a rule with a new `id` is appended to the effective ruleset.
- **Disable** — overlay a bundled `id` with `enabled: false`.
- **Replace / re-route / re-prioritize** — overlay a bundled `id`; the user
  rule **replaces the default wholesale** (lower its `priority` to outrank
  other rules, or point its `taxLineId` somewhere else).

Users never edit repo files to customize classification — the repo's defaults
stay generic and shareable.

## 5. Customizing your profile

All customization happens in **your profile instance** in the data dir — never
in repo files. Prerequisite: run
[`/workbench-ynab:setup`](../commands/setup.md) once so the plugin is
installed and configured.

**Create your instance** (first time):

```sh
mkdir -p ~/.claude/plugins/data/workbench-ynab-claude-workbench
cp assets/tax/tax-profile.example.json \
   ~/.claude/plugins/data/workbench-ynab-claude-workbench/tax-profile.json
```

The committed
[`assets/tax/tax-profile.example.json`](../assets/tax/tax-profile.example.json)
(issue #24 / M3-5) is the starting template — every value in it is an
anonymized placeholder. Then edit `tax-profile.json`:

1. **Set the required fields** — `filingStatus`, `taxYear` (and keep
   `schemaVersion` as shipped).
2. **Add a mapping rule** — append an object with a **new** `id` under
   `overrides.mappingRules` (see the `my-accountant-fees` example in
   [section 2](#2-schema-reference)). Give it a `match`, a `taxLineId` from
   the [line catalog](#the-line-catalog), a `priority`, and a `reason`
   template.
3. **Disable a bundled rule** — append an entry whose `id` matches the bundled
   rule (ids are in
   [`assets/tax/mapping-rules.json`](../assets/tax/mapping-rules.json)) with
   `enabled: false`.
4. **Reorder / re-route a bundled rule** — append an entry with the bundled
   `id` and your changed `priority` (lower = evaluated first) or `taxLineId`;
   it replaces the default wholesale, so restate the fields you want kept.
5. **Add a new business entity** — append to `businessEntities` with a fresh
   `id`, a `displayName`, `schedule: "C"`, and a `scheduleLineMap` whose
   `categoryGroups` / `accounts` name that entity's YNAB category groups and
   accounts. The `businessSignal` rule and `$profile` resolution pick it up
   from there.
6. **Override a threshold** — set e.g. `overrides.thresholds.saltCap` or
   `overrides.thresholds.medicalAgiPercent`. Remember: rates are fractions,
   caps are dollars.
7. **Override a standard-deduction year** — set
   `overrides.standardDeductionByYear.<filingStatus>.<YYYY>` to the dollar
   amount, e.g.:

   ```json
   "overrides": { "standardDeductionByYear": { "mfj": { "2026": 30500 } } }
   ```

The loader validates your instance against the schema on every load and
**fails loud** with the offending JSON path — it never proceeds with a
half-valid profile. To validate by hand, see
[validating an instance](../assets/tax/README.md) in the assets README. The
loader's precedence is always **defaults → your profile → your `overrides`**,
with per-leaf provenance recorded
([`docs/tax-profile-loader.md`](tax-profile-loader.md)).

## 6. Privacy

- **The real profile instance is personal financial data.** It contains your
  filing status, business structure, account and category names, and dollar
  figures. It must live **only** in the data dir
  (`~/.claude/plugins/data/workbench-ynab-claude-workbench/tax-profile.json`)
  and must **never be committed** — this repo is public.
- The repo's `.gitignore` blocks any `tax-profile.json` created inside the
  repo tree by mistake, and a regression test
  (`tests/unit/gitignore-tax-profile.test.sh`) pins that rule.
- The example file in the repo
  ([`assets/tax/tax-profile.example.json`](../assets/tax/tax-profile.example.json))
  is **fully anonymized** — placeholder names only, no real person, business,
  bank, account, or lender anywhere. Keep it that way in any contribution.
- **The YNAB token never goes in the profile.** It lives in the macOS Keychain
  (service `ynab-mcp`) and is injected by the launcher; tax config and the
  token are never co-located.

## 7. How the review skill consumes the engine

The M2 review skill
([`skills/review/ynab-review.md`](../skills/review/ynab-review.md)) is the
engine's primary consumer, through the **tax-engine facade**
([`lib/tax/index.mjs`](../lib/tax/index.mjs), issue #27) — a thin, stable
surface of exactly four exports: `loadEffectiveProfile`,
`classifyTransaction`, `classifyBatch`, `computeTaxSummary`.

The flow:

1. **Fetch** — the skill fetches transactions itself via the vendored MCP
   tools namespaced `mcp__plugin_workbench-ynab_ynab__*` (e.g.
   `ynab_list_transactions`). The engine is MCP-agnostic and only ever sees
   plain objects.
2. **Resolve the profile** — the skill calls `loadEffectiveProfile()` (the
   loader, issue #22 / M3-3) once to get the resolved, frozen profile:
   defaults ⊕ user profile ⊕ overrides, schema-validated, with provenance.
   On a bad profile it returns `ok: false` and the skill stops — no guessing.
3. **Classify** — the skill calls the classifier (issue #23 / M3-4) per
   transaction — `classifyBatch(txns, profile, { thresholds })` — getting one
   suggestion per transaction with `taxLineId`, `confidence`, `band`, and
   `reason`.
4. **Report and write-back** — bands govern what the report shows and what
   the proposal generator may pre-fill. Classification suggestions feed the
   **human-gated write-back flow** ([`/ynab-apply`](../commands/ynab-apply.md)):
   only `high`-band ops may pre-fill a proposal, and **every** proposal
   requires explicit human approval before anything is applied. The engine
   itself only suggests — it never writes.
5. **Summarize** — `computeTaxSummary(profile, ytdData)` composes the report's
   running YTD tax summary (Schedule C P&L, itemized-vs-standard, the medical
   AGI floor, SE tax, next quarterly payment) from the M3-6 primitives, with
   every rate and date coming from the resolved profile. The quarterly
   estimated-tax tracker ([`/ynab-tax`](../commands/ynab-tax.md),
   [`docs/estimated-tax-tracker.md`](estimated-tax-tracker.md)) consumes the
   same profile data.

### Logging — stderr only

The engine's modules write **nothing to stdout**, and any diagnostic output
ever added to them — or to any launcher/hook path around the vendored MCP —
must go to **stderr only**: **stdout is the JSON-RPC channel** for the
vendored MCP, and a single stray stdout byte corrupts the handshake. Keep this
rule intact when editing anything the MCP boot path touches.

---

> ⚠️ Estimates only — not tax advice. Consult a qualified professional before filing or paying.
