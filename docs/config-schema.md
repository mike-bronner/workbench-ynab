# `config.json` schema

The workbench-ynab configuration lives **outside the repository** at:

```
$HOME/.claude/plugins/data/workbench-ynab-claude-workbench/config.json
```

It lives there so it **survives plugin updates** — re-installing or upgrading
the plugin never touches the user's settings. The vendored YNAB MCP **cannot**
read this file; only the plugin's **skills and commands** do, through the shared
loader `bin/config.sh` (see [`config-loader.md`](config-loader.md)).

A machine-readable JSON Schema (draft-07) is provided for editor/tooling
validation at [`assets/config.schema.json`](../assets/config.schema.json), and a
complete, redacted example is at
[`assets/config.example.json`](../assets/config.example.json).

## Design rule: generic, not hardcoded

All tax logic is **data-driven**. The schema defines a *shape*; any one user's
situation — budget name, business name, persona name, tax figures — is a single
config **instance**, never a schema constant or a baked-in default. The prototype
this plugin productizes hardcoded a specific budget name, a specific side-business
and its checking account, and a specific persona voice. Here those are **config
fields**. You will find those prototype-specific names **only** as illustrative
instance values inside `assets/config.example.json` — never in this document, the
loader, the JSON Schema, or any default.

> **Scope note.** This issue owns the configuration **envelope + loader**. The
> deep, canonical tax sub-schema (full Schedule C/A/SE/1 line data, validation,
> defaults-merge) is owned by the Sprint 2 tax engine (issues #20–#23). The
> `tax_profile` and `mapping_rules` sections below define the top-level shape the
> loader exposes; Sprint 2 refines their interiors.

## Top-level keys

| Key | Type | Required | Summary |
|---|---|---|---|
| `schema_version` | integer | **required** | Config schema version, for forward migration. |
| `timezone` | string | **required** | IANA timezone — the single source of truth for all date math (window, carryover, month/quarter boundaries, tax year). |
| `budgets` | array | **required** | The YNAB budgets the plugin operates on (replaces the v1 singular `budget`). |
| `default_budget` | string | optional | `label` of the entry used when a caller needs a single budget. |
| `business` | object | optional | Side-business config (accounts, category group, expense categories). |
| `tax_profile` | object | **required** | Data-driven, generic tax parameters. |
| `mapping_rules` | array | optional | Payee/category → tax-line rules, expressed as data. |
| `persona` | object | **required** | The financial-review persona (configurable name). |
| `report` | object | **required** | Report output directory + template path. |
| `schedules` | object | optional | Scheduled-task cadences for background tasks (the unified `ynab-review` task and the `ynab-monitor` poll). |
| `alerts` | object | optional | Alert rules + delivery channel for proactive monitoring (M6). |
| `classification` | object | optional | Confidence-band thresholds for the human-review routing policy (issue #19). |

---

### `schema_version` *(integer, required)*

A monotonically increasing integer. Increment it when a breaking change to this
shape ships; `/workbench-ynab:setup` and downstream migration can then detect and
upgrade an older file. Current version: **`2`** (the multi-budget shape, issue
#84 — version 1 had a singular `budget` object; see the
[migration note](#migrating-a-v1-config-singular-budget) below).

---

### `timezone` *(string, required)*

An **IANA timezone identifier** — e.g. `America/Phoenix`, `America/New_York`,
`UTC` — mirroring `workbench-bujo`'s convention. It is the **single source of
truth for every date-sensitive computation** the review performs: the weekly
7-day lookback window, the carryover boundary, month start/end, the quarterly
estimated-tax windows, and the tax-year label (issue #31, design ref GAP-22).
All of these are computed **against the configured timezone, never the host
clock**, so a review is deterministic regardless of where or when it runs.

**Explicit default, never "system local".** `/workbench-ynab:setup` resolves
your machine's current IANA zone at setup time and pre-fills it, then writes the
**resolved identifier** into `config.json`. The stored value is always a concrete
zone name — it is *never* the literal string `system local` or an instruction to
re-read the host clock at run time — which is what keeps a scheduled run and an
interactive run on the same day in agreement. You may override it to any valid
IANA zone.

**Required, and validated fail-closed at load time.** The loader
([`bin/config.sh`](config-loader.md) `_cfg_timezone`) checks the value against the
tz database (`$TZDIR`, default `/usr/share/zoneinfo`) every time a review starts.
A **missing or invalid** timezone is a **hard error** — the loader prints a
descriptive message to stderr and returns non-zero — and the review stops. It
**never** silently falls back to the host clock: a wrong zone would misplace
near-midnight transactions in the lookback window and map a date to the wrong tax
year, so the plugin refuses to guess. The JSON Schema also carries a `pattern`,
but that is a shape check only; the loader's zoneinfo lookup is the authoritative
validity gate — and it verifies the name resolves to a compiled `TZif` zone
file, not merely that some file of that name exists, so zoneinfo housekeeping
artifacts (`leapseconds`, `+VERSION`, `tzdata.zi`) and the UTC-equivalent
pseudo-zones (`Factory`, `posixrules`) are rejected rather than silently
accepted.

The illustrative value `America/Phoenix` appears **only** as an instance value in
[`assets/config.example.json`](../assets/config.example.json) — never as a baked-in
default in the loader or schema (per the generic-not-hardcoded rule above).

```json
"schema_version": 2
```

---

### `budgets` *(array, required)*

The YNAB budgets this plugin operates on. **Replaces the schema-v1 singular
`budget` object**: config declares which budget(s) to target, and every skill
resolves its budget set from this array instead of assuming one budget. At
least one entry is required.

> **Scope note.** Per-budget overrides are **resolved by skills** as each skill
> is built (the review, monitor, and tax-tracker issues own their own budget
> iteration) — this config layer delivers the contract only: the shape, the
> loader helpers ([`config-loader.md`](config-loader.md)), and the migration.

Each entry:

| Field | Type | Required | Description |
|---|---|---|---|
| `budget_id` | string | one of id/name | YNAB budget id (UUID). Preferred when known — ids are rename-proof. |
| `budget_name` | string | one of id/name | Human-readable budget name as shown in YNAB; resolved to an id at runtime. |
| `label` | string | **required** | Human display string, unique across the array. The lookup key for `_cfg_budget_field` and `default_budget`. |
| `role` | string | **required** | Role/tag, e.g. `personal`, `business`, `archive`. Free-form; skills may group or filter by it. |
| `business_category_group` | string | optional | Per-budget override: YNAB category group holding this budget's business expense categories. |
| `tax_profile_path` | string | optional | Per-budget override: path to a tax-profile file linked to this budget (`~`/env-var expansion at use time), so Schedule C activity attributes to the correct budget. |
| `monitoring_enabled` | boolean | optional (default `true`) | Per-budget override: whether the monitoring poll covers this budget. |
| `write_back_enabled` | boolean | optional (default `true`) | Per-budget override: whether the write-back path may target this budget. The mandatory human approval gate applies regardless. |

```json
"budgets": [
  { "label": "Personal", "role": "personal",
    "budget_name": "<YOUR_PERSONAL_BUDGET_NAME>" },
  { "label": "Business", "role": "business",
    "budget_id": "<YOUR_BUSINESS_BUDGET_UUID>",
    "business_category_group": "Business Expenses",
    "write_back_enabled": false }
]
```

---

### `default_budget` *(string, optional)*

The `label` of the `budgets` entry to use when a caller needs a single budget
and does not specify one — the fallback that keeps single-budget users working
without naming a budget everywhere. When absent, the **first** `budgets` entry
is the default. A value matching no entry's `label` resolves to **nothing**
(the loader emits empty; a typo surfaces loudly rather than silently picking a
different budget).

```json
"default_budget": "Personal"
```

---

### Migrating a v1 config (singular `budget`)

An existing schema-v1 file — singular `budget`, no `budgets` key — **keeps
working without manual editing**. The loader ([`bin/config.sh`](config-loader.md))
applies the migration **at read time, in memory**: `_migrate_config` synthesizes
a single-entry `budgets` array from the legacy `budget.name`/`budget.id`
(`label` = the budget name, `role` = `personal` — the v1 shape modeled one
personal budget whose side-business lived in the `business` block). The file on
disk is **never rewritten** and its `schema_version` stays `1` — the migration
never auto-bumps it. Re-run `/workbench-ynab:setup` to upgrade the file itself
to the v2 shape.

---

### `business` *(object, optional)*

Side-business configuration. Omit the whole key if the user has no business.
Replaces the prototype's hardcoded business name, business checking account, and
expense categories.

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | optional | Business display name (report headings, Schedule C context). |
| `accounts` | string[] | optional | Names of YNAB accounts that belong to the business. |
| `category_group` | string | optional | Name of the YNAB category group holding business expense categories. |
| `expense_categories` | string[] | optional | YNAB categories treated as deductible business expenses. |

```json
"business": {
  "name": "<YOUR_BUSINESS_NAME>",
  "accounts": ["<YOUR_BUSINESS_CHECKING_ACCOUNT>"],
  "category_group": "<YOUR_BUSINESS_CATEGORY_GROUP>",
  "expense_categories": ["<CATEGORY_A>", "<CATEGORY_B>"]
}
```

---

### `tax_profile` *(object, required)*

Generic, data-driven tax parameters. Holds **only** filing status, **public** IRS
amounts/rates, due dates, and which schedules apply. It contains **no** personal
income figures, account ids, or names.

| Field | Type | Required | Description |
|---|---|---|---|
| `filing_status` | string (enum) | **required** | One of `single`, `married_filing_jointly`, `married_filing_separately`, `head_of_household`, `qualifying_surviving_spouse`. |
| `standard_deduction` | number | optional | Standard deduction for the filing status and tax year. A **public IRS figure** — set it to the current-year amount; the example ships `0.0` as a placeholder. |
| `medical_agi_threshold_pct` | number (0–1) | optional | Fraction of AGI above which unreimbursed medical expenses deduct on Schedule A (e.g. `0.075` = 7.5%). Public IRS rule. |
| `se_tax_rate` | number (0–1) | optional | Self-employment tax rate on net SE earnings (e.g. `0.153` = 15.3%). Public IRS rule. |
| `quarterly_due_dates` | string[] | optional | Estimated-tax due dates as `MM-DD` strings (year-agnostic; the active year is resolved at runtime). |
| `schedules` | string[] (enum) | **required** | Which schedules apply: any of `C`, `A`, `SE`, `1`. Non-empty. |

```json
"tax_profile": {
  "filing_status": "single",
  "standard_deduction": 0.0,
  "medical_agi_threshold_pct": 0.075,
  "se_tax_rate": 0.153,
  "quarterly_due_dates": ["04-15", "06-15", "09-15", "01-15"],
  "schedules": ["C", "A", "SE", "1"]
}
```

> The amounts and rates here are **public tax constants**, not personal data. Verify
> them against the current tax year before relying on them — this plugin is **not
> tax advice**.

---

### `mapping_rules` *(array, optional)*

Payee/category → tax-line rules expressed as **data, not code**. Each rule matches
transactions and assigns a schedule and a human-readable tax line. The full
matching engine and heuristics are owned by the Sprint 2 classifier (issue #23);
this envelope defines the array shape the loader exposes.

Each element:

| Field | Type | Required | Description |
|---|---|---|---|
| `match` | object | **required** | Match criteria; all present keys must match. |
| `match.payee_contains` | string | optional | Case-insensitive substring matched against the payee. |
| `match.category` | string | optional | Exact YNAB category name to match. |
| `match.category_group` | string | optional | Exact YNAB category group name to match. |
| `schedule` | string (enum) | optional | Schedule the matched transactions map onto (`C`/`A`/`SE`/`1`). |
| `tax_line` | string | optional | Tax line / roll-up label for matched transactions. |

```json
"mapping_rules": [
  { "match": { "category_group": "<YOUR_BUSINESS_CATEGORY_GROUP>" },
    "schedule": "C", "tax_line": "Schedule C — business expenses" },
  { "match": { "payee_contains": "pharmacy" },
    "schedule": "A", "tax_line": "Schedule A — medical & dental" }
]
```

---

### `persona` *(object, required)*

The financial-review persona. The **name is a config field, not a constant** — the
default voice is shipped by the persona skill (issue #36), and the user may rename
it here.

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | optional | Display name of the review persona. When omitted, the persona skill applies its shipped default name. Validated at config-load time (issue #28): **≤ 64 characters, no control characters** — setup fails loudly on a violation (`bin/persona.sh validate-name`). |
| `voice_overrides` | string \| null | optional | Free-text voice/tone notes layered on top of the shipped voice, **≤ 500 characters** (longer values are truncated with a logged warning). `null` to use the shipped voice. **Style only** — rendered into the model context as delimited DATA (`bin/persona.sh voice`); it can never authorize, expand, or alter a YNAB write (issue #28). |

```json
"persona": { "name": "<PERSONA_NAME>", "voice_overrides": null }
```

---

### `report` *(object, required)*

Report output configuration.

| Field | Type | Required | Description |
|---|---|---|---|
| `output_dir` | string | optional | Directory where generated HTML reports are written. Supports `~` and env-var expansion at use time. When absent or empty, the writer applies the shipped default `~/Documents/Claude/Reports` (see below). |
| `template_path` | string \| null | optional | Path to the frozen HTML report template. When `null`, the plugin's bundled template under `assets/` is used (frozen in Sprint 3, issue #42). |

```json
"report": { "output_dir": "~/Documents/Claude/Reports", "template_path": null }
```

`output_dir` lives **outside the repo** (this whole `config.json` does — see the
data-dir path above) and therefore **survives plugin updates**: it is the single,
update-stable source of truth for where reports are saved. The report writer
([`bin/report-writer.sh`](report-writer.md)) reads it through `bin/config.sh` with
the `// empty` idiom and falls back to `~/Documents/Claude/Reports` when it is
absent or empty.

---

### `schedules` *(object, optional)*

Cadences for the plugin's background scheduled tasks. The **setup step** (or a
`/workbench-ynab:setup` re-run) reads this block and deploys or syncs each task
via the scheduled-tasks MCP — cadence is **config-driven, never hardcoded** in a
skill or in the task deployment. Omit the whole block to accept the defaults.

#### `schedules.review` *(object, optional)*

The unified review (Sprint 3). **ONE** scheduled task (`ynab-review`) whose cron
fires `/workbench-ynab:ynab-review`; the read-only orchestrator decides which
tiers run that day (weekly, monthly, quarterly-tax, annual). It is **not** four
per-tier tasks — a single cadence covers them all, exactly like bujo's one
`bujo-ritual` task.

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `cron` | string | optional | `"0 7 * * 1"` | Cron expression for the unified review. Defaults to Monday 07:00 (the proven weekly cadence) when the block or field is absent. The orchestrator routes tiers, so this one cadence covers weekly/monthly/quarterly-tax/annual. |
| `enabled` | boolean | optional | `true` | Whether the `ynab-review` scheduled task is deployed. Set `false` and re-run setup to remove/disable the task; `ynab-monitor` is unaffected. |

```json
"schedules": { "review": { "cron": "0 7 * * 1", "enabled": true } }
```

#### `schedules.monitor` *(object, optional)*

The proactive between-run monitoring poll (M6). It runs more frequently than the
weekly review and is a **distinct** scheduled task (`ynab-monitor`), so it never
disturbs the weekly-review task (`ynab-review`).

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `cron` | string | optional | `"0 8 * * *"` | Cron expression for the monitoring poll. Defaults to daily at 08:00 when the block or field is absent. |
| `enabled` | boolean | optional | `true` | Whether the `ynab-monitor` scheduled task is deployed. Set `false` and re-run setup to remove/disable the task; `ynab-review` is unaffected. |

```json
"schedules": { "monitor": { "cron": "0 8 * * *", "enabled": true } }
```

---

### `alerts` *(object, optional)*

Alert rules and the delivery channel for proactive between-run monitoring (M6).
Thresholds are user-tunable data read **exclusively by the monitoring skill** —
never injected into the YNAB MCP launcher environment. Dollar amounts are
entered in **whole dollars** and converted to YNAB milliunits at load time
(`loadAlertsConfig()` in [`lib/monitor/alerts.mjs`](../lib/monitor/alerts.mjs) —
**not** `bin/config.sh`). Omit the whole block to accept the defaults —
monitoring works with no configuration. Invalid values fall back per field.

The full contract — field semantics, the structured finding shape, the
`dedupe_key` format, channel values, and the alert log — lives in
[`docs/alerts-config.md`](alerts-config.md).

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `enabled` | boolean | optional | `true` | Master switch for alert dispatch. |
| `large_transaction_amount` | number | optional | `500` | Single-transaction alert threshold, in **whole dollars**. |
| `unusual_multiplier` | number | optional | `3` | Multiple of a category's typical spend that counts as unusual. |
| `budget_overrun_pct` | number | optional | `100` | Percentage of budgeted amount at/beyond which a category is overrun. |
| `bill_due_lookahead_days` | integer | optional | `3` | Days ahead an upcoming scheduled bill is flagged. |
| `overdrawn` | boolean | optional | `true` | Whether a negative account balance is alert-worthy. |
| `channel` | string (enum) | optional | `"macos-notification"` | Delivery channel: `macos-notification` or `log-only`. Every dispatch also appends to the audit log. |

```json
"alerts": {
  "enabled": true,
  "large_transaction_amount": 500,
  "unusual_multiplier": 3,
  "budget_overrun_pct": 100,
  "bill_due_lookahead_days": 3,
  "overdrawn": true,
  "channel": "macos-notification"
}
```

---

### `classification` *(object, optional)*

Confidence-band thresholds for the classification → human-review routing policy
(issue #19; the full consumer contract lives in
[`docs/confidence-contract.md`](confidence-contract.md)). Read by
`loadThresholds()` in [`lib/tax/confidence.mjs`](../lib/tax/confidence.mjs) —
**not** by `bin/config.sh`. Confidence governs **proposal composition only**
(whether an op is pre-filled in the apply proposal); the human approval gate is
mandatory and independent of confidence. Omit the whole block to accept the
conservative shipped defaults. Invalid values — or a contradictory pair
(`mediumThreshold ≥ highThreshold`) — fall back to the defaults.

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `highThreshold` | number (0, 1] | optional | `0.85` | `confidence ≥ highThreshold` → band `high`: eligible for a pre-filled proposal op (still human-gated). |
| `mediumThreshold` | number (0, 1] | optional | `0.6` | `mediumThreshold ≤ confidence < highThreshold` → band `medium`: "review suggested" only, never pre-filled. Must be `< highThreshold`. |

```json
"classification": { "highThreshold": 0.85, "mediumThreshold": 0.6 }
```

---

## Validating a config

With a JSON Schema validator (e.g. [`ajv`](https://ajv.js.org/) or Python's
`jsonschema`):

```bash
# Python (no extra deps beyond `jsonschema`)
python3 -c 'import json,sys,jsonschema; \
  jsonschema.validate(json.load(open(sys.argv[1])), json.load(open(sys.argv[2])))' \
  assets/config.example.json assets/config.schema.json && echo "valid"
```

`assets/config.example.json` is kept valid against `assets/config.schema.json`;
the unit tests in `tests/unit/config.test.sh` also read it through the loader,
and `tests/unit/config-budgets.test.sh` covers the multi-budget helpers and the
v1→v2 read-time migration.
