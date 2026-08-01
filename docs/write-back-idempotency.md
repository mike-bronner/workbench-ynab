# Idempotent resume of a partially-applied batch (GAP-11 / #48)

This is the design for **resuming an apply that stopped part-way through**: how
each operation is keyed so a later run can recognise it, in what order the audit
log and the YNAB mutation are written, which consistency model the system
targets, and exactly what a resume does when the audit log and the live budget
disagree.

Write-back touches money records. "Re-run it and hope" is not an acceptable
answer, so every rule below is stated as a decision with its reason, not as an
implicit property of the code.

> **Scope: this document is the design, not the implementation.** The apply
> executor ([`assets/apply-executor.js`](../assets/apply-executor.js)), the audit
> log ([`bin/audit-log.sh`](../bin/audit-log.sh)), and the `/ynab-apply`
> idempotency guard ([`commands/ynab-apply.md`](../commands/ynab-apply.md) Step
> 1b) already implement part of it. [§10](#10-what-the-wiring-follow-up-must-build)
> lists exactly what is designed here but not yet built, so no reader mistakes a
> plan for a shipped guarantee.

**Related contracts.** [`docs/audit-log.md`](./audit-log.md) (the record shape),
[`assets/changeset-contract.md`](../assets/changeset-contract.md) (the operation
shape), [`assets/changeset-lifecycle.md`](../assets/changeset-lifecycle.md)
(proposal selection, global staleness, proposal status — GAP-10),
[`docs/write-back-safety.md`](./write-back-safety.md) (what may be written at
all).

> **Tool names are written bare here.** This document names read verbs as
> `ynab_get_transaction`, not with the `mcp__plugin_workbench-ynab_ynab__`
> prefix. The fully namespaced names live in
> [`skills/protocol/ynab-tools.md`](../skills/protocol/ynab-tools.md), which is
> the single source of truth `bin/check-tool-name-sources.sh` protects (issue
> #87). Prefix + verb gives the callable name.

---

## 1. The idempotency key

### 1.1 Composition

The key of an operation is the 4-tuple:

| Component | Source | Why it is in the key |
|---|---|---|
| **proposal id** | the envelope's `source` (the review run id that produced the change-set) | scopes the key to one proposal, so the same op position in a different proposal never matches |
| **op index** | the operation's 0-based position in `operations[]` | gives every op in a proposal a distinct key with no hashing needed |
| **target entity id** | `transaction_id` / `category_id` / `account_id` — whichever the op type carries | binds the key to the thing being changed, so a re-ordered proposal cannot silently inherit another op's history |
| **intended-change digest** | SHA-256 over the canonical intended change (see below) | binds the key to *what* was to be done, so an edited proposal cannot reuse an old op's "already applied" verdict |

The digest covers the **intent only** — `type`, `budget_id`, the target entity
id, `after`, and (for `allocate`) `month`. It deliberately excludes `before`,
`rationale`, and `risk`:

- `before` is drift evidence, not intent. It describes the world at proposal
  time. If it were in the key, the key would change exactly when the world moved
  — the moment resume matters most — and every resume after a drift would fail
  to match its own audit records.
- `rationale` and `risk` are human-facing text. Rewording a sentence must not
  change an operation's identity.

Canonical form before hashing: JSON with keys sorted lexicographically, no
insignificant whitespace, monetary values as **raw milliunit integers** (never a
pre-divided float), `null` for absent optional fields.

### 1.2 Encoding

The tuple is persisted in **two** fields, because the audit record already
carries the proposal id separately:

```
operation.id  ::=  "op-" <index> "-" <type> "-" <entity_id> "-" <digest>

<index>      ::= the 0-based array position, zero-padded to 4 decimal digits
<type>       ::= categorize | allocate | delete_duplicate | reconcile
<entity_id>  ::= the target entity id, verbatim
<digest>     ::= the first 12 lowercase hex characters of the SHA-256 above
```

Example: `op-0007-categorize-b1f0c9e2-4a77-4b31-9a02-6d3c0e5f1a88-9f2c1ab40d7e`

The proposal id is **not** repeated inside `operation.id`. It is the envelope's
`source`, which the executor already copies into every audit record as `run_id`
(`recordAudit`, `assets/apply-executor.js`). The full key is therefore the pair
**`(run_id, operation_id)`** as read off the audit log — see [§7](#7-alignment-with-the-audit-log-schema-57).

This encoding satisfies the schema as written: `operation.id` is declared
`"Stable per-operation id (UUID or deterministic key)"` in
[`assets/changeset-schema.json`](../assets/changeset-schema.json). This design
picks the deterministic-key option and fixes its grammar. No schema change is
needed.

### 1.3 Why the key is stable across runs

Every component is a pure function of the change-set envelope:

1. The envelope is written once and never rewritten. An edit produces a **new**
   proposal with a new `source` ([`assets/changeset-lifecycle.md`](../assets/changeset-lifecycle.md) §2).
2. `index` is a position in a frozen array.
3. The entity id is assigned by YNAB and is immutable for the life of the entity.
4. The digest is taken over a canonical serialization — sorted keys, integers,
   no whitespace — so it is byte-identical on every machine and every run.

Nothing in the key reads a clock, a random source, a locale, or a float.
Re-deriving the key on run *N* therefore produces the same string it produced on
run 1. That is the whole stability requirement: resume matches on equality of a
string it can recompute.

### 1.4 Why the key cannot collide

Collision resistance comes from the **index**, not from the hash:

- **Within a proposal**: two operations occupy two different array positions, so
  their `index` components differ. Every key in a proposal is distinct, by
  construction, whatever the digest does.
- **Across proposals**: resume queries the audit log by `run_id`
  (`audit-log.sh run <run_id>`), so records from another proposal are never in
  the candidate set. A same-index op in a different proposal cannot match.

The digest is not load-bearing for uniqueness. It is a **tamper detector**: if a
proposal file is edited in place without changing its `source`, the edited op's
digest changes and it no longer matches its old audit record. Resume then treats
it as **not applied** and re-verifies against live state — the safe direction. A
truncated 12-hex-character digest gives 48 bits, which is ample for detecting an
accidental edit; it is not, and does not need to be, a defence against an
adversary who can already rewrite the proposal file.

---

## 2. Write-ahead ordering

### 2.1 The sequence

For every operation, on a **real** apply (`dry_run: false`):

```
1. record intent   →  append { result_status: "pending_apply" }   (audit log)
2. apply the op    →  call the namespaced YNAB write tool
3. record result   →  append { result_status: "applied" | "error" | … }
```

The intent record is written **before** the mutation, never after. This is the
whole point of the ordering: the audit log can never be *behind* the budget by
more than one un-recorded outcome, and it can be *ahead* — which is harmless,
because an intent record claims nothing about what happened.

The destructive path already works this way: `delete_duplicate` appends a
`pending_delete` intent record before the irreversible delete
([`assets/delete-duplicate.js`](../assets/delete-duplicate.js), documented in
[`docs/audit-log.md`](./audit-log.md)). This design generalises that two-phase
trail to every operation type.

### 2.2 What a crash leaves behind

| Crash point | Trail | Resume sees | Resume does |
|---|---|---|---|
| before step 1 | nothing | no record for this key | process the op normally |
| between 1 and 2 | intent only | `pending_apply`, no outcome | **verify live state** ([§4](#4-live-ynab-state-is-the-tie-breaker)), then skip or apply |
| between 2 and 3 | intent only | `pending_apply`, no outcome | same as above — this is [interleaving B](#52-interleaving-b--applied-in-ynab-no-audit-record) |
| after step 3 | intent + outcome | `applied` (or `error`) | skip (after the [§5.1](#51-interleaving-a--the-audit-says-applied-live-state-disagrees) confirmation) |

**The worst case is a recheck, never a blind re-apply.** Every ambiguous cell in
that table resolves to "read live state and decide", not to "apply again and
hope". No path in this design dispatches a mutating tool on the strength of a
missing audit record alone.

The alternative ordering — apply first, record after — was rejected. It makes the
two dangerous states indistinguishable: an op with no record could be one that
never ran or one that ran and lost its record, and nothing in the trail
separates them. Write-ahead ordering makes "we were about to do this" an
explicit, durable fact.

### 2.3 The audit status vocabulary this adds

[`docs/audit-log.md`](./audit-log.md) documents five `result_status` values on
the trail today (`applied`, `skipped-stale`, `blocked`, `error`,
`pending_delete`). This design puts two more on it:

| Value | Written by | Meaning |
|---|---|---|
| `pending_apply` | the executor, before every non-destructive mutation | intent recorded; the outcome is not yet known. **New** — no producer writes it today |
| `human_review_required` | resume, for an [interleaving-A conflict](#51-interleaving-a--the-audit-says-applied-live-state-disagrees) | the op cannot be decided automatically and is routed to the human. Already a member of the executor's frozen `STATUS` enum, but **not** on the audit trail today |

`pending_delete` stays as it is — it is the destructive path's specialisation of
the same idea, and it already carries the stronger meaning that an irreversible
call is about to run. The wiring follow-up adds both rows to
`docs/audit-log.md` at the same time it adds the writers.

---

## 3. Consistency model — at-least-once with detection

**The chosen model is at-least-once with detection.** Exactly-once is not
claimed, because it cannot be delivered.

Exactly-once would need the local audit append and the remote YNAB mutation to
commit atomically. They are two systems on either side of a network, and the
YNAB API offers no transaction id, no idempotency key on its update verbs, and
no two-phase commit. Any implementation claiming exactly-once here would be
claiming a guarantee the substrate cannot supply.

What the system can supply is stronger than it sounds:

1. **Three of the four operations are idempotent by value.** `categorize` sets a
   category id, `allocate` sets a budgeted amount, `reconcile` sets a cleared
   status and a reconciled balance. Applying any of them twice leaves the same
   state as applying it once. For these, at-least-once is *observationally*
   exactly-once.
2. **Detection closes the gap.** Before any re-apply, resume compares live YNAB
   state against the operation's `after`. An op already in its target state is
   skipped, so the second delivery does not even reach the API.

`delete_duplicate` is the exception and gets the strict treatment: **a delete is
never auto-re-applied.** Deleting is not value-idempotent — a second delete of a
transaction that a human has since re-created, or a delete whose target id was
reused, destroys a record nobody approved destroying. An ambiguous delete is
routed to the human ([§5](#5-recovery--the-two-dangerous-interleavings)),
which matches the extra-confirmation posture the delete path already carries
([`docs/write-back-safety.md`](./write-back-safety.md)).

---

## 4. Live YNAB state is the tie-breaker

**The audit log is evidence. The budget is truth.** When they disagree, resume
believes the budget.

The audit log can be incomplete — a lost tail, a crash between mutation and
record, a hand-edited proposal. Live state cannot be incomplete about itself: if
the transaction carries the intended category, the change is in the budget,
whatever the log says. So every skip/apply decision on resume is confirmed
against a live read before it is acted on.

### 4.1 The verification query, per operation type

All reads are read-only tools from
[`skills/protocol/ynab-tools.md`](../skills/protocol/ynab-tools.md); prefix them
with `mcp__plugin_workbench-ynab_ynab__` to get the callable name.

| Op type | Read verb | Field read | Counts as applied when |
|---|---|---|---|
| `categorize` | `ynab_get_transaction` | `category_id` | equals `after.category_id` |
| `allocate` | `ynab_get_month` (for the op's `month`) | the target category's `budgeted` | equals `after.budgeted`, compared as integer milliunits |
| `delete_duplicate` | `ynab_get_transaction` (the victim id) | existence | the read returns **HTTP 404** — the transaction is gone |
| `reconcile` | `ynab_list_accounts` for the account; `ynab_get_transaction` per entry in `transaction_ids` | `reconciled_balance`; each transaction's `cleared` | `reconciled_balance` equals `after.reconciled_balance` **and** every listed transaction's `cleared` equals `after.cleared` |

Three rules govern how those reads are compared:

- **Compare only the fields the op names in `after`.** An unrelated live field
  that moved is not this op's business. This mirrors the executor's existing
  drift check, which compares only the keys present in `before`
  (`isStale`, `assets/apply-executor.js`).
- **Compare milliunits as integers.** Never divide before comparing; the ÷1000
  conversion is display-only ([`assets/changeset-contract.md`](../assets/changeset-contract.md) §2).
- **A `delete_duplicate` verification must distinguish 404 from every other read
  failure.** The read ports throw on failure
  ([`skills/protocol/ynab-tools.md`](../skills/protocol/ynab-tools.md)), so a
  "gone" 404 and a "server is down" 503 both surface as a thrown error. Only a
  404 is evidence of a completed delete. Every other failure is *unconfirmable*
  and is handled as such ([§5.1](#51-interleaving-a--the-audit-says-applied-live-state-disagrees)).

---

## 5. Recovery — the two dangerous interleavings

### 5.1 Interleaving A — the audit says applied, live state disagrees

The audit log carries `result_status: "applied"`, `dry_run: false` for this key,
but the change cannot be confirmed in the budget.

**Procedure — query live state first, then branch on what came back:**

| Live read result | Verdict | Action |
|---|---|---|
| succeeds, matches `after` | applied | **skip** the op; continue the batch |
| succeeds, does **not** match `after` | conflict | **flag for manual review.** Do not re-apply. Record the op as `human_review_required` and continue with the rest of the batch |
| fails (network, 5xx, timeout — anything but the delete-path 404) | unconfirmable | **do nothing to this op.** Report it and leave it un-processed |

**Why a mismatch is never auto-re-applied.** A mismatch means one of two things:
a human changed the value after this system applied it, or the audit record is
wrong. Re-applying serves neither. In the first case it silently reverts a
deliberate human edit — the exact hazard the executor's drift check exists to
prevent ("never clobber a value the human never saw"). In the second, the system
would be acting on a record it has just proved untrustworthy. Both call for a
person, so both go to a person.

**Why an unconfirmable read is not treated as "probably fine".** Failing open
here would mean either skipping an op that never applied, or re-applying one
that did. The op is left exactly where it was — the trail still says `applied`,
the batch continues, and the next resume tries the read again. Nothing is lost
by waiting.

### 5.2 Interleaving B — applied in YNAB, no audit record

The budget shows the change, but the trail has no outcome record for this key —
either a `pending_apply`/`pending_delete` intent with nothing after it, or (for
an op applied before write-ahead ordering shipped, or after a lost log tail)
nothing at all.

**Procedure:**

1. Verify live state per [§4.1](#41-the-verification-query-per-operation-type).
2. If live state matches `after`: **treat the op as applied.** This leans on
   YNAB's value-idempotent update semantics — the budget is already in the
   target state, so there is nothing left to do and re-applying would be a no-op
   at best.
3. **Backfill a synthetic audit record**, and emit a warning to the human in the
   same run.
4. If live state does **not** match `after`: the op simply never applied.
   Process it normally — except for `delete_duplicate`, which is routed to the
   human rather than re-attempted ([§3](#3-consistency-model--at-least-once-with-detection)).

**Backfill, not warn-only — and why.** The AC offers both. Backfill wins for two
reasons:

- **Warn-only leaves the resume non-convergent.** With no record, *every*
  subsequent resume of this proposal re-verifies the same op against live YNAB.
  Worse, if the human later changes that category by hand, a later resume reads a
  mismatch and escalates to manual review an op that genuinely applied — a false
  alarm manufactured by the missing record. Backfilling pins the finding at the
  moment it was verified.
- **An audit log with a known hole is a worse artifact than one with a labelled
  inference.** The log exists so a mutation can be reviewed, reversed, or
  disputed later ([`docs/audit-log.md`](./audit-log.md)). A hole gives a reader
  nothing.

The warning is emitted **as well**, because the human should know the trail was
repaired rather than written first-hand.

**The backfilled record is distinguishable, with no schema change.** It is a
normal record with `result_status: "applied"`, `dry_run: false`, and
**`tool: null`**. That combination is unproducible by the apply path: a real
apply always names the tool it called, because `recordAudit` takes the tool name
from the dispatch result (`assets/apply-executor.js`). So

> `result_status: "applied"` + `dry_run: false` + `tool: null`
> = **verification-derived backfill, not a first-hand apply**

is an unambiguous marker that the existing record shape already carries. No new
field, no schema version bump.

---

## 6. Resume preconditions, in order

A resume run is an apply run. It takes the **same** gates, in this order, and
processes **no** operation until all three have passed:

1. **Acquire the single-flight lock** (GAP-9 / #51) —
   `bin/apply-lock.sh acquire apply`. First, because it is the cheapest gate and
   the one that prevents two resumes from racing on the same proposal. Released
   on every exit path.
2. **Select the proposal and run the global staleness gate** (GAP-10) — a
   proposal too old or supplanted is rejected whole
   ([`assets/changeset-lifecycle.md`](../assets/changeset-lifecycle.md) §4).
   Resume gets no exemption: a stale proposal is stale whether or not part of it
   already applied.
3. **Pass the auth preflight** (GAP-8 / #50) — a read-only call that proves the
   token is valid and write-capable, before any op is touched.

**Why the auth preflight comes before the verification reads, not just before
the first mutation.** Resume's live-state reads need the same token. Without the
preflight, a revoked token turns every verification read into an
"unconfirmable" verdict ([§5.1](#51-interleaving-a--the-audit-says-applied-live-state-disagrees))
and the human gets N confusing per-op failures instead of one accurate message:
the token is dead. The preflight converts that into a single clean abort with a
remediation line.

Only after all three does resume read the audit log, classify each op, and
dispatch what remains.

---

## 7. Alignment with the audit-log schema (#57)

Every key component maps to a field that the audit record already carries. This
is what makes the log queryable as an idempotency index rather than just a
narrative:

| Key component | Audit-log field | Notes |
|---|---|---|
| proposal id | `run_id` | the executor sets `run_id := changeset.source` (`recordAudit`) |
| op index + entity id + digest | `operation_id` | the whole `operation.id` string from [§1.2](#12-encoding) |
| — (derivable) | `operation_type` | the op's `type`, also embedded in `operation_id` |
| target entity id | `target_entity_ids` | the record's id array; the key's entity id is its first element |
| — | `result_status` | `applied` is the only status that means "done"; the other values mean "not yet" |
| — | `dry_run` | a resume matches only `dry_run: false` records — a dry run mutated nothing |

The lookup a resume performs is exactly:

```bash
bash bin/audit-log.sh run "$RUN_ID" \
  | jq -r 'select(.dry_run == false and .result_status == "applied") | .operation_id'
```

which is the guard `/ynab-apply` Step 1b already runs
([`commands/ynab-apply.md`](../commands/ynab-apply.md)). This design keeps that
query unchanged and adds the live-state confirmation around it.

`audit-log.sh run` scans **every** monthly file, not just the current one, so a
partial apply that straddled a UTC month boundary still resolves.

---

## 8. Audit-log append requirements, and the one gap

The requirements this design depends on, restated:

| Requirement | Status today | Evidence |
|---|---|---|
| **Append-only** | ✅ implemented | the writer only ever `>>`-appends; it never rewrites, truncates, or seeks ([`bin/audit-log.sh`](../bin/audit-log.sh)) |
| **Ordered** | ✅ implemented | appends to an `O_APPEND` descriptor; records land in the order they were written |
| **One record per atomic write** | ✅ implemented | each record is one compact line emitted in a single `write(2)`, so a crash leaves the whole record or nothing — never a torn line |
| **`fsync` per record** | ❌ **not implemented** | the writer does no `fsync`. A record is durable against a *process* crash (it is in the page cache) but not against a *machine* crash or power loss |

**The fsync gap is called out rather than papered over.** The issue brief for
#48 assumed the log was fsync'd per record. It is not, and this document will
not restate an assumption the code does not deliver.

**The design is still correct without fsync**, because the audit log is not the
sole truth. A lost tail after a power cut produces exactly one condition:
operations that applied but have no outcome record — which is
[interleaving B](#52-interleaving-b--applied-in-ynab-no-audit-record), already
handled by live-state verification and backfill. The trail degrades into a case
the recovery procedure covers, not into a wrong decision.

Append-only + ordered + atomic-per-record **are** sufficient for deterministic
resume: resume needs to read a set of complete records and match keys, and it
never needs the log to be a complete account of the world. What fsync would buy
is fewer live reads after a hard crash, not correctness. Adding it (an `fsync`
or `sync` after each append) is worth a follow-up, and this document is the
place that names it as an open gap.

---

## 9. Worked walkthroughs

Setup for all three: proposal `run-2026-06-14`, three operations.

```
index 0  categorize  txn-A → category "Groceries"   op-0000-categorize-txn-A-1a2b3c4d5e6f
index 1  allocate    cat-B budgeted 250000          op-0001-allocate-cat-B-7f8e9d0c1b2a
index 2  categorize  txn-C → category "Fuel"        op-0002-categorize-txn-C-3c4d5e6f7a8b
```

### 9.1 Clean resume — every op already applied, everything skipped

Run 1 applied all three, then the process was killed before the summary printed.

Run 2:

1. Acquires the lock, passes staleness, passes auth preflight ([§6](#6-resume-preconditions-in-order)).
2. Reads the audit log for `run_id = run-2026-06-14`: three records with
   `result_status: "applied"`, `dry_run: false`, one per key.
3. Verifies each against live state: `txn-A.category_id` matches, `cat-B.budgeted`
   is `250000`, `txn-C.category_id` matches.
4. Skips all three. Calls no write tool. Writes the proposal's
   `partial → applied` transition and retires it per
   [`assets/changeset-lifecycle.md`](../assets/changeset-lifecycle.md) §6.

```text
✅ Everything in this proposal is already applied — nothing to do.
   3 op(s) confirmed against live YNAB state.
```

### 9.2 Interleaving A — the trail says applied, the budget says otherwise

Between run 1 and run 2, a human re-categorised `txn-C` by hand in the YNAB app,
from "Fuel" to "Auto Maintenance".

Run 2:

1. Gates pass. Audit shows all three `applied`.
2. Verification: `txn-A` matches, `cat-B` matches, `txn-C.category_id` is
   `Auto Maintenance` — it does **not** match `after.category_id` (`Fuel`).
3. `txn-C` is a conflict. It is **not** re-applied. It is reported as
   `human_review_required` and the run continues.

```text
⚠️  op-0002-categorize-txn-C-3c4d5e6f7a8b — audit says applied, live state differs.
    expected category: Fuel
    live category:     Auto Maintenance
    Not re-applied. Someone changed this after the apply — review it yourself.
```

Had the `txn-C` read *failed* instead of returning a different value, the op
would be reported as unconfirmable and left entirely alone, with nothing written
and no verdict recorded.

### 9.3 Interleaving B — applied in YNAB, no outcome record

Run 1 applied ops 0 and 1. The machine lost power after YNAB accepted op 1 but
before the result record was appended. The log holds: `applied` for op 0,
`pending_apply` for op 1, nothing for op 2.

Run 2:

1. Gates pass.
2. Op 0: audit says `applied`, live matches → skip.
3. Op 1: intent record, no outcome. Verification reads `cat-B.budgeted` for the
   op's month and finds `250000` — it matches `after.budgeted`. Treat as applied.
   Backfill a synthetic record and warn:

   ```json
   {
     "timestamp": "2026-06-15T09:12:03Z",
     "schema_version": "1.0.0",
     "run_id": "run-2026-06-14",
     "operation_id": "op-0001-allocate-cat-B-7f8e9d0c1b2a",
     "operation_type": "allocate",
     "target_entity_ids": ["cat-B"],
     "before": { "budgeted": 0 },
     "after":  { "budgeted": 250000 },
     "tool": null,
     "result_status": "applied",
     "error_class": null,
     "applied_state": null,
     "dry_run": false
   }
   ```

   `tool: null` on an `applied`, non-dry-run record marks this as
   verification-derived, not first-hand
   ([§5.2](#52-interleaving-b--applied-in-ynab-no-audit-record)).

   ```text
   ⚠️  op-0001-allocate-cat-B-7f8e9d0c1b2a applied in YNAB but had no outcome record.
       Verified against live state and backfilled the audit trail.
   ```

4. Op 2: no record at all, and live state does not match `after` — it never ran.
   Apply it normally, write-ahead ordered.

---

## 10. What the wiring follow-up must build

Designed here, **not yet implemented**:

| # | Item | Lands in |
|---|---|---|
| 1 | Emit `operation.id` in the [§1.2](#12-encoding) grammar instead of an opaque id | the review's change-set emitter (M4-10) |
| 2 | Write-ahead intent records (`pending_apply`) for non-destructive ops | `assets/apply-executor.js` |
| 3 | The `pending_apply` row in the `result_status` table | `docs/audit-log.md` |
| 4 | Live-state verification of every skip/apply verdict, per [§4.1](#41-the-verification-query-per-operation-type) | the resume path in `commands/ynab-apply.md` Step 1b |
| 5 | Interleaving A and B handling, including the backfill record | the resume path |
| 6 | `fsync` per audit append ([§8](#8-audit-log-append-requirements-and-the-one-gap)) | `bin/audit-log.sh` |

Already implemented and unchanged by this design: the single-flight lock
(`bin/apply-lock.sh`), the auth preflight and its `error_class` / `applied_state`
stamping (`assets/apply-executor.js`), the per-op drift check, the
`(run_id, operation_id)` audit query in `/ynab-apply` Step 1b, and the
`pending_delete` two-phase trail on the delete path.
