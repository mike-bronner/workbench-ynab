# `bin/audit-log.sh` — the write-back audit log

`bin/audit-log.sh` is the **append-only evidence trail** for approval-gated
write-back (Sprint 4 / M4). For every operation the apply executor (M4-4) acts
on — real **or** dry-run — it appends exactly **one** structured JSONL record
capturing what changed, when, and the before/after values, so Mike can review,
reverse, or dispute any mutation later, and a misbehaving write path leaves a
paper trail for debugging.

It is a **sourceable** bash helper, in the same family as
[`bin/config.sh`](config-loader.md) and `bin/persona.sh`. Sourcing it only
**defines** functions and never runs `set -e`/`set -u` or any side-effecting
command at load time, so it cannot abort or mutate the caller's shell. Run
directly, it dispatches the read-helper CLI.

## Where the log lives — under the plugin **data** dir, never the repo

```
~/.claude/plugins/data/workbench-ynab-claude-workbench/audit/audit-YYYY-MM.jsonl
```

One file per **UTC** month. **Both `config.json` and the audit log live under the
plugin data directory — outside this repo — so they survive plugin updates.**
Nothing about a user's budget history belongs in the repo. The path is resolved
HOME-relative via the same workbench-core pattern the config loader uses (see
`workbench-core/hooks/mcp-memory.sh` lines 66–76); it is never hard-coded and
never points inside the repo.

Because each record persists financial data — before/after milliunits, category
names, account and transaction ids — the writer creates the audit dir **0700**
and every `audit-YYYY-MM.jsonl` file **0600** (owner-only), so the trail is not
world-readable by default.

## Why JSONL (one object per line), not a single JSON array

| | JSONL (append one line) | One growing JSON array |
|---|---|---|
| Append cost | `>>` one line — no read, no parse | read-modify-**write** the whole file (O(n)) |
| Crash safety | a kill mid-write leaves at most one partial **trailing** line, which the readers skip — every complete record before it still reads back | a truncated rewrite can lose the **entire** history |
| Rewrites existing data? | **never** | every append |

Append-only integrity is the entire point of an audit log, so JSONL is the
correct shape. The writer only ever `>>`-appends — it never rewrites,
truncates, or seeks. Because each complete record is newline-terminated, the
only thing a crash mid-append can leave is one **unterminated trailing** line;
the read helpers skip exactly that line (see [Reading the log](#reading-the-log))
and emit every record before it. A malformed line in the **body** is a
different matter — corruption an audit trail must not silently swallow — so the
readers surface it loudly instead.

## The writer — `_audit_append <operation_json> <result_json> <dry_run>`

A **pure function of its three inputs**: it reads no external state and never
touches a YNAB API, so it is unit-testable in isolation
(`tests/unit/test-audit-log.sh`). Its only side effect is appending one record;
the audit dir and monthly file are created on first write if absent.

| Argument | Shape | Notes |
|---|---|---|
| `operation_json` | a change-set operation (see [`assets/changeset-schema.json`](../assets/changeset-schema.json)) | `before`/`after` are stored **verbatim, in raw milliunits** |
| `result_json` | `{ tool, status, schema_version, run_id }` | the executor's call descriptor + the change-set provenance it carries |
| `dry_run` | `true`\|`1`\|`yes` → `true`; else `false` | dry runs are logged too, flagged, so they leave a full paper trail |

`STDOUT` is left untouched (reserved for the read helper); diagnostics go to
`STDERR`; a non-zero exit signals a build/append failure.

### Record shape

Every record contains exactly these fields:

```json
{
  "timestamp": "2026-06-15T12:00:00Z",
  "schema_version": "1.0.0",
  "run_id": "run-A",
  "operation_id": "op-cat-1",
  "operation_type": "categorize",
  "target_entity_ids": ["txn-1"],
  "before": { "category_id": null, "category_name": null },
  "after":  { "category_id": "c9", "category_name": "Groceries" },
  "tool": "mcp__ynab__ynab_update_transaction",
  "result_status": "success",
  "dry_run": false
}
```

`target_entity_ids` is derived from whichever id fields the operation carries:
`transaction_id` / `category_id` / `account_id`, followed by any
`transaction_ids` (so a `reconcile` op records `[account_id, …transaction_ids]`).

## Reading the log

Two read helpers, both formatting **milliunits ÷ 1000** for human display
(`budgeted`, `amount`, `cleared_balance`, `reconciled_balance`) and printing to
`STDOUT`:

```bash
# As library functions (after `source bin/audit-log.sh`):
_audit_read_last 10        # last N records from the current UTC month
_audit_read_run  run-A     # every record for a run id, across ALL months

# As a CLI:
bash bin/audit-log.sh last 10
bash bin/audit-log.sh run run-A
```

Both helpers print **JSONL** (one JSON object per line), not a JSON array — a
caller wanting an array can pipe through `jq -s`. They tolerate a crash:
a partial, unterminated **trailing** line (all a kill mid-append can leave) is
**skipped**, and every complete record before it is still emitted. A malformed
line in the **body** — interior corruption, not a crash artifact — is instead
reported on `STDERR` with the `audit-log:` prefix (alongside jq's own detail)
and fails the read, so the corruption is never silently swallowed.

The raw log keeps milliunit integers; only the read path divides by 1000, so the
on-disk record stays the exact value that was applied.

## Test seams

Production leaves these unset; tests set them for determinism:

| Env var | Overrides |
|---|---|
| `YNAB_AUDIT_DIR` | the audit directory |
| `YNAB_AUDIT_MONTH` | the `YYYY-MM` month key |
| `YNAB_AUDIT_TIMESTAMP` | the record timestamp |
