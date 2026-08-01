# Change-Set Lifecycle — selection, staleness, retention & status (GAP-10)

The [change-set **contract**](./changeset-contract.md) (M4-1) defines the shape of
a single proposal envelope — provenance plus an ordered list of typed operations.
This document defines the **lifecycle of the proposal *files* around that
envelope**: when several proposals exist, which one `/ynab-apply` targets; when a
proposal is too stale to apply at all; how applied and superseded proposals are
retired so the live directory never fills with ambiguous candidates; and the
single **proposal-status model** every write-back component reads and writes.

> **This issue (GAP-10) defines the lifecycle and nothing else.** Like the M4-1
> contract, it produces no writes and calls no MCP tools. Its consumers *wire* it:
> the review emitter ([M4-10](#appendix--consumer-wiring)) writes proposals and the
> initial status; [`/ynab-apply`](../commands/ynab-apply.md) (M4-5) selects,
> staleness-gates, applies, and advances status; and the resume / lock / errored-op
> work (GAP-11 / GAP-9 / GAP-8) reads and writes the same status model. Where this
> spec names a config key or an envelope field a consumer must add, that addition is
> called out as coordination — it is not shipped here.

Two invariants frame everything below:

- **The change-set envelope is immutable after generation.** What the human
  reviewed and approved is exactly what stays on disk. Lifecycle status is
  therefore tracked *beside* the envelope (a sidecar file + the file's directory),
  **never by mutating the frozen, `additionalProperties: false` envelope**.
- **Global staleness rejects a *whole* proposal; per-op drift skips a *single*
  op.** They are distinct gates at distinct layers (§5). A proposal can be globally
  fresh and still carry individually stale ops.

---

## 1. Where proposals live, and how they are named

Proposals live under the plugin **data** dir — outside the repo, so they survive
plugin updates and never carry a user's budget history into version control — in
the proposal directory the apply command already resolves:

```text
$PROPOSAL_DIR = $CONFIG_DIR/proposals        # default
             = <.apply.proposal_path>        # when the config key overrides it
$CONFIG_DIR   = $HOME/.claude/plugins/data/workbench-ynab-claude-workbench
```

The directory has exactly three roles, one per retention state (§6):

```text
proposals/                      # ACTIVE — candidates only (status: pending | partial)
├── changeset-<stamp>.json      #   an immutable change-set envelope (M4-1)
├── changeset-<stamp>.status.json   #   its mutable status sidecar (§2)
├── applied/                    # RETIRED — fully applied (status: applied)
└── superseded/                 # RETIRED — displaced or discarded (status: superseded | discarded)
```

**Filename.** A proposal file is `changeset-<stamp>.json`, where `<stamp>` is the
envelope's `generated_at` compacted to a sortable UTC token
(`2026-06-19T14:30:00Z` → `changeset-2026-06-19T143000Z.json`). The date-only form
the tracking issue sketched (`changeset-YYYY-MM-DD.json`) is a human shorthand;
the authoritative form carries the **time** so two reviews on one day never
collide, and if a same-second collision is ever possible the emitter appends a
short `source` disambiguator (`…143000Z-<source>.json`).

**The filename is a convenience, never the source of truth.** Selection and
staleness (§3, §4) sort and age on the envelope's `generated_at` and `source`
fields — a mis-named or clock-skewed file cannot defeat ordering, because the name
is never trusted for it.

---

## 2. Proposal status — the lifecycle state model

A **proposal-level status** describes the whole proposal. It is deliberately
**not** the executor's per-**op** `result_status`
(`applied` / `skipped-stale` / `blocked` / `error`, recorded once per operation in
the [audit log](../docs/audit-log.md)). Op result-statuses are the *evidence*;
proposal status is the *summary* derived from that evidence plus the human's
apply/discard decisions.

### 2.1 The five states

| Status       | Meaning                                                                                     | Directory              |
|--------------|---------------------------------------------------------------------------------------------|------------------------|
| `pending`    | Emitted, untouched. Every op still to apply. The default candidate.                         | `proposals/`           |
| `partial`    | Some — but not all — ops applied (real, `dry_run=false`). Resumable (GAP-11).                | `proposals/`           |
| `applied`    | Every op has an `applied` audit record. Terminal, fully retired.                            | `proposals/applied/`   |
| `superseded` | A newer review displaced this still-`pending` proposal. Terminal.                           | `proposals/superseded/`|
| `discarded`  | The human rejected the whole proposal. Terminal.                                            | `proposals/superseded/`|

`pending` and `partial` are the **candidate** states — only these live in the
active `proposals/` dir and only these are selectable (§3). The three terminal
states are retired out of the active dir (§6), so the active dir never accumulates
ambiguous already-decided proposals.

### 2.2 The status sidecar — the materialized status field

Because the envelope is immutable (and `additionalProperties: false` forbids
adding a `status` field to it), each proposal carries its status in a **sidecar
JSON file** named `changeset-<stamp>.status.json`, co-located with — and travelling
alongside — its envelope. The sidecar is *mutable* lifecycle state, distinct from
both the immutable envelope and the append-only audit log:

```json
{
  "proposal": "changeset-2026-06-19T143000Z.json",
  "source": "run-2026-06-19-weekly",
  "generated_at": "2026-06-19T14:30:00Z",
  "schema_version": "1.0.0",
  "status": "partial",
  "audit_run_id": "run-2026-06-19-weekly",
  "transitions": [
    { "to": "pending", "at": "2026-06-19T14:30:05Z", "by": "review-emit" },
    { "to": "partial", "at": "2026-06-20T09:12:41Z", "by": "ynab-apply" }
  ]
}
```

| Field           | Purpose                                                                                  |
|-----------------|------------------------------------------------------------------------------------------|
| `proposal`      | The envelope filename this sidecar governs.                                               |
| `source`        | The review run id — the stable key every audit record carries as `run_id` (`run_id := source`). |
| `generated_at`  | Copied from the envelope; lets selection/staleness read the sidecar without opening the envelope. |
| `schema_version`| The envelope schema version, so a status-model change can migrate.                        |
| `status`        | One of the five §2.1 values. The single field that answers "where is this proposal in its life?" |
| `audit_run_id`  | **The pointer to the audit log** — read it with `audit-log.sh run <audit_run_id>` to see per-op evidence (§9). Equals `source`. |
| `transitions`   | Append-only trail: each `{ to, at, by }` records who advanced the status and when.       |

**Why a sidecar and not a derived value.** Status *could* be inferred from
directory + audit log, but three requirements make an explicit, written field the
right call: (a) `discarded` is a human decision that leaves **no** audit record to
derive from; (b) a defined, single-writer field lets §2.3 state exactly which
component performs each transition (and lets §8's lock protect one well-known
write); and (c) `partial` must "carry an explicit status with a pointer to the
audit log" — the sidecar *is* that pointer (`audit_run_id`). Directory placement
(§6) remains the coarse, filesystem-visible retention signal, and it **must always
agree** with the sidecar's `status`; on any disagreement the sidecar wins and the
next lock-holding writer repairs the placement.

### 2.3 Transitions — allowed edges and their writer

```text
                 review-emit
                     │  (create)
                     ▼
   ┌──────────────► pending ───────────────┐
   │                 │  │                   │
   │  review-emit    │  │  ynab-apply       │ ynab-apply
   │  (newer review) │  │  (some ops)       │ (reject whole)
   │                 │  ▼                   ▼
superseded           │ partial ─────────► discarded
   ▲                 │  │  (ynab-apply, reject/discard)
   │   ynab-apply    │  │  ynab-apply
   └── (all ops) ◄───┴──┴──► applied  (all ops applied)
```

| From      | To           | Written by     | When                                                                 |
|-----------|--------------|----------------|----------------------------------------------------------------------|
| _(none)_  | `pending`    | `review-emit`  | The emitter writes the envelope + sidecar at creation. Only entry point. |
| `pending` | `partial`    | `ynab-apply`   | An apply run applied ≥1 but not all ops.                              |
| `pending` | `applied`    | `ynab-apply`   | An apply run left every op with an `applied` audit record.            |
| `pending` | `superseded` | `review-emit`  | A newer review is emitted for the same budget while this is untouched.|
| `pending` | `discarded`  | `ynab-apply`   | The human rejected the whole proposal.                               |
| `partial` | `applied`    | `ynab-apply`   | A resume run completed the remaining ops.                            |
| `partial` | `discarded`  | `ynab-apply`   | The human abandoned a half-applied proposal.                         |

Two edges are **deliberately absent**:

- **`partial` → `superseded` is not allowed.** A newer review never auto-displaces
  a half-applied proposal — its already-applied ops are real ledger changes, and
  silently retiring it could strand an idempotent resume (GAP-11). A `partial`
  older proposal is *left in place*; the next apply against it hits the staleness
  gate (§4), which surfaces "a newer review exists" and routes the human to
  reconcile or explicitly `discard`.
- **`applied` → anything** and **`superseded`/`discarded` → anything** are absent —
  the three retired states are terminal.

---

## 3. Selection — which proposal `/ynab-apply` targets

When `/ynab-apply` runs with no explicit argument, it targets **the newest
candidate proposal**:

1. Consider only files in the **active** `proposals/` dir (never `applied/` or
   `superseded/`), i.e. only `pending` and `partial` proposals.
2. Sort by the envelope **`generated_at`** (the authoritative sort key), newest
   first. Tie-break on the compacted filename stamp, then on the `source` id — a
   total, deterministic order that never depends on filesystem mtime.
3. Target the newest. A `partial` proposal sorts among candidates normally: if it
   is the newest candidate it is selected and **resumed** (the idempotency guard
   skips its already-applied ops — GAP-11).

**Explicit override.** The user may point apply at a specific proposal by path:
`/ynab-apply <path-to-changeset.json>`. An explicit path bypasses the newest-wins
sort (but **not** the staleness gate of §4 — an explicitly named stale proposal is
still rejected).

> **Coordination — supersedes the interim selection.** `/ynab-apply` Step 1 today
> picks `ls -t "$PROPOSAL_DIR"/*.json | head -1` (most-recent by mtime, top-level
> only). That is an interim placeholder; when this lifecycle is wired it is
> replaced by the `generated_at` sort above and the `applied/` / `superseded/`
> subdirs (whose files the top-level glob already excludes). Until then, moving
> retired proposals into the subdirs already keeps `ls -t` from selecting an
> applied or superseded proposal.

---

## 4. Global staleness — the whole-proposal freshness gate

A proposal that has aged past a threshold, or that a newer review has already
supplanted, is **rejected outright at command entry — never partially applied**.
The user is told to regenerate the review rather than apply a proposal whose view
of the world has broadly drifted.

The gate runs **before any op is processed** (§5) and evaluates three signals, in
order:

1. **Supersession.** If a `pending`/`partial` proposal with a *newer*
   `generated_at` exists for the same `budget_id`, the older one is stale.
   (Emission already retires a superseded *pending* proposal to `superseded/` per
   §2.3; this catch also covers a `partial` that emission left in place.)
2. **Wall-clock age.** If `now - generated_at` exceeds
   `.apply.max_proposal_age_hours` (default **168** — seven days), the proposal is
   stale. The default is deliberately generous: a weekly review's proposal stays
   applicable for roughly a review cycle, no longer.
3. **Server-knowledge drift (optional, off by default).** If the envelope records
   the YNAB `server_knowledge` captured at generation *and*
   `.apply.max_server_knowledge_delta` is set, a live-vs-generation delta beyond
   that bound marks the proposal stale — a cheap "the world changed a lot since
   this was proposed" signal that catches heavy churn *inside* the age window.

On a stale verdict, apply **rejects the whole proposal** with a clear,
user-facing message and applies nothing:

```text
⛔ This proposal is stale — refusing to apply any of it.
   Generated: 2026-06-02T14:30:00Z (9 days ago; max 7).
   Re-run the review to generate a fresh proposal, then apply that.
```

A fresh verdict lets apply proceed to the per-op layer (§5). Fail-closed: if
`generated_at` is unreadable or the sidecar/lock cannot be resolved, the gate
treats the proposal as stale rather than risk applying against an unknown vintage.

### 4.1 Tying freshness to the envelope, not the file

The age and supersession checks read the envelope's **`generated_at`** (the M4-1
field) — not the file's mtime, which a copy or restore can reset. The optional
server-knowledge check reads a generation-time `server_knowledge` the emitter
records; because the current envelope is `additionalProperties: false`, adding it
is an **optional** field and thus a **MINOR** schema bump (per contract §7), so its
*absence* is normal and simply falls back to age-only — server-knowledge is an
enhancement, never a prerequisite.

---

## 5. The two gates are distinct and ordered

Staleness and drift are often conflated; they are separate gates at separate
layers, and both must be understood to reason about an apply:

| | **Global staleness** (§4) | **Per-op drift** (M4-4) |
|---|---|---|
| Question | "Is this *proposal* too old / supplanted to apply at all?" | "Has *this op's* target changed since the snapshot?" |
| Granularity | The whole proposal | One operation |
| When | **Command entry**, before any op is processed | **Inside the executor**, per op, on every dry-run and real apply |
| Signal | `generated_at` age · supersession · (optional) server-knowledge delta | `isStale(op.before, live)` — live no longer equals the op's `before` snapshot |
| Effect | **Reject the whole proposal**; apply nothing | Mark that op `skipped-stale`; the rest of the batch proceeds |
| Owner | This spec (GAP-10), enforced by `/ynab-apply` | The apply executor (`assets/apply-executor.js`) |

**Ordering.** Global staleness runs **first**, at entry. Only a globally fresh
proposal reaches the executor, where per-op drift then runs per operation. The two
do not overlap: a proposal can pass the global gate (recent, not superseded) yet
still have individual ops the executor skips as stale — that is expected and
correct, not a contradiction. A globally stale proposal never reaches the per-op
layer at all.

---

## 6. Retention & archival — the active dir holds only candidates

Retention is expressed by **directory placement**, kept in lock-step with the
sidecar `status` (§2.2):

- **Fully applied** (`status: applied`) — `/ynab-apply` moves the envelope **and**
  its sidecar into `proposals/applied/` once every op carries an `applied` audit
  record.
- **Superseded** (`status: superseded`) — when the review emitter writes a newer
  proposal for a budget, it retires any still-`pending` older proposal for that
  budget into `proposals/superseded/`.
- **Discarded** (`status: discarded`) — when the human rejects a proposal
  wholesale, `/ynab-apply` moves it into `proposals/superseded/` (the shared
  "retired, not applied" bucket; the sidecar's `status` distinguishes `discarded`
  from `superseded`).
- **Candidates** (`pending`, `partial`) stay in the active `proposals/` dir.

The result: the active `proposals/` dir holds **only** proposals still eligible to
apply — never an ambiguous mix of live and already-decided ones. `applied/` and
`superseded/` are the durable archive (an applied proposal + its audit trail is
the record of what was actually written). A proposal file and its `.status.json`
sidecar always move **together**; they are never separated across directories.

---

## 7. "Pending" defined precisely

A proposal is **pending** from the moment the emitter writes it until it becomes
either **fully applied** or **explicitly discarded**. Precisely:

- **Enters `pending`** when `review-emit` writes the envelope + sidecar.
- **Leaves `pending` for `partial`** the first time an apply run applies at least
  one (but not all) of its ops — it is then *pending completion*, resumable, and
  still a candidate.
- **Leaves for `applied`** when every op has an `applied` audit record.
- **Leaves for `discarded`** when the human rejects the whole proposal.
- **Leaves for `superseded`** only from `pending` (never `partial`), when a newer
  review displaces it.

"Pending" therefore spans exactly the `pending` **and** `partial` states — the two
candidate states — and nothing else. An **errored** op (per-op `result_status:
error`, GAP-8) does **not** count as applied: a proposal with some errored and no
successfully-applied ops stays `pending`; with some applied and some errored it is
`partial` until the errors are resolved (re-applied) or the human discards it.

---

## 8. Concurrency — status writes are single-flight (GAP-9)

The global-staleness rejection and **every** proposal-status write (sidecar update
+ the paired directory move) are performed **while holding the GAP-9 single-flight
lock**. Two actors must never transition the same proposal concurrently — e.g. an
apply advancing a proposal to `applied` while a review emission tries to mark it
`superseded` would otherwise race the sidecar and the file move.

Because status lives in exactly one sidecar written by exactly one lock-holding
writer at a time (§2.3), the lock scope is small and well-defined: acquire, read
the current sidecar, decide the transition, write the sidecar, move the file,
release. Directory placement and sidecar `status` can never diverge under a
concurrent writer, and if a crash ever leaves them disagreeing, the next
lock-holder treats the sidecar as authoritative and repairs the placement (§2.2).

> **Coordination.** The GAP-9 lock **is implemented** as
> [`bin/apply-lock.sh`](./../bin/apply-lock.sh) (issue #51): a single-flight lock
> under the data dir (`$CONFIG_DIR/apply.lock`), acquired as `apply` or `review`,
> holding pid + timestamp + operation, with `kill -0` stale-recovery so a crashed
> holder never deadlocks the next run. It is **wired into `/ynab-apply`** (Step 0:
> acquire before the proposal read, release on every exit path). The M4-10 review
> emitter takes the *lighter* form — `acquire review` around the proposal write,
> backing off if an apply holds the lock — when that emitter lands. The lock is a
> **concurrency guard only**: it carries no approval state and no write-approval
> decision reads it (issue #51 AC #6). Every status write named in this document
> runs inside its critical section.

---

## 9. Reconciliation with GAP-8, GAP-9, GAP-11

The proposal-status model is the shared contract these three consumers read and
write; each interacts with it as follows:

- **GAP-8 (errored ops).** Op-level `error` is recorded in the audit log's
  `result_status`, not in proposal status. Errored ops are simply "not yet
  applied": they keep a proposal `pending`/`partial` (§7) and are re-attempted on
  the next apply/resume. Proposal status never has an `error` value — the audit log
  owns per-op error detail; the sidecar's `audit_run_id` points there.
- **GAP-9 (single-flight lock).** Guards the staleness rejection and every status
  write (§8), so status transitions are serialized and the sidecar/directory pair
  stays consistent.
- **GAP-11 (idempotent resume).** Reads status to find the resumable candidate
  (`partial`, still in `proposals/`) and reads the audit log (via `audit_run_id`)
  to skip already-`applied` ops — exactly the existing idempotency guard
  (`/ynab-apply` Step 1b). When a resume completes the last op, it writes the
  `partial → applied` transition and triggers the §6 move.

The single source of per-op truth is the **audit log** (`result_status` per op);
the single source of per-proposal truth is the **sidecar** (`status`). Neither
duplicates the other — proposal status is *derived and written from* audit
evidence plus human decisions, and always points back at the audit log it was
derived from.

---

## 10. Configuration keys

The staleness gate is configurable under the existing `.apply` object of
[`config.json`](./config.schema.json). All keys are optional with shipped
defaults, so an omitted `.apply` block behaves sensibly:

| Key                              | Type            | Default   | Meaning                                                             |
|----------------------------------|-----------------|-----------|---------------------------------------------------------------------|
| `.apply.proposal_path`           | string          | `$CONFIG_DIR/proposals` | The active proposal dir (existing key). `applied/` and `superseded/` are its subdirs. |
| `.apply.max_proposal_age_hours`  | integer         | `168`     | Wall-clock staleness threshold (§4.2). `≤ 0` disables the age gate. |
| `.apply.max_server_knowledge_delta` | integer \| null | `null`  | Optional server-knowledge drift bound (§4.3). `null` ⇒ off.         |

> **Coordination.** Only `.apply.proposal_path` exists in `config.schema.json`
> today. The two staleness keys above are added to the `.apply` object (which is
> `additionalProperties: false`) by the apply-wiring follow-up, together with the
> code that reads them — this spec defines their names, types, and defaults so that
> follow-up has an unambiguous target.

---

## Appendix — consumer wiring

This spec is consumed, not self-executing. The touch points:

| Consumer | Reads | Writes |
|---|---|---|
| **Review emitter (M4-10)** | existing candidates for the budget (supersession) | new envelope + sidecar (`pending`); retires displaced `pending` proposals (`superseded` + move) — all under the GAP-9 lock |
| **`/ynab-apply` (M4-5)** | selection (§3), staleness gate (§4), status + audit log | `partial` / `applied` / `discarded` transitions + the paired §6 move |
| **Resume (GAP-11)** | `partial` candidate + audit `applied` op-ids | `partial → applied` on completion |
| **Lock (GAP-9)** | — | wraps every status write above in its critical section |
| **Errored ops (GAP-8)** | audit `result_status: error` | nothing in proposal status (errors keep a proposal `pending`/`partial`) |

The two schema/config additions this spec anticipates — an optional envelope
`server_knowledge` (MINOR bump, §4.3) and the two `.apply` staleness keys (§10) —
are the emitter's and apply command's to make when they wire the lifecycle; both
are optional, so nothing here breaks an existing change-set or config.
