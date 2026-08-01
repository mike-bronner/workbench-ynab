#!/usr/bin/env bash
# Unit tests for docs/write-back-idempotency.md — the GAP-11 / issue #48
# idempotent-resume design. Run directly: tests/unit/write-back-idempotency-doc.test.sh
#
# The deliverable of #48 is a DESIGN, so its acceptance criteria are content
# invariants: the key composition and its encoding grammar, the write-ahead
# ordering and its worst-case claim, the named consistency model, the per-op-type
# live-verification query, both interleaving recovery procedures, the resume
# preconditions IN ORDER, the audit-schema field mapping, the append requirements,
# and three worked walkthroughs. This file pins each one so a later edit cannot
# silently gut it while leaving the headings behind.
#
# It also cross-checks the doc against the CODE for the one claim that could rot
# into a lie: the doc states bin/audit-log.sh does NOT fsync. If someone adds an
# fsync, this test fails and forces the doc to be corrected.
#
# Style mirrors tests/unit/docs-set.test.sh: raw bash, `set -u`, PASS/FAIL
# counters, non-zero exit on any failure.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOC="docs/write-back-idempotency.md"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
no() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# has <desc> <literal> — the literal must appear in the design doc.
has() {
  local desc="$1" needle="$2"
  if grep -qF -- "$needle" "$REPO_ROOT/$DOC" 2>/dev/null; then
    ok "$desc"
  else
    no "$desc"
  fi
}

# has_in <file> <desc> <literal> — the literal must appear in another file.
has_in() {
  local file="$1" desc="$2" needle="$3"
  if grep -qF -- "$needle" "$REPO_ROOT/$file" 2>/dev/null; then
    ok "$desc"
  else
    no "$desc"
  fi
}

echo "write-back-idempotency-doc.test.sh — the issue #48 design invariants"

# --- AC 1: the document exists -------------------------------------------------
if [ -f "$REPO_ROOT/$DOC" ]; then
  ok "$DOC exists"
else
  no "$DOC exists"
  echo ""
  echo "passed: $PASS  failed: $FAIL"
  exit 1
fi

# --- AC 2: key composition, encoding, stability, collision resistance ----------
# Each of the four components is pinned to its OWN composition-table row, so
# dropping any single component fails (a whole-file grep for e.g. "op index"
# would still match the prose elsewhere).
has "key composition: proposal id row" "| **proposal id** | the envelope's \`source\`"
has "key composition: op index row" "| **op index** | the operation's 0-based position in \`operations[]\`"
has "key composition: target entity id row" "| **target entity id** | \`transaction_id\` / \`category_id\` / \`account_id\`"
has "key composition: intended-change digest row" "| **intended-change digest** | SHA-256 over the canonical intended change"
# The digest covers intent only — the reason `before` is excluded is the load-bearing
# argument (a key that moves when the world moves breaks resume exactly when it matters).
has "digest excludes before" "It deliberately excludes \`before\`,"
has "digest excludes rationale and risk" "\`rationale\` and \`risk\` are human-facing text"
has "digest excludes before: the stated reason" "the key would change exactly when the world moved"
# Encoding grammar — the production plus each terminal.
has "encoding: the id production" 'operation.id  ::=  "op-" <index> "-" <type> "-" <entity_id> "-" <digest>'
has "encoding: index is zero-padded to 4 digits" "the 0-based array position, zero-padded to 4 decimal digits"
has "encoding: digest is 12 hex chars of SHA-256" "the first 12 lowercase hex characters of the SHA-256"
# shellcheck disable=SC2016  # a literal needle: no backtick expansion wanted
has "encoding: the full key is the (run_id, operation_id) pair" '**`(run_id, operation_id)`**'
has "encoding: no schema change is needed" "picks the deterministic-key option and fixes its grammar"
# Stability proof — the operative claim, not just the heading.
has "stability: no clock, randomness, locale, or float" "Nothing in the key reads a clock, a random source, a locale, or a float"
has "stability: an edit produces a new proposal id" "An edit produces a **new**"
# Collision proof — uniqueness comes from the index, and the digest's real job.
has "collision: uniqueness comes from the index, not the hash" "Collision resistance comes from the **index**, not from the hash"
has "collision: cross-proposal lookups are scoped by run_id" "resume queries the audit log by \`run_id\`"
has "collision: the digest is a tamper detector" "It is a **tamper detector**"
has "collision: a tampered op is treated as NOT applied" "**not applied** and re-verifies against live state"

# --- AC 3: write-ahead ordering and the worst-case claim -----------------------
has "write-ahead: step 1 records intent" '1. record intent   →  append { result_status: "pending_apply" }'
has "write-ahead: step 2 applies the op" "2. apply the op    →  call the namespaced YNAB write tool"
has "write-ahead: step 3 records the result" '3. record result   →  append { result_status: "applied" | "error" | … }'
has "write-ahead: intent is written BEFORE the mutation" "written **before** the mutation, never after"
has "write-ahead: worst case is a recheck, never a blind re-apply" \
  "**The worst case is a recheck, never a blind re-apply.**"
has "write-ahead: apply-first ordering was considered and rejected" "was rejected"
has "write-ahead: the new pending_apply status is declared" "| \`pending_apply\` | the executor, before every non-destructive mutation"
# The design also puts human_review_required on the trail; both deltas must stay declared.
has "write-ahead: the human_review_required trail delta is declared" "| \`human_review_required\` | resume, for an "

# --- AC 4: the named consistency model, with justification ---------------------
has "model: at-least-once with detection is named as chosen" \
  "**The chosen model is at-least-once with detection.**"
has "model: exactly-once is explicitly not claimed" "Exactly-once is not"
has "model: justification — no two-phase commit across the boundary" "no two-phase commit"
has "model: justification — three ops are idempotent by value" "**Three of the four operations are idempotent by value.**"
has "model: delete is the non-idempotent exception" "never auto-re-applied.** Deleting is not value-idempotent"

# --- AC 5: interleaving A recovery, fully specified ----------------------------
has "interleaving A: heading" "### 5.1 Interleaving A — the audit says applied, live state disagrees"
has "interleaving A: live read first" "query live state first"
has "interleaving A: match ⇒ skip" "| succeeds, matches \`after\` | applied | **skip** the op"
has "interleaving A: mismatch ⇒ manual review, never re-apply" \
  "| conflict | **flag for manual review.** Do not re-apply."
has "interleaving A: failed read ⇒ unconfirmable, op untouched" \
  "| unconfirmable | **do nothing to this op.**"
has "interleaving A: why a mismatch is never auto-re-applied" "never clobber a value the human never saw"

# --- AC 6: interleaving B recovery, fully specified ----------------------------
has "interleaving B: heading" "### 5.2 Interleaving B — applied in YNAB, no audit record"
has "interleaving B: live match ⇒ treat as applied" "**treat the op as applied.**"
has "interleaving B: leans on YNAB idempotency" "leans on"
has "interleaving B: the choice is backfill, and it is named" "**Backfill, not warn-only — and why.**"
has "interleaving B: reason — warn-only is non-convergent" "**Warn-only leaves the resume non-convergent.**"
has "interleaving B: a warning is emitted as well" "The warning is emitted **as well**"
has "interleaving B: the backfill marker needs no schema change" \
  "= **verification-derived backfill, not a first-hand apply**"
# shellcheck disable=SC2016  # a literal needle: no backtick expansion wanted
has "interleaving B: the marker is tool: null on an applied real record" '**`tool: null`**'

# --- AC 7: live state is the tie-breaker, with the per-op-type query -----------
has "tie-breaker: the budget wins over the log" \
  "**The audit log is evidence. The budget is truth.**"
# One row per op type, each pinning verb AND field — so dropping a row, or
# swapping a verb/field, fails.
has "verify query: categorize" "| \`categorize\` | \`ynab_get_transaction\` | \`category_id\` |"
has "verify query: allocate" "| \`allocate\` | \`ynab_get_month\` (for the op's \`month\`) | the target category's \`budgeted\` |"
has "verify query: delete_duplicate" "| \`delete_duplicate\` | \`ynab_get_transaction\` (the victim id) | existence |"
has "verify query: reconcile" "| \`reconcile\` | \`ynab_list_accounts\` for the account;"
has "verify query: compare only the fields named in after" "**Compare only the fields the op names in \`after\`.**"
has "verify query: compare milliunits as integers" "**Compare milliunits as integers.**"
has "verify query: a delete must separate 404 from other read failures" \
  "verification must distinguish 404 from every other read"

# --- AC 8: resume preconditions, and their ORDER ------------------------------
has "preconditions: lock (GAP-9 / #51)" "**Acquire the single-flight lock** (GAP-9 / #51)"
has "preconditions: staleness gate (GAP-10)" "**Select the proposal and run the global staleness gate** (GAP-10)"
has "preconditions: auth preflight (GAP-8 / #50)" "**Pass the auth preflight** (GAP-8 / #50)"
has "preconditions: nothing is processed until all three pass" "processes **no** operation until all three have passed"
has "preconditions: why the preflight precedes the verification reads" \
  "**Why the auth preflight comes before the verification reads"
# The ORDER is an AC requirement, so assert it positionally rather than trusting
# that three present bullets happen to be in sequence.
lock_line="$(grep -nF -- "**Acquire the single-flight lock**" "$REPO_ROOT/$DOC" | head -1 | cut -d: -f1)"
stale_line="$(grep -nF -- "**Select the proposal and run the global staleness gate**" "$REPO_ROOT/$DOC" | head -1 | cut -d: -f1)"
auth_line="$(grep -nF -- "**Pass the auth preflight**" "$REPO_ROOT/$DOC" | head -1 | cut -d: -f1)"
if [ -n "$lock_line" ] && [ -n "$stale_line" ] && [ -n "$auth_line" ] \
   && [ "$lock_line" -lt "$stale_line" ] && [ "$stale_line" -lt "$auth_line" ]; then
  ok "preconditions are ordered lock → staleness → auth preflight"
else
  no "preconditions are ordered lock → staleness → auth preflight"
fi

# --- AC 9: 1:1 mapping onto the #57 audit-log schema fields -------------------
has "schema map: proposal id → run_id" "| proposal id | \`run_id\` |"
has "schema map: index+entity+digest → operation_id" "| op index + entity id + digest | \`operation_id\` |"
has "schema map: entity id → target_entity_ids" "| target entity id | \`target_entity_ids\` |"
has "schema map: applied is the only done status" 'is the only status that means "done"'
has "schema map: a resume matches only dry_run:false records" "a resume matches only \`dry_run: false\` records"
# The doc reproduces the Step 1b lookup; it must stay the query the command runs.
has "schema map: the audit lookup query" 'select(.dry_run == false and .result_status == "applied") | .operation_id'
has_in commands/ynab-apply.md "the reproduced lookup matches /ynab-apply Step 1b" \
  'select(.dry_run == false and .result_status == "applied") | .operation_id'

# --- AC 10: append requirements restated, with honest status ------------------
has "append: append-only is implemented" "| **Append-only** | ✅ implemented |"
has "append: ordering is implemented" "| **Ordered** | ✅ implemented |"
has "append: one atomic write per record" "| **One record per atomic write** | ✅ implemented |"
has "append: fsync is NOT implemented, and is called out" "| **\`fsync\` per record** | ❌ **not implemented** |"
has "append: the missing fsync degrades to interleaving B, not to a wrong decision" \
  "not into a wrong decision"
has "append: the three implemented properties suffice for deterministic resume" \
  "Append-only + ordered + atomic-per-record **are** sufficient for deterministic"
# Honesty cross-check against the CODE: the doc claims bin/audit-log.sh does not
# fsync. If that ever changes, the doc must change with it — fail here.
if grep -qE '(^|[^[:alnum:]_])(fsync|sync)([^[:alnum:]_]|$)' "$REPO_ROOT/bin/audit-log.sh" 2>/dev/null; then
  no "the doc's 'no fsync' claim still matches bin/audit-log.sh"
else
  ok "the doc's 'no fsync' claim still matches bin/audit-log.sh"
fi

# --- AC 11: three worked walkthroughs ----------------------------------------
has "walkthrough (a): clean resume, everything skipped" \
  "### 9.1 Clean resume — every op already applied, everything skipped"
has "walkthrough (a): calls no write tool" "Calls no write tool"
has "walkthrough (b): interleaving A" \
  "### 9.2 Interleaving A — the trail says applied, the budget says otherwise"
has "walkthrough (b): the conflicting op is not re-applied" "It is **not** re-applied"
has "walkthrough (c): interleaving B" \
  "### 9.3 Interleaving B — applied in YNAB, no outcome record"
has "walkthrough (c): shows the backfilled record with tool: null" '"tool": null,'

# --- Honesty: design vs. implementation, and the follow-up list ---------------
has "the doc states it is a design, not the implementation" \
  "**Scope: this document is the design, not the implementation.**"
has "the doc lists what the wiring follow-up must build" \
  "## 10. What the wiring follow-up must build"

# --- Cross-links: every doc that anticipates this design points at it ---------
# Require a real markdown LINK target, not a bare mention: a prose reference to the
# filename with the link retargeted elsewhere is drift, and must fail.
for f in docs/audit-log.md docs/write-back-safety.md assets/changeset-lifecycle.md commands/ynab-apply.md; do
  if grep -qE '\]\([^)]*write-back-idempotency\.md\)' "$REPO_ROOT/$f" 2>/dev/null; then
    ok "$f links the resume design"
  else
    no "$f links the resume design"
  fi
done

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
