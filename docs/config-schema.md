# `config.json` schema

The workbench-ynab configuration lives **outside the repository** at:

```
$HOME/.claude/plugins/data/workbench-ynab-claude-workbench/config.json
```

It lives there so it **survives plugin updates** — re-installing or upgrading
the plugin never touches the user's settings. The vendored YNAB MCP **cannot**
read this file; only the plugin's **skills and commands** do, through the shared
loader `bin/config.sh` (see [`config-loader.md`](config-loader.md)).

> **[`assets/config.schema.json`](../assets/config.schema.json) is the source of
> truth for field-by-field detail.** Every field's type, requiredness, default,
> constraints, and semantics live in that draft-07 schema's own `description`
> entries, where editors, validators, and tooling read them directly. This
> document is the human-readable companion: the design rules, an index of the
> top-level keys, worked examples, and the narrative a JSON Schema has no slot
> for. If the two ever diverge, **the schema wins** and this document must be
> corrected to match it — do not re-explain a field here.

A complete, redacted example config is at
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

An index only — one line per key. For each key's fields, types, defaults, and
constraints, read that key's `description` in
[`assets/config.schema.json`](../assets/config.schema.json).

| Key | Type | Required | Summary |
|---|---|---|---|
| `schema_version` | integer | **required** | Config schema version, for forward migration. |
| `timezone` | string | **required** | IANA timezone — the single source of truth for all date math (window, carryover, month/quarter boundaries, tax year). |
| `tax_year` | integer | optional | Pins the active tax year, overriding calendar-year derivation from the review date. Four digits. |
| `budgets` | array | **required** | The YNAB budgets the plugin operates on (replaces the v1 singular `budget`). |
| `default_budget` | string | optional | `label` of the entry used when a caller needs a single budget. |
| `business` | object | optional | Side-business config (accounts, category group, expense categories). |
| `tax_profile` | object | **required** | Data-driven, generic tax parameters. |
| `mapping_rules` | array | optional | Payee/category → tax-line rules, expressed as data. |
| `persona` | object | **required** | The financial-review persona (configurable name). |
| `report` | object | **required** | Report output directory, template path, and retention. |
| `schedules` | object | optional | Scheduled-task cadences for background tasks (the unified `ynab-review` task and the `ynab-monitor` poll). |
| `alerts` | object | optional | Alert rules + delivery channel for proactive monitoring (M6). |
| `apply` | object | optional | Overrides for the `/workbench-ynab:ynab-apply` approval command (M4-5). |
| `classification` | object | optional | Confidence-band thresholds for the human-review routing policy (issue #19). |

## Worked examples

One snippet per key, in the order above. These are illustrative instances, not
the contract — the contract is the schema.

---

### `schema_version` *(integer, required)*

```json
"schema_version": 2
```

---

### `timezone` *(string, required)*

```json
"timezone": "America/Phoenix"
```

The illustrative value `America/Phoenix` appears **only** as an instance value in
[`assets/config.example.json`](../assets/config.example.json) — never as a baked-in
default in the loader or schema (per the generic-not-hardcoded rule above).

---

### `budgets` *(array, required)*

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

```json
"persona": { "name": "<PERSONA_NAME>", "voice_overrides": null }
```

---

### `report` *(object, required)*

```json
"report": { "output_dir": "~/Documents/Claude/Reports", "template_path": null, "retention_days": 30 }
```

The report writer ([`bin/report-writer.sh`](report-writer.md)) reads `output_dir`
through `bin/config.sh`; [`bin/ynab-prune.sh`](../SECURITY.md#generated-artifacts)
sweeps the same directory under `retention_days`.

---

### `schedules` *(object, optional)*

Omit the whole block to accept the defaults.

#### `schedules.review` *(object, optional)*

```json
"schedules": { "review": { "cron": "0 7 * * 1", "enabled": true } }
```

One cadence covers every tier — the read-only orchestrator routes weekly,
monthly, quarterly-tax and annual out of a single `ynab-review` task, exactly
like bujo's one `bujo-ritual` task.

#### `schedules.monitor` *(object, optional)*

```json
"schedules": { "monitor": { "cron": "0 8 * * *", "enabled": true } }
```

---

### `alerts` *(object, optional)*

```json
"alerts": {
  "enabled": true,
  "large_transaction_amount": 500,
  "unusual_multiplier": 3,
  "budget_overrun_pct": 100,
  "bill_due_lookahead_days": 3,
  "overdrawn": true,
  "channel": "macos-notification",
  "tax": { "lead_time_days": 7, "reminders_enabled": true }
}
```

Read by `loadAlertsConfig()` in [`lib/monitor/alerts.mjs`](../lib/monitor/alerts.mjs)
— **not** `bin/config.sh`. The full contract (field semantics, the structured
finding shape, the `dedupe_key` format, channel values, and the alert log) lives
in [`docs/alerts-config.md`](alerts-config.md).

#### `alerts.tax` *(object, optional)*

Quarterly estimated-tax **payment reminders** (M6-5, issue #83). Both fields take
effect on the **next orchestrator/review run** — no code change. The reminder
fires within `lead_time_days` of a quarter's due date (🟡 attention) and escalates
to 🔴 on the due date when no payment is recorded, then stays silent once a payment
for that quarter lands in the tracker. It runs inside the unified `ynab-review`
scheduled task (`schedules.review`), so it adds **no** extra cron entry. Due dates
come from `tax_profile.quarterly_due_dates` — never hardcoded. Full contract:
[`alerts-config.md`](alerts-config.md).

---

### `classification` *(object, optional)*

```json
"classification": { "highThreshold": 0.85, "mediumThreshold": 0.6 }
```

The full consumer contract lives in
[`docs/confidence-contract.md`](confidence-contract.md).

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
