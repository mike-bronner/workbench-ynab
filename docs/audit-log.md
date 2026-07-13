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
names, account and transaction ids — the writer keeps the audit dir **0700** and
every `audit-YYYY-MM.jsonl` file **0600** (owner-only), so the trail is not
world-readable. It both creates them owner-only (a subshell-scoped `umask 077`
plus `mkdir -m 700`) **and** `chmod`s them on every append, so a pre-existing dir
or file left at a looser mode is tightened rather than silently trusted — `mkdir
-m`/`umask` only bite at creation. The 0700 dir is the real access boundary; the
0600 file is defense-in-depth.

## Why JSONL (one object per line), not a single JSON array

| | JSONL (append one line) | One growing JSON array |
|---|---|---|
| Append cost | `>>` one line — no read, no parse | read-modify-**write** the whole file (O(n)) |
| Crash safety | each record is appended in one atomic, newline-terminated write — a crash leaves either the whole record or nothing, **never a partial line** | a truncated rewrite can lose the **entire** history |
| Rewrites existing data? | **never** | every append |

Append-only integrity is the entire point of an audit log, so JSONL is the
correct shape. The writer only ever `>>`-appends — it never rewrites,
truncates, or seeks. Each record is one compact line (`jq -c`, no interior
newlines), so the writer emits it plus its terminating newline in a **single
atomic `write(2)`** to an `O_APPEND` file descriptor: a regular-file write of a
sub-page buffer is copied to the page cache uninterruptibly, so a crash leaves
either the whole newline-terminated record or nothing — **never a partial,
truncated line**. As belt-and-suspenders the writer also refuses to **fuse** a new
record onto a pre-existing dangling fragment (one left by an out-of-band
truncation, not by this writer): if the file does not already end in a newline it
prepends one, isolating the fragment on its own line — still strictly append-only,
adding bytes only at EOF.

The read helpers stay defensively lenient regardless: a partial, unterminated
**trailing** line (all an out-of-band truncation could leave) is **skipped** and
every complete record before it is still emitted (see
[Reading the log](#reading-the-log)), while a malformed line in the **body** —
corruption an audit trail must not silently swallow — is surfaced loudly instead.
The writer's single-write guarantee means a crash mid-append no longer produces a
torn line for them to tolerate.

## The writer — `_audit_append <operation_json> <result_json> <dry_run>`

A **pure function of its three inputs**: it reads no external state and never
touches a YNAB API, so it is unit-testable in isolation
(`tests/unit/test-audit-log.sh`). Its only side effect is appending one record;
the audit dir and monthly file are created on first write if absent. Each record
is written as a single atomic, newline-terminated append, so a crash never leaves
a partial line and a new record is never fused onto a pre-existing dangling
fragment (see [Why JSONL](#why-jsonl-one-object-per-line-not-a-single-json-array)).

| Argument | Shape | Notes |
|---|---|---|
| `operation_json` | a change-set operation (see [`assets/changeset-schema.json`](../assets/changeset-schema.json)) | `before`/`after` are stored **verbatim, in raw milliunits** |
| `result_json` | `{ tool, status, schema_version, run_id, error_class?, applied_state? }` | the executor's call descriptor + the change-set provenance it carries; the last two are present only on an errored op |
| `dry_run` | `true`\|`1`\|`yes` → `true`; else `false` | dry runs are logged too, flagged, so they leave a full paper trail |

On an **errored** op the executor also stamps two auth-failure fields (GAP-8 / #50),
which the writer persists verbatim (both default to `null` on a non-error op):

| Field | Values | Meaning |
|---|---|---|
| `error_class` | `auth_revoked` / `insufficient_scope` / `rate_limited` / `unknown` | the failure class the executor classified the thrown port error into |
| `applied_state` | `not_applied` / `unknown` | `not_applied` when YNAB rejected the call (a 4xx, so nothing changed); `unknown` when it can't be determined (a 5xx or a network timeout mid-mutation) |

These two are the substrate the idempotent-resume design ([#48](https://github.com/mike-bronner/workbench-ynab/issues/48)) reads to reason about a failed op without re-querying.

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
  "result_status": "applied",
  "error_class": null,
  "applied_state": null,
  "dry_run": false
}
```

`error_class` and `applied_state` are `null` on a successful or dry-run record and
carry a value only when `result_status` is `error` (see the writer contract above).

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
caller wanting an array can pipe through `jq -s`. They are defensively lenient:
a partial, unterminated **trailing** line (defense-in-depth — the writer's atomic
append means a crash no longer produces one; only an out-of-band truncation could)
is **skipped**, and every complete record before it is still emitted. Every **body**
line must be a JSON **object**: a line that fails to parse — or that parses to
valid-but-non-object JSON such as the literal `null` (which would otherwise
fabricate a phantom `{"before":null,"after":null}` record or be silently dropped)
— is interior corruption, not a crash artifact, so it is reported on `STDERR` with
the `audit-log:` prefix (alongside jq's own detail) and **fails the read**, never
silently swallowed.

The raw log keeps milliunit integers; only the read path divides by 1000, so the
on-disk record stays the exact value that was applied.

## Test seams

Production leaves these unset; tests set them for determinism:

| Env var | Overrides |
|---|---|
| `YNAB_AUDIT_DIR` | the audit directory |
| `YNAB_AUDIT_MONTH` | the `YYYY-MM` month key |
| `YNAB_AUDIT_TIMESTAMP` | the record timestamp |
