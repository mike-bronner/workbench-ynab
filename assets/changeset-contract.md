# Change-Set Contract — workbench-ynab write-back (M4)

The **change-set** is the single canonical, versioned data structure that every
Sprint 4 (M4) write-back path speaks. Proposal, approval, dry-run, apply, and
audit all read and write the same envelope, so there is exactly one shape to
learn, validate, and reason about.

This document is the contract. The machine-readable schema lives next to it at
[`changeset-schema.json`](./changeset-schema.json); worked examples live under
[`fixtures/`](./fixtures/); the reusable validator is
[`validate-changeset.js`](./validate-changeset.js).

> **This issue (M4-1) defines the contract and nothing else.** It produces no
> writes and calls no MCP tools. Every other M4 issue *consumes* this schema.

---

## 1. What a change-set is — and its lifecycle

A change-set is an **envelope** carrying an **ordered list of typed
operations**. Each operation is a single, reviewable, ledger-only change to a
YNAB budget: re-categorize a transaction, set a category's monthly budgeted
amount, delete a duplicate transaction, or reconcile an account. The envelope
records provenance (when it was generated, which budget, and whether a review
run or a human produced it) and asserts the hard invariant that no change-set
ever moves real money.

The change-set flows through a fixed lifecycle. **No stage may be skipped**, and
human approval gates the transition from proposal to any write:

1. **Produce** — the review engine (or a human, `source: "manual"`) emits a
   change-set: an ordered list of proposed operations, each with a `before`
   snapshot, an `after` proposal, a one-line `rationale`, and a `risk` tag.
2. **Propose** — the change-set is surfaced to the human for review. Nothing has
   touched the ledger yet.
3. **Approve** — the human explicitly approves the batch (locked decision: each
   change batch is gated by explicit human approval). Approval is what unlocks
   the apply path.
4. **Dry-run** — apply runs in dry-run mode **by default**, reporting exactly
   what would change without calling any write tool.
5. **Apply** — the approved operations are applied **in array order** via the
   namespaced YNAB MCP tools (§3). Destructive operations (§5) require extra
   confirmation.
6. **Audit** — the applied change-set (with per-operation results) is appended
   to the audit log for a durable, replayable record.

The `id` on every operation is stable, so apply can be **idempotent on resume**:
a re-run skips operations already recorded as applied in the audit log.

---

## 2. Money is always milliunits

Every monetary field — `amount`, `budgeted`, `cleared_balance`,
`reconciled_balance` — is a **YNAB milliunit integer**, never a float.

- Milliunits are YNAB's native money unit: **divide by 1000 for display.**
  `250000` → `$250.00`; `-54990` → `-$54.99`.
- The schema types every monetary field as `integer` (see the `milliunits`
  definition in `changeset-schema.json`) and rejects floats. **Never store a
  pre-divided float** like `250.00` — it loses precision and breaks the apply
  path.
- Negative amounts are outflows; positive amounts are inflows, exactly as YNAB
  reports them.
- A single shared money helper (centralized milliunits → currency formatting,
  tracked separately in the backlog) owns display conversion. Change-set
  artifacts always carry raw milliunits.

---

## 3. Apply uses the **namespaced** MCP tools — never `mcp__ynab__*`

Downstream apply code calls the YNAB MCP through its **fully namespaced** tool
names. The MCP is vendored into this plugin and exposed under the
`plugin_workbench-ynab_ynab` namespace, so the correct names are:

- `mcp__plugin_workbench-ynab_ynab__ynab_update_transaction`
- `mcp__plugin_workbench-ynab_ynab__ynab_update_transactions`
- `mcp__plugin_workbench-ynab_ynab__ynab_update_category`
- `mcp__plugin_workbench-ynab_ynab__ynab_delete_transaction`
- `mcp__plugin_workbench-ynab_ynab__ynab_reconcile_account`

> ⚠️ **Do not use the bare `mcp__ynab__*` names.** They will not resolve against
> the vendored, namespaced MCP. Consumers must hardcode the
> `mcp__plugin_workbench-ynab_ynab__*` namespace shown above.

### Operation → apply tool mapping

| Operation type     | Apply tool(s)                                                          | Consumed by |
|--------------------|-----------------------------------------------------------------------|-------------|
| `categorize`       | `ynab_update_transaction` / `ynab_update_transactions`                 | M4-6        |
| `allocate`         | `ynab_update_category`                                                 | M4-7        |
| `delete_duplicate` | `ynab_delete_transaction`                                              | M4-8        |
| `reconcile`        | `ynab_reconcile_account` + `ynab_update_transaction(s)`                | M4-9        |

(Tool names above are shown unqualified for readability; apply code must use the
fully namespaced `mcp__plugin_workbench-ynab_ynab__*` form from the list above.)

---

## 4. The `money_movement: false` invariant

Every change-set carries `money_movement: false` as a **schema const** — the
field cannot hold any other value and a change-set that sets it `true` fails
validation outright.

This is the structural half of the M4 safety promise: write-back is **strictly
ledger-only** (categorize / allocate / dedup / reconcile). The plugin never
initiates transfers or payments. The **M4-2 write-safety guardrail** is the
runtime half: before any apply runs, it asserts `money_movement === false` (and
that no operation maps to a money-moving tool) and hard-blocks otherwise. The
schema makes a money-moving change-set unrepresentable; the guardrail makes a
money-moving apply impossible. Both must hold.

---

## 5. Risk tags

Every operation carries a `risk` tag: `low`, `medium`, or `destructive`.

- `delete_duplicate` is **always** `destructive` — the schema pins it with a
  `const`, so a `delete_duplicate` operation tagged anything else fails
  validation.
- Apply treats `destructive` operations specially: they require extra
  confirmation beyond batch approval before the delete is executed.

---

## 6. Envelope and operation shapes

### Envelope (required top-level fields)

| Field            | Type                | Notes                                                        |
|------------------|---------------------|-------------------------------------------------------------|
| `schema_version` | string (semver)     | `MAJOR.MINOR.PATCH`; see §7.                                 |
| `generated_at`   | string (date-time)  | ISO 8601 / RFC 3339.                                         |
| `budget_id`      | string              | Target budget; every operation's `budget_id` must match.    |
| `budget_name`    | string              | Display + audit.                                             |
| `source`         | string              | Review run id, or the literal `"manual"`.                    |
| `money_movement` | boolean `const false` | The §4 invariant.                                         |
| `operations`     | array (min 1 item)  | Ordered; applied in array order.                            |

### Operation (shared required fields, every type)

`id`, `type`, `budget_id`, `before`, `after`, `rationale`, `risk` — plus the
**target entity id(s)** that each type requires:

| Type               | Required target(s)                          | `before` / `after` carry                                  |
|--------------------|---------------------------------------------|----------------------------------------------------------|
| `categorize`       | `transaction_id`                            | category id/name before → proposed category              |
| `allocate`         | `category_id`, `month` (`YYYY-MM-01`)       | budgeted milliunits before → proposed budgeted           |
| `delete_duplicate` | `transaction_id`                            | full transaction snapshot → `{ "deleted": true }`        |
| `reconcile`        | `account_id` (optional `transaction_ids[]`) | cleared/reconciled balances + status before → after      |

The schema discriminates the four subtypes with a `oneOf` keyed on the `type`
`const`, so exactly one subtype schema matches each operation and each enforces
its own required target id(s).

---

## 7. Versioning — `schema_version`

`schema_version` is **semantic versioning** (`MAJOR.MINOR.PATCH`) for the
change-set schema itself. Increment it whenever `changeset-schema.json` changes:

- **MAJOR** — a breaking change: a removed or renamed field, a new required
  field, a tightened type, a removed operation type, or any change that makes a
  previously-valid change-set invalid. Consumers must be updated in lockstep.
- **MINOR** — a backward-compatible addition: a new optional field, a new
  operation type, or a relaxed constraint that keeps all previously-valid
  change-sets valid.
- **PATCH** — a non-structural change: clarified `description` text, corrected
  annotations, documentation-only edits.

Producers stamp the version they emitted; consumers should check `schema_version`
and refuse a MAJOR they do not understand. The current schema version is
**`1.0.0`**.

---

## 8. Validation

### Chosen validator: Ajv

The reusable validator [`validate-changeset.js`](./validate-changeset.js) uses
**[Ajv](https://ajv.js.org)** — the de-facto JSON Schema validator for the
JavaScript/Node ecosystem the rest of the plugin runs on — via its **JSON Schema
2020-12** dialect (`ajv/dist/2020`) plus **[ajv-formats](https://github.com/ajv-validator/ajv-formats)**
for `date` and `date-time` format checking. Dependencies and pinned versions are
declared in [`package.json`](./package.json) (`ajv` 8.17.1, `ajv-formats`
3.0.1), so any plugin code can `require` the validator and reject malformed
change-sets (M4-4 / M4-5 rely on this).

`validateChangeset(changeset)` returns a structured result:

```js
const { validateChangeset } = require('./assets/validate-changeset');
const { valid, errors } = validateChangeset(myChangeSet);
// valid: boolean
// errors: [{ path, keyword, message, params }, ...]  (empty when valid)
```

### Running it

Install the dependency and validate the example fixtures:

```sh
npm --prefix assets install
npm --prefix assets run validate:fixtures
# or directly:
node assets/validate-changeset.js assets/fixtures/categorize.example.json
```

The schema is plain JSON Schema 2020-12, so it can equally be validated by any
conformant validator (e.g. Python's `jsonschema` with `Draft202012Validator`)
for CI in non-Node contexts.

---

## 9. Worked example fixtures

[`fixtures/`](./fixtures/) holds at least one valid change-set per operation
type — they double as test fixtures for downstream M4 issues:

| Fixture                          | Demonstrates                                  |
|----------------------------------|-----------------------------------------------|
| `categorize.example.json`        | a single `categorize` operation               |
| `allocate.example.json`          | a single `allocate` operation                 |
| `delete-duplicate.example.json`  | a single `delete_duplicate` (destructive)     |
| `reconcile.example.json`         | a single `reconcile` operation                |
| `combined.example.json`          | all four types in one ordered envelope         |

Every fixture validates against the schema (verified by the validator above).

---

## 10. File layout

All change-set artifacts live under `assets/`, mirroring the `workbench-bujo`
convention of keeping templates and contracts under `assets/`. None of this
content lives under `docs/`.

```
assets/
├── changeset-schema.json     # the JSON Schema (Draft 2020-12) — the machine contract
├── changeset-contract.md     # this document — the human contract
├── validate-changeset.js     # reusable Ajv validator (library + CLI)
├── package.json              # validator dependency (ajv, ajv-formats)
└── fixtures/                 # worked examples / test fixtures, one per op type
    ├── categorize.example.json
    ├── allocate.example.json
    ├── delete-duplicate.example.json
    ├── reconcile.example.json
    └── combined.example.json
```
