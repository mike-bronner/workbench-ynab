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

## What ships today — `/ynab-apply` Step 1b — and what this design supersedes

Resume is not hypothetical. A resume path **ships today**:
[`/ynab-apply`](../commands/ynab-apply.md) **Step 1b — Idempotency guard**. It
solves state (1) — the clean prefix — and nothing else. Step 1b reads the audit
records for the proposal's `run_id`, collects the `operation_id`s carrying a
non-dry-run `result_status: applied`, and partitions those ops out of the set
**before the executor is ever invoked**:

```bash
APPLIED_IDS ← audit-log.sh run "$RUN_ID" \
  | jq 'select(.dry_run == false and .result_status == "applied") | .operation_id'
```

Because that partition happens ahead of the executor, the executor's
`readLiveState` / `isStale` drift seam
([`assets/apply-executor.js`](../assets/apply-executor.js) `prepareOp`) **never
runs for an op the log already calls `applied`** — and when *every* op is
recorded `applied`, Step 1b short-circuits the entire run ("Everything in this
proposal is already applied — nothing to do") with **zero live YNAB calls**.

**That is audit-only idempotency, and this design supersedes it.** Trusting
`result_status` as the sole verdict is precisely the failure mode #48 exists to
close: it is correct for the clean prefix and silently wrong for interleavings A
and B, because a record saying `applied` is *evidence that a mutation was
attempted*, never proof of the ledger's current contents. Concretely:

| | Step 1b as shipped | This design |
|---|---|---|
| Verdict source | audit `result_status` alone | **live YNAB state**, audit as corroborating evidence |
| Ops skipped with no live read | every op recorded `applied` | none — every op is live-verified before skip or dispatch |
| Interleaving A (record says `applied`, ledger disagrees) | silently skipped | flagged for manual review, never re-applied |
| Interleaving B (ledger changed, no record) | re-dispatched blind | detected, skipped, trail backfilled + warned |
| Whole-proposal short-circuit | exits with zero live calls | still exits early — but only after every op is live-confirmed |

The audit log keeps exactly the role it has today: it tells resume **where a run
got to**, and therefore where to look. What changes is that it no longer gets the
final word.

**This document changes no shipped behavior on its own.** It is the design the
resume implementation must build to; Step 1b's audit-only filter is superseded
*when that implementation lands*, not before, and until then remains correct for
the clean-prefix case it was written for. Two companion edits ship in this same
change so the tree carries **one** definition of GAP-11 rather than two:
[`assets/changeset-lifecycle.md`](../assets/changeset-lifecycle.md) §9, which
previously equated GAP-11 with "exactly the existing idempotency guard", and a
forward pointer in Step 1b itself.

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
| before step 1 | no record | live-verify (interleaving B path); **under this ordering the op cannot have been applied** — step 2 is unreachable if step 1 never ran — so live state reads not-applied → apply |
| between 1 and 2 | intent only | live-verify; not applied → apply; applied → record result + skip |
| between 2 and 3 | intent only, YNAB changed | live-verify; applied → record result + skip |
| after step 3 | intent + result | matched by key → live-verify → skip |

The first row is worth a caveat, because it reads differently depending on which
trail is on disk. **Under the designed write-ahead ordering**, "no record" implies
"not applied" — the ordering is precisely what buys that inference. **On today's
single-record trail** (result-only, no intent record for the non-destructive ops),
"no record" is genuinely ambiguous: the op may have been applied moments before
the crash with the result append never reached. That is the real interleaving-B
case, and resume handles it identically either way — *live-verify first*, then
apply or skip + backfill on what YNAB actually says. The ordering upgrade narrows
what the trail can mean; it never changes what resume does with it, which is why
the algorithm is correct on both trails.

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
            source                              ⧉  // proposal id — the review run id (envelope.source)
            op_index                            ⧉  // 0-based position in the ordered operations[] array
            op.type                             ⧉  // categorize | allocate | delete_duplicate | reconcile
            target_entity_id                    ⧉  // a single opaque id string — see the encoding note below
            canonical_json(intended_change(op))     // the intended-change digest
        )[0:16 bytes] )                             // 128 bits, ⧉ = 0x1F unit separator
```

**Five** fields are hashed. Four are exactly those the AC names — **proposal id
(`source`) + op index + target entity id + intended-change digest**. The fifth,
`op.type`, is a **deliberate addition beyond the AC**, and it is there for a
specific reason: `intended_change(op)` below is a *per-type* projection, so the
digest alone does not say which projection produced it. Hashing `op.type`
alongside it binds the digest to its own interpretation — changing an op's `type`
in place changes the key even if the projected fields happen to serialize
identically. It adds nothing to collision-resistance (`op_index` and `source`
already carry that, below); it is there to keep the digest self-describing.

**`target_entity_id` encoding.** It is exactly **one** id string per op — never a
composition, so there is no separator or ordering rule to get wrong:

| Op type | `target_entity_id` |
|---|---|
| `categorize` | `op.transaction_id` |
| `allocate` | `op.category_id` |
| `delete_duplicate` | `op.transaction_id` (the victim) |
| `reconcile` | `op.account_id` |

The month an `allocate` targets is **not** folded in here; it is hashed exactly
once, by that op type's `intended_change` projection below. Keeping it in one
place is deliberate — a value hashed in two spots under two different rules is a
stability bug waiting to happen. `op_index` and `source` supply uniqueness, so
`target_entity_id` never needs to be unique on its own.

### `intended_change(op)` — what "the intended change" actually is

The intended-change digest cannot simply be `canonical_json(after)`, because for
two of the four op types `after` does not carry the op's payload:

- **`delete_duplicate`** — `after` is schema-pinned to the constant
  `{"deleted": true}` ([`assets/changeset-schema.json`](../assets/changeset-schema.json),
  `deleteDuplicateOp.after.deleted` is a `const`), so it contributes **zero
  entropy**. The op's real payload is the victim (the op's own top-level
  `transaction_id`, already hashed as `target_entity_id`) plus the **surviving
  twin**, whose id is `deleteDuplicateOp.twin.id` — a *top-level* `twin` object,
  and note the twin's id field is `id`, **not** `transaction_id` (`transaction_id`
  on a delete op names the victim).
- **`reconcile`** — the transactions to mark cleared live in the *top-level*
  `transaction_ids` array (`reconcileOp.transaction_ids`), not inside `after`.

So the digest hashes a **per-type projection** of the op's mutation-determining
fields:

| Op type | `intended_change(op)` | Why |
|---|---|---|
| `categorize` | `{ after: { category_id: op.after.category_id } }` | `after.category_id` is the whole intent; `after.category_name` is schema-marked *"display only"* and is **excluded** — a category rename must not move the key |
| `allocate` | `{ after, month }` | `after.budgeted` is scoped to a specific budget `month` |
| `delete_duplicate` | `{ after, twin_id: op.twin.id }` | `after` is a constant; the twin is the pairing evidence that makes the delete meaningful |
| `reconcile` | `{ after, transaction_ids: sorted(op.transaction_ids ?? []) }` | the cleared-marking set is top-level, not in `after` |

`transaction_ids` is **sorted** before hashing so a pure reordering — the same op
semantically — yields the same key.

Deliberately **not** hashed: `before` (a snapshot of the world, not a statement of
intent — it can legitimately differ between two generations of the same proposal),
`rationale` / `risk` (human-facing metadata that does not change what the op does
to the ledger), and any field the schema marks **display only** — today that is
exactly `categorizeOp.after.category_name`. `allocate`, `reconcile` and
`delete_duplicate` carry no display-only fields in `after` (`{ budgeted }`,
`{ reconciled_balance, cleared }`, and the `{ deleted: true }` constant
respectively), so for those three the whole `after` object is mutation-determining
and is hashed as-is.

### `canonical_json` — pinned to RFC 8785 (JCS)

Cross-run key stability rests entirely on `canonical_json` emitting the **same
bytes for the same value on every run**, so the scheme is pinned here rather than
left to the implementer: `canonical_json` is **RFC 8785, the JSON Canonicalization
Scheme (JCS)**. Its relevant guarantees are object keys sorted by UTF-16 code
unit, no insignificant whitespace, minimal string escaping, ECMAScript
`Number::toString` number serialization, and UTF-8 output.

Every value in the projections above is an integer (milliunits), a string id, a
`YYYY-MM-DD` month, a boolean, or an array of string ids — **no floating-point
values** — so JCS number formatting is exact here and its awkward edges (exponent
form, `-0`) never arise.

**The stability proof below is conditional on this pin.** The producer (M4-10)
MUST use an RFC 8785 implementation; a hand-rolled `JSON.stringify` with ad-hoc
key sorting is **not** a substitute — it leaves number formatting, escaping, and
key-order rules unspecified, which is exactly what makes two runs disagree.

### Proof of stability and collision-resistance

- **Stable across runs of the same proposal.** All five inputs are frozen in the
  proposal file the moment it is produced: `source` is the envelope's provenance,
  `op_index` is the array position, and `op.type`, `target_entity_id` and every
  field `intended_change(op)` projects are the op's own frozen fields. A resume
  reads the *same* frozen file, so it recomputes the *same* key. Regenerating the
  proposal from the same review inputs yields the same five inputs and therefore
  the same key — no dependence on wall-clock time or a random seed (and, because
  `before` is excluded from the projection, no dependence on when the ledger was
  snapshotted either).
- **Collision-resistant within a change-set.** `op_index` is unique per proposal,
  so no two ops in one change-set can share a key even before the hash — the
  index alone disambiguates. This is the guarantee the design actually relies on,
  and it holds unconditionally.

  `source` *partially* extends that uniqueness across proposals: for
  review-generated proposals it is the review run id, which is distinct per run.
  But it is **not** a global discriminator — the schema explicitly permits the
  literal string `"manual"` ([`assets/changeset-schema.json`](../assets/changeset-schema.json),
  `source`: *"the review run id that produced it, or the literal `manual`"*), so
  **every human-authored proposal shares one `source` by design**. Two manual
  proposals can therefore collide on `(source, op_index)`.

  That degenerate case is harmless, and it is worth being precise about why
  rather than waving at it. A collision additionally requires identical `op.type`,
  `target_entity_id` **and** `intended_change` — i.e. the two ops are the *same
  mutation against the same entity*. Applying that mutation once or twice yields
  the same ledger state (the idempotent-or-detectably-safe table above), and
  resume does not decide from the key alone in any case: it live-verifies the
  op's current state and branches on that. So a key collision between two
  identical mutations cannot produce a wrong ledger — at worst one op's audit
  record is attributed to its twin, which the live-state check then resolves
  correctly. Distinct mutations never collide, which is the property the proof
  needs.
- **Tamper-evident over the op's own mutation-determining fields.** Folding
  `target_entity_id` and `canonical_json(intended_change(op))` into the hash binds
  the key to *what the op does to the ledger*. An in-place edit of a proposal file
  that changes the op's effect — a different target, a different `after`, a
  different surviving `twin` on a delete, a different `transaction_ids` set on a
  reconcile — changes the key, so resume treats it as a **new** op and refuses to
  falsely skip it as "already applied."

  That tamper-evidence is **scoped, not absolute**: editing `before`, `rationale`,
  or `risk` in place leaves the key unchanged **by design**, since none of them
  alters the mutation. The per-type projection exists precisely because the naive
  `canonical_json(after)` would *not* have this property — a `delete_duplicate`
  whose `twin` was swapped in place is a materially different and more dangerous
  op, and under an `after`-only digest (`after` being the constant
  `{"deleted": true}`) its key would not have moved at all.

  **One field that *does* affect the outcome is nonetheless excluded from the
  hash: `budget_id`.** It is required on all four op subtypes and it materially
  determines *which ledger* is mutated, so the claim above is scoped to the op's
  **target-and-intent** fields — not to every field that affects the result.
  Swapping `budget_id` in place does **not** move the key.

  That is safe, and the protection is worth naming precisely because it comes
  from a different layer than the key. The envelope carries one `budget_id`, the
  schema requires every op to match it, and
  [`assets/write-safety-guardrail.js`](../assets/write-safety-guardrail.js) blocks
  a mismatch with `BUDGET_ID_MISMATCH`. Critically, the executor runs
  `evaluateChangeset` as an **upfront whole-batch** gate before any per-op
  processing, and that gate loops over **every** operation — including ones a
  resume would go on to skip — with a single block aborting the **entire** batch
  ([`assets/apply-executor.js`](../assets/apply-executor.js), step 2). So a
  tampered `budget_id` is caught before resume reaches its skip/dispatch fork; the
  skip branch cannot smuggle one past. (The second, per-op `evaluateOperation`
  immediately before each tool call is defense-in-depth on the dispatch path only
  — a skipped op misses *that* re-check, but never the upfront one.)

  Folding `budget_id` into the hash would additionally make the tamper
  *self-evident in the key* rather than caught by a separate gate. The resume
  implementation issue may do so — it is a strict addition that breaks no property
  proved here.

  The unit-separator (`0x1F`) between fields prevents concatenation ambiguity
  (e.g. `"a" ‖ "bc"` never hashing equal to `"ab" ‖ "c"`).
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
out in [`docs/audit-log.md`](./audit-log.md) as the substrate this design reads to
decide **which recovery path a failed op takes** — `not_applied` → simply
un-applied, dispatch normally; `unknown` → interleaving A, resolve against live
state. This document is that reader; the fields route the decision, they never
replace the live-state check.

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
([`docs/mcp-capability-map.md`](./mcp-capability-map.md)), never inlined here
(with the two gaps noted under the table):

| Op type | Logical read verb | Field compared | "Already applied" when live == |
|---|---|---|---|
| `categorize` | `get_transaction` | `category_id` | `after.category_id` |
| `allocate` | `get_category` (with `month`) | that category's `budgeted` | `after.budgeted` |
| `delete_duplicate` | `get_transaction` (the victim) | existence / `deleted` flag | victim not-found or `deleted: true` |
| `reconcile` (mark cleared) | `get_transaction` / `list_transactions` | each listed txn's `cleared` | `after.cleared` on every `transaction_id` |
| `reconcile` (reconcile account) | `get_account` | account `reconciled_balance` (+ `cleared_balance`) | `after.reconciled_balance` |

Each row names the verb the executor's `readLiveState` seam **actually resolves
today**, and the ground truth for that is the wiring exercised end-to-end by
[`assets/test/e2e-write-back.test.js`](../assets/test/e2e-write-back.test.js)
(its `wirePorts` `readLiveState`, driven through the real `applyChangeset`):
`get_transaction` for categorize and delete_duplicate, **`get_category`**
(`budget_id` + `category_id` + `month`, returning `{ budgeted }`) for allocate,
and for reconcile `get_account` at account level plus `get_transaction` per
listed id. Reconcile's pair is also named in
[`skills/reconcile-write-path.md`](../skills/reconcile-write-path.md), which
documents `list_transactions` as the equivalent bulk read for the mark-cleared
ids even though the e2e harness exercises only the per-id form.

> **Not to be confused with `get_month`.** `get_month` *does* appear on the
> allocate path, which makes it an easy wrong answer here. But it appears only in
> **`dryRunAllocate`** ([`assets/allocate-handler.js`](../assets/allocate-handler.js)),
> which reads it — via an injected `getMonth` port rather than by calling the tool
> directly — once per distinct month to compute the advisory Ready-to-Assign
> over-allocation warning. That check is a **pre-approval, read-only preview that
> never blocks**, not the drift read. The handler owns **no** `readLiveState` at
> all; the executor owns the drift check, as the module's own header states. So
> `get_month` is **not** the tie-breaker verb for allocate. A `get_month` payload
> does carry per-category `budgeted` and would therefore *work* — but this table
> names the verb the code actually resolves, not one that would be sufficient.

> **Capability-map gap.** **Two** verbs in the table above — `get_account` and
> `get_category` — are currently **missing** from both tool-name sources of truth
> ([`docs/mcp-capability-map.md`](./mcp-capability-map.md) and
> `skills/protocol/ynab-tools.md`), even though both are real vendored tools used
> by tested drift paths (`get_account` by reconcile, `get_category` by allocate).
> Until that is fixed they are the two verbs in this table the map cannot resolve
> to a namespaced name. Cite them from the e2e wiring and
> `skills/reconcile-write-path.md` in the meantime. Tracked as **#247**, which
> covers the class rather than either verb individually — resolving it belongs
> there, not here. The gap is not cosmetic: a reader who cannot find a verb in
> the map tends to substitute a wrong-but-map-conformant one, which is exactly
> how `get_month` landed in this table in the first place.

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
detection, used for one extra decision.

**The staleness comparison is delegated per op type — resume never rolls its
own, with one documented exception (`reconcile_account`, below).** Each op type
already owns a staleness check, and resume calls that check rather than
applying one generic `Object.keys(...)` comparison to every op. This matters
most for `reconcile`, which is the **only** op type whose `before`/`after`
snapshots have no `required` fields in the schema
([`assets/changeset-schema.json`](../assets/changeset-schema.json) —
`categorizeOp` requires `category_id`, `allocateOp` requires `budgeted`,
`deleteDuplicateOp` requires seven, `reconcileOp` requires none). A schema-valid
reconcile op can therefore carry `before: {}` / `after: {}`, and the executor's
subset comparison `isStale`
([`assets/apply-executor.js`](../assets/apply-executor.js)) is
`Object.keys(before).some(...)` — **vacuously `false` for `{}`**, so an empty
snapshot matches *any* live state. Run through the generic three-way branch
above, `live == after` is tested first, so a reconcile op with `after: {}` would
vacuously match and take **ALREADY APPLIED → skip** before the CONFLICT fallback
is ever reached: resume would silently skip a real money op it never applied.

Production solved this — but **only for one of `reconcile`'s two sub-actions.**
`isReconcileStale`
([`assets/reconcile-handler.js`](../assets/reconcile-handler.js)) branches on the
sub-action, and only one branch carries the guard:

- **`mark_cleared` — guarded, and resume inherits it.** The branch fails
  **closed** on a missing `before.cleared` baseline
  (`if (baseline === undefined) return true;`), and its comment names this exact
  case: *"a schema-valid op can reach here with `before: {}`; fail CLOSED."*
- **`reconcile_account` — unguarded. ⚠️ Designed, not yet wired.** The branch is
  a bare `return isStale(op.before, live);` with no baseline check, so `before:
  {}` is vacuously non-stale here for exactly the reason the generic comparison
  above is. Delegation alone does **not** close the trap for this sub-action.
  Tracked as **#282**. Until that lands, resume must apply the empty-snapshot
  fail-closed rule below **itself** for `reconcile_account` rather than assume
  the delegate does it. Delegating and stopping there would silently skip a real
  money op.

So "delegate to the op type's own check" is the rule, and it is sufficient
**everywhere except `reconcile_account`**, which needs resume's own guard until
#282 ships. Do not read the rule as a blanket guarantee.

**Delegation answers "is it stale?", not "is it already applied."**
`isReconcileStale` reads only `op.before` — `op.after` is never referenced on its
staleness path. The delegated check therefore covers the `live == before` /
drift half of the three-way branch above. The `live == after` **ALREADY APPLIED**
half has no shipped per-op-type equivalent to delegate to, so resume computes it
itself, subject to the fail-closed rules below: an empty or baseline-free `after`
never counts as a match. This is the ordering that makes the trap dangerous —
`live == after` is tested first, before any delegated staleness check runs.

**Fail-closed throughout.** Each of these is treated as **not-confirmed-applied**,
and none of them ever triggers a silent re-apply:

- A `before`/`after` that is **not a comparable object** (`null`, an array, a
  scalar).
- An **empty or baseline-free snapshot** (`{}`, or a reconcile `before` with no
  `cleared` baseline). `{}` *is* a comparable object, so the clause above does
  not cover it — it needs naming separately. This is the vacuity trap. Resume
  enforces this rule **directly**, on both `before` and `after`, for **every** op
  type. Where the op type's own check already fails closed on it
  (`mark_cleared`), resume's rule is redundant and harmless; where it does not
  (`reconcile_account`, pending #282), resume's rule is the only thing standing
  between an empty snapshot and a silently skipped money op. Do not weaken this
  to "the delegate handles it."
- A **live read that throws** (network, 5xx, timeout). Resume has *less*
  evidence than a missing audit record, which §"Write-ahead ordering" already
  forbids dispatching on. So resume **does nothing to this op** — it does not
  skip it as applied and it does not dispatch it — and **reports it as
  unconfirmable** in the resume report. It stays un-applied and a human decides.
  This rule holds for **every** op type and **both** interleavings; the two
  procedures below cross-reference it rather than restating it.

An auth failure on the read is the one exception to "do nothing to this op": it
aborts the whole batch exactly as it does today
([`assets/apply-executor.js`](../assets/apply-executor.js) `prepareOp`), because
a revoked token invalidates every remaining op, not just this one.

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

- **the live read itself fails** (network, 5xx, timeout) → **unconfirmable.** Do
  nothing to this op — neither skip-as-applied nor dispatch — and report it. This
  is the general fail-closed rule from §"The unified resume decision"; it is not
  special to interleaving A.

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

- **the live read fails** (network, 5xx, timeout) → **unconfirmable.** Do nothing
  to this op — neither treat-as-applied nor dispatch — and report it. Same
  general fail-closed rule as interleaving A, from §"The unified resume decision".
  It bears restating here because interleaving B is the branch where a naïve
  "if it matches, skip; otherwise process normally" reading is most tempting: a
  thrown read is not a mismatch, and treating it as one would dispatch a
  mutating call on **zero** information. `categorize` / `allocate` / `reconcile`
  are value-idempotent (§"Consistency model"), so the fallout there would be a
  wasted call rather than corruption — but `delete_duplicate` is not, and the
  rule is uniform so no reader has to work out which is which.

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
2. **Global freshness gate (GAP-10) — the whole-proposal check. ⚠️ Designed, not
   yet wired.** Reject a proposal that is too stale to apply at all
   ([`assets/changeset-lifecycle.md`](../assets/changeset-lifecycle.md) §4). Global
   staleness rejects a *whole* proposal; per-op drift (the tie-breaker above) skips
   a *single* op — the two are distinct and both apply on resume.

   Unlike gates 1 and 3, **this one does not ship today**:
   [`commands/ynab-apply.md`](../commands/ynab-apply.md) states the global
   staleness gate is "wired when the lifecycle follow-up lands," and until then
   only the top-level `*.json` glob (which excludes retired proposals in
   `applied/` and `superseded/`) stands in for it. Resume therefore inherits this
   gate **as designed**, and inherits its absence as shipped: a resume run today
   clears gates 1 and 3 and relies on per-op live-state verification for
   everything the global check would otherwise catch. That is sound — the tie-
   breaker is per-op and does not depend on the proposal-level check — but it is
   weaker than the ordering below implies, and it becomes correct as written when
   the lifecycle follow-up lands.
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
write. This is identical to a first-time apply — **resume adds no gate and removes
none.** That equivalence is the load-bearing claim, and it holds in both worlds:
today, resume and first-time apply both run gates 1 and 3 and both skip the
unwired gate 2; once GAP-10 lands, both run all three in this order. Resume is
never the weaker path.

## Audit-log durability requirements — restated, and sufficient for resume

Deterministic resume relies on the audit log's write guarantees, restated here
from [`docs/audit-log.md`](./audit-log.md):

- **Append-only.** The writer only ever `>>`-appends; it never rewrites,
  truncates, or seeks. History is immutable, so a resume reads the same records
  a prior run wrote.
- **Atomic per record.** Each record is one compact `jq -c` line emitted with its
  terminating newline in a **single atomic `write(2)`** to an `O_APPEND` fd, so a
  crash leaves **either the whole newline-terminated record or nothing — never a
  torn line**. Resume therefore never has to reason about a half-written record;
  every record it reads is complete.
- **fsync'd per record. ⚠️ Requirement, not yet implemented.** Each record should
  be flushed to stable storage before the writer reports success, so a **power
  cut** — not just a process crash — leaves the trail intact. This does not hold
  today: [`bin/audit-log.sh`](../bin/audit-log.sh) does the atomic append above
  and returns; `grep -rn fsync bin/ docs/audit-log.md` returns **zero hits**.
  Atomic-append survives a process death (the kernel already has the bytes); it
  does **not** survive the machine losing power before the page cache is flushed.
  Tracked as **#275** against `bin/audit-log.sh`. Named here as a gap rather than
  dissolved by a wording change, the same way this document marks the GAP-10
  freshness gate "⚠️ Designed, not yet wired" and the `backfilled` field additive.
- **Ordered.** One file per UTC month, appended in processing order, so replaying
  a run's records (`audit-log.sh run <run_id>`) yields them in the order the ops
  were acted on.

**These requirements are sufficient for deterministic resume — and the three that
ship today are already sufficient for resume *correctness*.** Append-only +
atomic-per-record means the trail resume reads is a prefix of complete, ordered
records — exactly the "recoverable, ordered trail" a crash must leave. Combined
with live-state verification as the tie-breaker, resume needs nothing more from
the log: the log tells it *where a run got to*, and live YNAB state resolves
*anything the log cannot confirm*.

**Why the missing fsync does not block this design.** A tail lost to a power cut
produces exactly the shape §"Interleaving B" already handles: ops applied to
YNAB with no audit record. Resume live-verifies those, treats them as applied,
and backfills. So resume stays correct without fsync — which is precisely why
#275 is a tracked gap and not a blocker on this document.

**Why it still matters.** The audit log is not only a resume aid; it is the
**forensic** record of every money mutation this plugin makes
([`docs/audit-log.md`](./audit-log.md)). "The last N records were lost to a power
cut" is a materially worse failure for a compliance trail than "resume
recomputed it", and resume's ability to reconstruct *ledger state* does not
reconstruct the *evidence* of who changed what and when. That is the gap #275
closes, and it is why this document keeps fsync as a stated requirement instead
of narrowing the durability contract to what the code happens to do today.

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

This walkthrough is the **designed** behavior, and it is where the difference
from the shipped Step 1b is easiest to see: run the same scenario through Step 1b
today and all three ops are filtered out on `result_status` alone, short-circuiting
with **zero** live reads. The end state is identical *here* — because the audit
log happens to be telling the truth. Walkthroughs (b) and (c) are the cases where
it isn't, and there the three live reads above are the whole point.

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
