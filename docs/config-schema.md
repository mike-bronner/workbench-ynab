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
| `budget` | object | **required** | The target YNAB budget to review. |
| `business` | object | optional | Side-business config (accounts, category group, expense categories). |
| `tax_profile` | object | **required** | Data-driven, generic tax parameters. |
| `mapping_rules` | array | optional | Payee/category → tax-line rules, expressed as data. |
| `persona` | object | **required** | The financial-review persona (configurable name). |
| `report` | object | **required** | Report output directory + template path. |
| `schedules` | object | optional | Scheduled-task cadences for background tasks (e.g. the monitoring poll). |

---

### `schema_version` *(integer, required)*

A monotonically increasing integer. Increment it when a breaking change to this
shape ships; `/workbench-ynab:setup` and downstream migration can then detect and
upgrade an older file. Current version: **`1`**.

```json
"schema_version": 1
```

---

### `budget` *(object, required)*

The YNAB budget to review. Replaces the prototype's hardcoded budget name.

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | **required** | Human-readable budget name as shown in YNAB. |
| `id` | string \| null | optional | YNAB budget id (UUID). When `null`, the budget is resolved by `name`. |

```json
"budget": { "name": "<YOUR_BUDGET_NAME>", "id": null }
```

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
| `name` | string | **required** | Display name of the review persona. When omitted, the persona skill applies its shipped default name. |
| `voice_overrides` | object \| null | optional | Per-user voice/tone overrides. `null` to use the shipped voice. |

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
the unit tests in `tests/unit/config.test.sh` also read it through the loader.
