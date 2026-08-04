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
| Append cost | one line appended — no read, no parse | read-modify-**write** the whole file (O(n)) |
| Crash safety | each record is appended in one atomic, newline-terminated write **and fsync'd before the writer returns** — a crash leaves either the whole record or nothing, **never a partial line**, and never loses an already-returned record | a truncated rewrite can lose the **entire** history |
| Rewrites existing data? | **never** | every append |

Append-only integrity is the entire point of an audit log, so JSONL is the
correct shape. The writer only ever appends — it never rewrites,
truncates, or seeks. Each record is one compact line (`jq -c`, no interior
newlines), so the writer emits it plus its terminating newline in a **single
atomic `write(2)`** to an `O_APPEND` file descriptor, then **`fsync(2)`s that
descriptor before returning** (see [The durability
guarantee](#the-durability-guarantee)): a regular-file write of a
sub-page buffer is copied to the page cache uninterruptibly, so a crash leaves
either the whole newline-terminated record or nothing — **never a partial,
truncated line** — and the flush means a returned record survives a power cut,
not just a process crash. As belt-and-suspenders the writer also refuses to **fuse** a new
record onto a pre-existing dangling fragment (one left by an out-of-band
truncation, not by this writer): if the file does not already end in a newline it
prepends one, isolating the fragment on its own line — still strictly append-only,
adding bytes only at EOF.

## The durability guarantee

**When `_audit_append` returns `0`, the record is on stable storage.** Not merely
in the page cache — the writer `fsync(2)`s the file before it returns, once per
record ([#275](https://github.com/mike-bronner/workbench-ynab/issues/275)). Two
distinct properties hold together, on the same descriptor, in the same process:

| Property | What it defeats | How |
|---|---|---|
| **One atomic `write(2)`** to an `O_APPEND` fd | a **torn** record — half a line on disk | the record is one compact line (`jq -c`), written whole in a single `write(2)`; `O_APPEND` also positions every write at EOF atomically, so concurrent appenders never interleave |
| **`fsync(2)` before returning** | a **lost** record — a returned append still only in the page cache when the power cuts | the same fd is flushed to disk before the writer reports success |

Atomicity alone was never enough. The audit log is the forensic record of every
money mutation this plugin makes, and "we lost the last N records to a power cut"
is a materially worse outcome than a resume recomputing them.

**Fail-closed.** If the flush cannot happen, the append **fails** (non-zero,
diagnostic on `STDERR`) rather than reporting a success it cannot back:

- `python3` missing from `PATH` → refused before anything is created; **neither
  the record file nor the audit directory appears**. There is no fallback to an
  unflushed `>>`.
- the shim cannot open the file, or the write comes up short → non-zero, and the
  writer reports `append failed`. A short write is never fsync'd and called a
  success; the next append's no-fuse guard isolates the fragment on its own line.

### Why `python3`, not `dd conv=fsync`

Bash has no builtin that flushes a file to disk, so the append is delegated to a
small inline `python3 -c` program (`_audit_fsync_append_program`). `dd` was the
other candidate and **cannot do an fsync'd append on BSD/macOS**, which this
plugin targets — all three formulations fail there:

| Formulation | Result on BSD/macOS |
|---|---|
| `dd conv=fsync oflag=append of=FILE` | `dd: unknown open flag append` — `oflag=` is a GNU coreutils extension |
| `dd conv=fsync >> FILE` | `dd: fsyncing stdout: Invalid argument` — BSD `dd` won't fsync a descriptor it didn't open, so the write lands **unflushed** |
| `dd conv=fsync of=FILE` | **truncates** the audit log |

Even where `oflag=append` exists, `dd` copies block-wise and would split a record
larger than its block size across several `write(2)` calls, breaking the
single-atomic-write property above. `python3`'s `os.write` issues exactly one.

This adds `python3` to the plugin's runtime tools — `bash`, `node`, `jq`,
`security`, and now `python3` — all system binaries. No third-party package is
installed, and the no-`node_modules` guarantee in
[`docs/testing.md`](testing.md) is untouched.

### Throughput cost

Measured on macOS (APFS on NVMe), 200 sequential `_audit_append` calls, best of
three runs:

| | ms per record |
|---|---|
| Before (`>>`, no flush) | ~18–20 |
| After (single `write(2)` + `fsync(2)`) | ~47 |
| — of which: `python3` interpreter startup | ~25 |
| — of which: the `fsync(2)` itself | **~0.4** |

**Verdict: keep the flush per record; do not batch at run boundaries.** The
durability itself is nearly free (~0.4 ms). Essentially all of the +28 ms is
`python3` process startup, which batching *fsyncs* would not remove — only
batching *writes* would, and that trades away both the per-record trail and the
atomic-write property this design rests on. In context the cost is noise: every
audited operation is gated on a YNAB API round-trip measured in hundreds of
milliseconds, so ~28 ms of shim overhead per record sits below the noise floor of
a real apply run.

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
(`tests/unit/audit-log.test.sh`). Its only side effect is appending one record;
the audit dir and monthly file are created on first write if absent. Each record
is written as a single atomic, newline-terminated append **and flushed to stable
storage before the function returns**, so a crash never leaves a partial line, a
power cut never loses a record the writer already reported as written, and a new
record is never fused onto a pre-existing dangling fragment (see
[The durability guarantee](#the-durability-guarantee)).

| Argument | Shape | Notes |
|---|---|---|
| `operation_json` | a change-set operation (see [`assets/changeset-schema.json`](../assets/changeset-schema.json)) | `before`/`after` are stored **verbatim, in raw milliunits** |
| `result_json` | `{ tool, status, schema_version, run_id, error_class?, applied_state? }` | the write path's call descriptor + the change-set provenance it carries; the last two are present only on an errored op |
| `dry_run` | `true`\|`1`\|`yes` → `true`; else `false` | dry runs are logged too, flagged, so they leave a full paper trail |

`status` is stored verbatim as each record's `result_status`. Its full on-trail
vocabulary is five values from three producers:

| `result_status` | Written by |
|---|---|
| `applied` / `skipped-stale` / `blocked` / `error` | the frozen `STATUS` enum in [`assets/apply-executor.js`](../assets/apply-executor.js) — the authoritative definition of these four — passed by the executor's `recordAudit` and mirrored by [`assets/reconcile-handler.js`](../assets/reconcile-handler.js)'s `recordAudit` |
| `pending_delete` | the delete path's pre-delete **intent** record ([`assets/delete-duplicate.js`](../assets/delete-duplicate.js) `makeAuditingDeleteApplyOp`), appended before the irreversible delete runs so a destructive op leaves a two-phase trail ([#50](https://github.com/mike-bronner/workbench-ynab/issues/50)): intent before, outcome after |

The writer itself performs no validation or normalization of `status` — it is a
trusted pass-through (see `_audit_append`); a raw MCP call status such as
`success` is never a valid input.

On an **errored** op the executor also stamps two auth-failure fields (GAP-8 / #50),
which the writer persists verbatim (both default to `null` on a non-error op):

| Field | Values | Meaning |
|---|---|---|
| `error_class` | `auth_revoked` / `insufficient_scope` / `rate_limited` / `unknown` | the failure class the executor classified the thrown port error into |
| `applied_state` | `not_applied` / `unknown` | `not_applied` when YNAB rejected the call (a 4xx, so nothing changed); `unknown` when it can't be determined (a 5xx or a network timeout mid-mutation) |

These two are the substrate the idempotent-resume design ([#48](https://github.com/mike-bronner/workbench-ynab/issues/48)) reads to decide **which recovery path a failed op takes**: `not_applied` means YNAB rejected the call and nothing changed, so the op is simply un-applied and is dispatched normally; `unknown` means the write may or may not have landed, which is the "interleaving A" case that must be resolved against **live YNAB state** before the op is skipped or re-applied. The fields route the decision — they do not replace the live-state check, which resume performs for every op (see [`docs/write-back-idempotency.md`](./write-back-idempotency.md)).

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
