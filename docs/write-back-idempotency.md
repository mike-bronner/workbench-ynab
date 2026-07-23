# Idempotent resume of a partially-applied batch (GAP-11 / #48)

This is the design for **resuming an apply run that died partway through a
batch** without ever re-applying an operation twice or corrupting the ledger.
It is the design counterpart to the audit-log schema
([`docs/audit-log.md`](./audit-log.md), #57) and the executor
([`assets/apply-executor.js`](../assets/apply-executor.js), M4-4): the audit log
records what happened, the executor decides what to do, and this document
specifies how a *second* run reconciles the two after a crash.

> **The code is the source of truth.** This doc describes the resume behavior the
> M4 modules already make possible and the one additive field the resume
> implementation must add. Where it names existing behavior — the audit record
> shape, the `readLiveState`/`isStale` drift seam, the single-flight lock, the
> auth preflight — that behavior is authoritative in the referenced module and
> this doc must be corrected to match it if it drifts.

The write-back safety model this sits inside —
[`docs/write-back-safety.md`](./write-back-safety.md) — is unchanged: resume
adds no new write tool, no new approval bypass, and no new money-movement
surface. It only changes *which already-approved ops actually get dispatched* on
a re-run.

## The problem — three ways a batch can be left half-done

The apply executor walks a change-set's operations **in array order**
([`assets/changeset-contract.md`](../assets/changeset-contract.md) §1) and,
for each op it acts on, appends exactly one record to the append-only audit log
([`docs/audit-log.md`](./audit-log.md)). Between "the YNAB mutation lands" and
"the audit record is durably appended" there is a gap, and a crash, a killed
process, an OS reboot, or a network partition can land inside it. Three
dangerous states result:

1. **Clean prefix.** Ops `0..k` recorded `applied`; ops `k+1..n` never ran. A
   naïve re-run would re-apply `0..k`.
2. **Interleaving A — audit says applied, YNAB unconfirmable.** A record exists
   (`applied`, or `error` with `applied_state: unknown` after a 5xx / timeout
   *mid*-mutation) but the run can no longer confirm the change actually landed
   in YNAB.
3. **Interleaving B — apply-without-record.** The YNAB tool call **succeeded**
   but the audit append **failed** (or the process died between the two). YNAB
   shows the change; the audit log has no record of it.

For a money-adjacent system the exactly-once-vs-at-least-once question these
raise must be **designed, not left implicit** in a single acceptance-criterion
bullet. This document does that.

## Consistency model — at-least-once-with-detection

**The system targets at-least-once-with-detection, not exactly-once.** Exactly-once
would require atomically coupling a remote YNAB mutation with a local audit
append across a crash — a distributed-commit problem with no clean single-node
solution. We do not attempt it. Instead every op may be *dispatched* more than
once across runs, and a **live-state check before each dispatch** collapses that
to the correct end state.

This is safe because **every allowed operation is idempotent-or-detectably-safe**:

| Op type | Underlying write | Re-apply semantics |
|---|---|---|
| `categorize` | set a transaction's category to X | setting it to X twice yields X — idempotent |
| `allocate` | set a category's `budgeted` for a month to N | setting it to N twice yields N — idempotent |
| `reconcile` | mark listed txns cleared / reconcile account to balance B | converging to a target state; re-running converges to the same state — idempotent |
| `delete_duplicate` | delete transaction T | deleting T twice: the second call finds T already gone — **detectably** safe (a not-found is success, not an error) |

The three converge-to-a-target ops are naturally idempotent; the one destructive
op is *detectably* idempotent (a repeat delete is a no-op the resume path reads
as "already gone"). Because of this, **at-least-once-with-detection produces the
exact same final ledger state as exactly-once would** — without needing
distributed atomicity. The audit log is therefore treated as *corroborating
evidence*, never as the sole source of truth: when audit and live YNAB state
disagree, **live state wins** (see *The tie-breaker — live-state verification* below).

## Write-ahead ordering — record-intent → apply → record-result

The designed per-op ordering is **write-ahead**:

```
1. record-intent   append an intent record BEFORE the mutation
2. apply-op         dispatch the YNAB write tool
3. record-result    append the terminal result record AFTER the mutation
```

The worst case a crash can produce under this ordering is an **intent with no
result** — which resume handles by *rechecking live state*, never by blindly
re-applying. There is no ordering under which a crash forces a blind re-apply:

| Crash lands… | On-disk trail | Resume action |
|---|---|---|
| before step 1 | no record | live-verify (interleaving B path); the op is either not-yet-applied → apply, or already-applied → skip + backfill |
| between 1 and 2 | intent only | live-verify; not applied → apply; applied → record result + skip |
| between 2 and 3 | intent only, YNAB changed | live-verify; applied → record result + skip |
| after step 3 | intent + result | matched by key → live-verify → skip |

The destructive delete path **already implements this two-phase trail** today: it
appends a `pending_delete` intent record before the irreversible delete and the
outcome record after ([`docs/audit-log.md`](./audit-log.md), the `pending_delete`
row; #50). This design **generalizes that posture** to every op type. Until the
resume implementation lands the intent record for the non-destructive ops, the
algorithm below is *still correct* on the current single-record trail, because
**live-state verification — not the presence of a record — is the authoritative
tie-breaker.** The record tells resume where to *look*; live YNAB state tells it
what to *do*.

## The idempotency key

Every operation already carries a **stable per-op `id`**
([`assets/changeset-schema.json`](../assets/changeset-schema.json): *"Stable
per-operation id … Used for idempotent resume and audit"*), and every audit
record stores it as `operation_id` alongside the change-set's `source` as
`run_id`. The **idempotency key is the pair `(run_id, operation_id)`** —
equivalently `(changeset.source, op.id)`. Resume matches an op to its audit
record on exactly this pair and nothing else.

### Composition — how `op.id` is constructed

For the key to be reproducible even if the *same* proposal is regenerated from
the same review inputs, and collision-free within a change-set, the producer
MUST construct `op.id` **deterministically** as a content hash — not a random
UUID:

```
op.id = "op-" + base32_lower( SHA256(
            source            ⧉    // proposal id — the review run id (envelope.source)
            op_index          ⧉    // 0-based position in the ordered operations[] array
            op.type           ⧉    // categorize | allocate | delete_duplicate | reconcile
            target_entity_id  ⧉    // transaction_id | category_id(+month) | account_id
            canonical_json(after) // the intended-change hash
        )[0:16 bytes] )            // 128 bits, ⧉ = 0x1F unit separator
```

The four components are exactly those the AC names: **proposal id + op index +
target entity id + intended-change hash**.

### Proof of stability and collision-resistance

- **Stable across runs of the same proposal.** All four inputs are frozen in the
  proposal file the moment it is produced: `source` is the envelope's provenance,
  `op_index` is the array position, `target_entity_id` and `after` are the op's
  own fields. A resume reads the *same* frozen file, so it recomputes the *same*
  key. Regenerating the proposal from the same review inputs yields the same four
  inputs and therefore the same key — no dependence on wall-clock time or a
  random seed.
- **Collision-resistant within a change-set.** `op_index` is unique per proposal,
  so no two ops in one change-set can share a key even before the hash — the
  index alone disambiguates. `source` extends that uniqueness *across* proposals
  (two proposals never share a `source`; see the lifecycle's `source` disambiguator
  in [`assets/changeset-lifecycle.md`](../assets/changeset-lifecycle.md)).
- **Tamper-evident.** Folding `target_entity_id` and `canonical_json(after)` into
  the hash binds the key to *what the op does*. If a proposal file is edited in
  place — same slot, different target or different intended change — the key
  changes, so resume treats it as a **new** op and refuses to falsely skip it as
  "already applied." The unit-separator (`0x1F`) between fields prevents
  concatenation ambiguity (e.g. `"a" ‖ "bc"` never hashing equal to `"ab" ‖ "c"`).
- SHA-256 truncated to 128 bits keeps the second-preimage/collision margin far
  above the handful of ops in any real change-set.

### 1:1 alignment with the audit-log schema (#57)

Every key component and every field resume reasons over already exists in the
audit record — **no schema change is needed to match an op to its record.** The
mapping is exact:

| Key / evidence | Audit record field (#57) | Change-set origin |
|---|---|---|
| proposal id | `run_id` | envelope `source` (`run_id := source`) |
| **`op.id`** (composed) | `operation_id` | op `id` |
| op type | `operation_type` | op `type` |
| target entity id(s) | `target_entity_ids` | `transaction_id` / `category_id` / `account_id` |
| intended change (before → after) | `before`, `after` | op `before`, `after` |
| terminal outcome | `result_status` | executor `STATUS` (`applied`/`skipped-stale`/`blocked`/`error`) |
| failed-op posture | `error_class`, `applied_state` | executor `classifyError` (#50) |

The `run_id := source` identity is stated in
[`assets/changeset-lifecycle.md`](../assets/changeset-lifecycle.md) (the sidecar's
`audit_run_id` "Equals `source`") and enforced in the executor's `recordAudit`
(`run_id: changeset.source`). The `applied_state` / `error_class` pair is called
out in [`docs/audit-log.md`](./audit-log.md) as *"the substrate the
idempotent-resume design (#48) reads to reason about a failed op without
re-querying."* This document is that reader.

**One additive field is proposed** for interleaving B (below): a boolean
`backfilled` (default absent/`false`), set only on a record resume reconstructs
from live state. It is purely additive — it does not alter any existing field or
the `(run_id, operation_id)` key — and the resume implementation issue must add
it to the #57 writer. It is flagged here, not silently assumed.

## The tie-breaker — live-state verification

Live YNAB state is the **authoritative tie-breaker**: when the audit log is
absent, incomplete, or disagrees with reality, resume believes YNAB, not the log.
Resume reuses the executor's existing drift seam — `readLiveState(op)` re-reads
the op's live state and the design compares it to **both** the `before` and the
`after` snapshot (the executor today compares only to `before`, via `isStale`;
resume extends the comparison to `after`). The read tools, by op type, are the
same logical read verbs the drift check already uses — the concrete namespaced
names live in the single-source-of-truth capability map
([`docs/mcp-capability-map.md`](./mcp-capability-map.md)), never inlined here:

| Op type | Read verb (see capability map) | Field compared | "Already applied" when live == |
|---|---|---|---|
| `categorize` | `get_transaction` | `category_id` | `after.category_id` |
| `allocate` | `get_month` (category under `month`) | that category's `budgeted` | `after.budgeted` |
| `delete_duplicate` | `get_transaction` (the victim) | existence / `deleted` flag | victim not-found or `deleted: true` |
| `reconcile` (mark cleared) | `list_transactions` | each listed txn's `cleared` | `after.cleared` on every `transaction_id` |
| `reconcile` (reconcile account) | `list_accounts` | account `reconciled_balance` (+ `cleared_balance`) | `after.reconciled_balance` |

### The unified resume decision

For each op, in array order, after the gates below, resume reads live state once
and branches on a three-way comparison:

```
live == after                 → ALREADY APPLIED. Skip (idempotent). If no
                                 result record exists, record one (backfill).
live == before (and != after) → NOT YET APPLIED. Dispatch the op normally;
                                 the executor's guardrail + audit apply as usual.
live == neither               → CONFLICT / third-party drift. Do NOT re-apply.
                                 Route by evidence: audit says applied → flag
                                 for manual review; otherwise skip as
                                 skipped-stale (the executor's existing verdict).
```

This is the same `readLiveState` read the executor already performs for drift
detection, used for one extra decision. Fail-closed throughout: a `before`/`after`
that is not a comparable object, or a read that throws, is treated as
**not-confirmed-applied** and never triggers a silent re-apply — an auth failure
on the read aborts the whole batch exactly as it does today
([`assets/apply-executor.js`](../assets/apply-executor.js) `prepareOp`).

## Recovery procedures for the two dangerous interleavings

### Interleaving A — audit says "applied", live YNAB unconfirmable

A record for `(run_id, op.id)` exists with `result_status: applied`, **or** with
`result_status: error` and `applied_state: unknown` (a 5xx / network timeout
*mid*-mutation, where the write may or may not have landed). Resume must not
trust the record blindly.

**Procedure — query live YNAB state first, then:**

- **live == `after` (match)** → the change is in the ledger. **Skip.** No
  re-apply. (If the record was `error/unknown`, append a corrected `applied`
  result so the trail reflects reality.)
- **live != `after` (mismatch)** → the ledger does not show the intended change
  despite the record. **Flag for manual review — never auto-re-apply.** A record
  claiming `applied` that reality contradicts is a genuine inconsistency in a
  money-adjacent trail; silently re-applying could clobber a value a human or a
  later run set deliberately. Surface it to the human and stop touching that op.

An `error` record with `applied_state: not_applied` is **not** interleaving A: a
4xx means YNAB rejected the call and nothing changed, so the op is simply
un-applied and resume dispatches it normally (live will read `== before`).

### Interleaving B — YNAB applied, no audit record (apply-without-record)

No record exists for `(run_id, op.id)`, but live YNAB state shows the change.
The tool call succeeded and the audit append failed or the process died between
them.

**Procedure — verify live state, then treat as applied and heal the trail:**

- **live == `after`** → the change is already in the ledger. **Treat as applied**
  — lean on YNAB idempotency; do **not** re-dispatch.
- **Heal the gap by backfilling a synthetic audit record** (marked `backfilled: true`,
  `result_status: applied`, `run_id` = the proposal `source`, timestamped at
  resume time) **and emit a warning** to the resume report / `STDERR`.

  **Why backfill rather than only warn:** the audit log's entire purpose is a
  **complete, replayable** evidence trail for every ledger mutation
  ([`docs/audit-log.md`](./audit-log.md)). A silent skip would leave a permanent
  hole where a real mutation happened — the worst outcome for a money trail.
  Backfilling is still strictly **append-only** (a new record appended at EOF,
  never a rewrite), and the `backfilled: true` marker keeps it **honest**: the
  record is explicitly *inferred from live state at resume time*, not *observed
  at apply time*, so no reader mistakes reconstruction for original evidence. The
  warning is emitted **as well**, so a human knows a gap was healed and can
  investigate why the original append was lost.

- **live != `after`** → the op genuinely never applied (no record *and* no ledger
  change). Dispatch it normally.

## Resume prerequisites — the same gates as any apply, in order

A resume run **is** an apply run against an already-approved, already-persisted
proposal. It inherits every gate the first run passed, in the same order, and
must clear them **before processing any op**:

1. **Single-flight lock (#51) — first, before reading the proposal.** Acquire the
   GAP-9 concurrency lock ([`bin/apply-lock.sh`](../bin/apply-lock.sh)) so a
   scheduled review or a second interactive apply cannot run against the same
   proposal concurrently. If it is held, back off and exit — do not resume. The
   lock is **held across the entire resume lifecycle** and released at every exit.
   It authorizes nothing (it carries only pid + timestamp + operation); it purely
   serializes actors ([`docs/write-back-safety.md`](./write-back-safety.md), "The
   single-flight lock authorizes nothing").
2. **Global freshness gate (GAP-10) — the whole-proposal check.** Reject a
   proposal that is too stale to apply at all
   ([`assets/changeset-lifecycle.md`](../assets/changeset-lifecycle.md) §4). Global
   staleness rejects a *whole* proposal; per-op drift (the tie-breaker above) skips
   a *single* op — the two are distinct and both apply on resume.
3. **Auth preflight (#50) — before the first mutation.** A cheap read-only YNAB
   call confirms the token is valid and write-capable. Any failure (401 / 403 /
   network) aborts the whole batch: zero mutations, and **no audit record for any
   op that never ran** ([`assets/apply-executor.js`](../assets/apply-executor.js)
   step 3.5). Dry-run resume skips the preflight (it never mutates).
4. **Only then** process ops in array order, each through the unified resume
   decision above.

**Ordering is explicit: lock → freshness → auth preflight → per-op processing.**
The lock is taken before the proposal is even read (so nothing else can mutate it
underneath the resume); the auth preflight is the last gate before the first
write. This is identical to a first-time apply — resume adds no gate and removes
none.

## Audit-log durability requirements — restated, and sufficient for resume

Deterministic resume relies on the audit log's write guarantees, restated here
from [`docs/audit-log.md`](./audit-log.md):

- **Append-only.** The writer only ever `>>`-appends; it never rewrites,
  truncates, or seeks. History is immutable, so a resume reads the same records
  a prior run wrote.
- **Atomic per record (the durability property).** Each record is one compact
  `jq -c` line emitted with its terminating newline in a **single atomic
  `write(2)`** to an `O_APPEND` fd, so a crash leaves **either the whole
  newline-terminated record or nothing — never a torn line**. Resume therefore
  never has to reason about a half-written record; every record it reads is
  complete. (An explicit `fsync` per record would add power-loss durability on
  top of this atomicity; the atomic-append guarantee is what resume's
  *correctness* depends on, and it holds today.)
- **Ordered.** One file per UTC month, appended in processing order, so replaying
  a run's records (`audit-log.sh run <run_id>`) yields them in the order the ops
  were acted on.

**These three are sufficient for deterministic resume.** Append-only + atomic-per-record
means the trail resume reads is a prefix of complete, ordered records — exactly
the "recoverable, ordered trail" a crash must leave. Combined with live-state
verification as the tie-breaker, resume needs nothing more from the log: the log
tells it *where a run got to*, and live YNAB state resolves *anything the log
cannot confirm*.

## Worked walkthrough

A proposal `run_id = run-2026-06-19-weekly` with three ops, applied in order:

- **op-A** `categorize` txn-1 → category `c9`
- **op-B** `allocate` category `c3` for `2026-06-01` → `budgeted: 250000`
- **op-C** `delete_duplicate` txn-7

### (a) Clean resume — everything already applied, all skipped

The first run completed all three and recorded `applied` for each, then the
*reporting* step crashed and the run was re-invoked. Resume:

1. Acquires the lock, passes freshness, passes auth preflight.
2. op-A: record `(run-2026-06-19-weekly, op-A.id)` = `applied`. Live-verify:
   txn-1's `category_id == c9` (== `after`) → **skip**.
3. op-B: record `applied`. Live-verify: category `c3` `budgeted == 250000`
   (== `after`) → **skip**.
4. op-C: record `applied`. Live-verify: txn-7 not-found (== "already gone") →
   **skip**.

**Result: zero mutations, ledger unchanged, batch marked complete.** The naïve
"re-apply everything" bug is avoided entirely.

### (b) Interleaving A — op-B errored mid-mutation, unconfirmable

The first run applied op-A, then op-B's `update_category` returned a 504 *after*
the request reached YNAB. The executor recorded op-B as `error` with
`applied_state: unknown`, then the process was killed before op-C. Resume:

1. op-A: `applied` + live `== after` → **skip**.
2. op-B: record is `error / applied_state: unknown` → interleaving A. **Query
   live first:**
   - *Sub-case B-applied:* category `c3` `budgeted == 250000` (== `after`) → the
     write did land despite the 504 → **skip**, and append a corrected `applied`
     result so the trail is truthful.
   - *Sub-case B-conflict:* category `c3` `budgeted == 180000` (neither `before`
     nor `after` — someone re-budgeted it by hand) → **flag for manual review,
     do not re-apply.** Resume does not clobber the human's value.
3. op-C: no record yet → falls through to the interleaving-B / normal path (live
   shows txn-7 still present, `== before`) → **dispatch normally.**

### (c) Interleaving B — op-C applied, append lost

The first run applied op-A and op-B (both recorded), then op-C's delete
**succeeded** but the process was `kill -9`'d before the audit append. Resume:

1. op-A, op-B: records present, live `== after` → **skip** both.
2. op-C: **no record** for `(run-2026-06-19-weekly, op-C.id)`. Live-verify:
   txn-7 is **not-found** (== `after`, "already gone") → **treat as applied**,
   do not re-delete. **Backfill** a synthetic record (`backfilled: true`,
   `result_status: applied`, timestamped now) and **emit a warning** that op-C's
   original append was lost and reconstructed.

**Result: zero re-applies, the trail is healed and honest, the human is warned.**

---

**See also:** [`docs/audit-log.md`](./audit-log.md) (#57, the record shape and
durability), [`docs/write-back-safety.md`](./write-back-safety.md) (the write-back
safety model and the single-flight lock), [`assets/changeset-contract.md`](../assets/changeset-contract.md)
and [`assets/changeset-lifecycle.md`](../assets/changeset-lifecycle.md) (the
change-set envelope, `source`/`run_id`, and staleness), and
[`assets/apply-executor.js`](../assets/apply-executor.js) (the executor, its
`readLiveState`/`isStale` drift seam, auth preflight, and `error_class` /
`applied_state`).
