#!/usr/bin/env bash
# Unit tests for docs/write-back-idempotency.md (GAP-11 / issue #48).
#
# This file deliberately does NOT re-assert the document's prose against itself.
# Grepping a doc for a sentence the same doc supplies proves nothing — it passes
# just as happily when the sentence is wrong. Every assertion here pins a claim
# the document makes about the CODE against that code, so the test goes red when
# the two drift apart. Three drift classes are covered:
#
#   1. Live-read tool names. The tie-breaker table names one read verb per op
#      type. The wrong verb has now been written into this table twice (once
#      `list_accounts` for reconcile, once `get_month` for allocate) because the
#      capability map is missing `get_account`/`get_category` (issue #247), so an
#      author deferring to the map lands on a wrong-but-map-conformant name.
#      EVERY row is checked against the wiring
#      `assets/test/e2e-write-back.test.js` actually drives through the real
#      executor, and the row count is itself asserted — a row added to the table
#      without a matching tuple below fails the suite rather than drifting
#      unchecked, which is how two rows went uncovered before.
#
# Assertions about the document are scoped to the row or callout they name, never
# a whole-file grep. Every verb in the tie-breaker table is also discussed in the
# prose below it, so an unscoped search stays green through a straight cell swap —
# the very drift class 1 exists to catch. The e2e side is scoped the same way, to
# the one `readLiveState` branch that serves the row: `get_transaction` is wired
# twice in that function alone, so a whole-file match cannot tell the two apart.
#   2. Fail-closed premises. The document's reconcile vacuity argument rests on
#      `reconcileOp.before`/`.after` having no `required` array in the schema, and
#      on `isReconcileStale` existing to delegate to. Both are read from source.
#   3. The fsync gap. The document marks fsync-per-record a requirement that is
#      not implemented (issue #275). That marker must come down when the code
#      lands, so the test asserts the gap is REAL — if `bin/audit-log.sh` gains an
#      fsync and the doc still calls it missing, this fails.
#
# Style mirrors tests/unit/docs-set.test.sh: raw bash, `set -u`, PASS/FAIL
# counters, non-zero exit on any failure.
#
# Tool names appear here only in their BARE form (`get_account`, never the
# namespaced `mcp__…__ynab_get_account`), so this file stays clean under
# bin/check-tool-name-sources.sh.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOC="docs/write-back-idempotency.md"
E2E="assets/test/e2e-write-back.test.js"
SCHEMA="assets/changeset-schema.json"
RECONCILE="assets/reconcile-handler.js"
RECONCILE_SKILL="skills/reconcile-write-path.md"
AUDIT="bin/audit-log.sh"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
no() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# has <file> <literal> — literal (non-regex) match anywhere in the file.
# Whole-file scope is only sound for a needle the file mentions in ONE place. For
# anything the document also discusses in prose, extract the row or callout first
# (see sections 1 and 3) — otherwise the prose keeps the assertion green while the
# pinned row drifts.
has() { grep -qF -- "$2" "$REPO_ROOT/$1" 2>/dev/null; }

# in_text <text> <literal> — literal match inside an already-extracted fragment.
in_text() { printf '%s\n' "$1" | grep -qF -- "$2"; }

echo "write-back-idempotency-doc.test.sh — doc claims vs. the code they describe"

# --- 0. the document exists (AC #1) ------------------------------------------
if [ -f "$REPO_ROOT/$DOC" ]; then
  ok "$DOC exists"
else
  no "$DOC exists"
  echo "FATAL: design document missing — remaining assertions would be vacuous."
  exit 1
fi

# --- 1. tie-breaker verbs: doc ROW  <->  real e2e wiring BRANCH ---------------
# Each tuple is (verb, the table row that must name it, op label, the e2e
# `readLiveState` branch that serves it). The verb must appear BOTH in that row of
# the doc's tie-breaker table AND in that branch of the wiring the e2e harness
# drives through the real applyChangeset. Checking only the doc would pass on a
# fabricated name; checking only the code would pass while the doc named something
# else entirely.
#
# Both sides are scoped. The doc side is one table ROW, never the whole document:
# every verb in this table is also discussed in the prose under it, so a
# whole-document grep stays green even when two table cells are swapped — the
# exact drift this section exists to catch. The e2e side is one BRANCH of
# `readLiveState`, never the whole file: `get_transaction` is wired twice in that
# one function (the transaction branch and, per listed id, the reconcile branch),
# so a whole-file match cannot tell a row's own wiring from a sibling's.
#
# There is one tuple per row of the table, all five. A row with no tuple is a row
# that drifts silently, which is how two of them went unchecked before.
echo "  -- live-read verbs cross-checked against $E2E"

# The tie-breaker table alone: its header row through the blank line ending it.
# The header is unique in the document; the three other tables use different ones.
table="$(awk '/^\| Op type \| Logical read verb \|/{f=1} f&&/^$/{exit} f' "$REPO_ROOT/$DOC")"
if [ -z "$table" ]; then
  no "the tie-breaker table is locatable in $DOC"
fi

# row <first-cell> — the one table row whose leading cell is <first-cell>.
row() { printf '%s\n' "$table" | grep -F -- "| $1 |"; }

# e2e_branch <label> — the lines of e2e's `readLiveState` that serve <label>.
# Branch boundaries are the op.type guards themselves, so the cut tracks the
# wiring rather than line numbers. `categorize` and `delete_duplicate` genuinely
# share one branch in the source; both map to `transaction`.
e2e_branch() {
  awk -v want="$1" '
    /const readLiveState/ { fn = 1 }
    /const applyOp/       { fn = 0 }
    !fn { next }
    /op\.type === .categorize./    { b = "transaction" }
    /op\.type === .allocate./      { b = "allocate" }
    /^[[:space:]]*\/\/ reconcile:/ { b = "reconcile" }
    b == want { print }
  ' "$REPO_ROOT/$E2E"
}

covered=0
while IFS='@' read -r verb rowcell optype branch; do
  [ -n "$verb" ] || continue
  covered=$((covered + 1))
  this_row="$(row "$rowcell")"
  wiring="$(e2e_branch "$branch")"
  if [ -z "$this_row" ]; then
    no "the tie-breaker table has a row for $optype"
  elif ! in_text "$this_row" "$verb"; then
    no "the $optype table row names \`$verb\` as its tie-breaker verb"
  elif [ -z "$wiring" ]; then
    no "the e2e \`readLiveState\` $branch branch is locatable"
  elif ! in_text "$wiring" "TOOLS.$verb"; then
    no "the e2e $branch branch really resolves \`$verb\` (the $optype row claims it)"
  else
    ok "$optype tie-breaker \`$verb\` — named in ITS OWN row AND wired in the e2e $branch branch"
  fi
done <<'PAIRS'
get_transaction@`categorize`@categorize@transaction
get_category@`allocate`@allocate@allocate
get_transaction@`delete_duplicate`@delete_duplicate@transaction
get_transaction@`reconcile` (mark cleared)@reconcile-mark-cleared@reconcile
get_account@`reconcile` (reconcile account)@reconcile-account@reconcile
PAIRS

# Every row above is checked — but only the rows that HAVE a tuple. Twice now the
# table has held more rows than the loop covered, and the suite stayed green both
# times because nothing compared the two counts. So compare them: a row added to
# the doc without a tuple here fails immediately, instead of drifting unchecked
# until someone re-reads the table by hand.
table_rows="$(printf '%s\n' "$table" | grep -c '^| `')"
if [ "$table_rows" -eq "$covered" ]; then
  ok "every tie-breaker row has a cross-check ($covered of $table_rows)"
else
  no "every tie-breaker row has a cross-check — table has $table_rows, PAIRS covers $covered"
fi

# The mark-cleared row names a SECOND verb, `list_transactions`. The e2e harness
# never drives it — it reads each listed id individually — so it has no branch to
# cross-check and cannot join the loop above without breaking that loop's e2e
# invariant. Its source of truth is the write path's own readLiveState spec, so
# pin it there, scoped to the `mark_cleared` bullet that names it.
# shellcheck disable=SC2016  # a literal table cell: the backticks are markdown
                            # code fences in the document, not a command to run.
mc_row="$(row '`reconcile` (mark cleared)')"
mc_spec="$(awk '/^  - `mark_cleared`/{f=1;print;next} f&&(/^  - /||/^[^ ]/){exit} f' \
  "$REPO_ROOT/$RECONCILE_SKILL")"
if [ -z "$mc_row" ] || ! in_text "$mc_row" "list_transactions"; then
  no "the mark-cleared row names \`list_transactions\` as its second read verb"
elif [ -z "$mc_spec" ]; then
  no "the \`mark_cleared\` readLiveState spec is locatable in $RECONCILE_SKILL"
elif ! in_text "$mc_spec" "list_transactions"; then
  no "the write path's \`mark_cleared\` read really names \`list_transactions\`"
else
  ok "mark-cleared second verb \`list_transactions\` — in ITS OWN row AND in the write path's \`mark_cleared\` read"
fi

# `get_month` is the specific wrong answer for allocate (it appears on the
# allocate path, but only in the advisory dry-run preview, never as the drift
# read). Pin all three halves: it must stay OUT of the table itself, the doc must
# warn about it in prose, and the e2e wiring must not resolve it as a live read.
# The table check is what catches a regression — the prose warning is doc-only
# text that survives any table edit.
if in_text "$table" "get_month"; then
  no "\`get_month\` is kept out of the tie-breaker table"
elif ! has "$DOC" "get_month"; then
  no "doc warns off \`get_month\` for allocate"
elif has "$E2E" "TOOLS.get_month"; then
  no "e2e wiring confirms \`get_month\` is not the allocate live read"
else
  ok "\`get_month\` absent from the table, warned off in prose, unwired in e2e"
fi

# The two verbs the capability map cannot resolve must be flagged as such IN THE
# GAP CALLOUT, with the tracking issue cited — otherwise a reader silently
# substitutes a map-conformant wrong answer, which is how this defect recurred.
# Scoped to the callout: both verbs and `#247` appear elsewhere in the document,
# so a whole-document check would survive the citation being deleted from here.
cap_gap="$(awk '/^> \*\*Capability-map gap\.\*\*/{f=1} f&&!/^>/{exit} f' "$REPO_ROOT/$DOC")"
if [ -z "$cap_gap" ]; then
  no "the capability-map-gap callout is locatable in $DOC"
elif ! in_text "$cap_gap" "#247"; then
  no "the capability-map-gap callout cites issue #247"
elif ! in_text "$cap_gap" "get_account" || ! in_text "$cap_gap" "get_category"; then
  no "the capability-map-gap callout names both unresolvable verbs"
else
  ok "capability-map-gap callout names \`get_account\` + \`get_category\`, cites #247"
fi

# --- 2. the reconcile fail-closed premise, read from source ------------------
echo "  -- reconcile vacuity premise cross-checked against $SCHEMA and $RECONCILE"

# The doc argues reconcile is the ONLY op type whose before/after carry no
# `required` array, which is what makes `before: {}` schema-valid there alone.
# Read that straight out of the schema so the argument dies with the schema.
# shellcheck disable=SC2016  # JS source for node -e: `$defs` is a JSON Schema key
                            # and the backticks are a JS template literal — bash
                            # must not expand either.
req_report="$(node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const defs = s.$defs || s.definitions || {};
  const out = [];
  for (const [name, def] of Object.entries(defs)) {
    if (!name.endsWith("Op")) continue;
    for (const f of ["before", "after"]) {
      const snap = (def.properties || {})[f];
      if (!snap) continue;
      out.push(`${name}.${f}=${Array.isArray(snap.required) ? "required" : "none"}`);
    }
  }
  console.log(out.join(" "));
' "$REPO_ROOT/$SCHEMA" 2>/dev/null)"

if [ -z "$req_report" ]; then
  no "schema snapshot requirements are readable from $SCHEMA"
else
  # Expect: every reconcileOp snapshot unconstrained, every other op's constrained.
  bad=""
  for entry in $req_report; do
    name="${entry%%=*}"
    state="${entry##*=}"
    case "$name" in
      reconcileOp.*) [ "$state" = "none" ] || bad="$bad $name(expected-none)" ;;
      *)             [ "$state" = "required" ] || bad="$bad $name(expected-required)" ;;
    esac
  done
  if [ -n "$bad" ]; then
    no "reconcileOp alone has unconstrained before/after snapshots —drifted:$bad"
  else
    ok "reconcileOp alone has unconstrained before/after snapshots (doc's vacuity premise holds)"
  fi
fi

# The doc's fix is to delegate to each op type's own check rather than run one
# generic comparison. If `isReconcileStale` is renamed or deleted, the doc's
# named delegation target is stale and this must fail.
# The trailing `(` matters: matching bare `function isReconcileStale` would still
# succeed against a renamed `function isReconcileStaleX(`, since it is a prefix.
if has "$DOC" "isReconcileStale" && has "$RECONCILE" "function isReconcileStale("; then
  ok "doc delegates to \`isReconcileStale\`, and that function really exists"
else
  no "doc delegates to \`isReconcileStale\`, and that function really exists"
fi

# The delegated guard must still be the fail-closed one the doc relies on: a
# missing baseline returns stale. Pin the branch, not the comment.
if grep -q 'if (baseline === undefined) return true;' "$REPO_ROOT/$RECONCILE" 2>/dev/null; then
  ok "isReconcileStale still fails closed on a missing \`before.cleared\` baseline"
else
  no "isReconcileStale still fails closed on a missing \`before.cleared\` baseline"
fi

# `isStale`'s subset comparison is what makes `{}` vacuously non-stale. If it
# stops being a subset comparison the doc's whole trap description is obsolete.
if grep -q 'Object.keys(before).some(' "$REPO_ROOT/assets/apply-executor.js" 2>/dev/null; then
  ok "isStale is still the subset comparison that makes \`{}\` vacuously match"
else
  no "isStale is still the subset comparison that makes \`{}\` vacuously match"
fi

# --- 3. failed-live-read branch in BOTH interleavings ------------------------
# A thrown read is neither a match nor a mismatch. Both procedures must say so;
# covering only one leaves the other's literal reading dispatching on no
# information. Each interleaving section is isolated before matching, so a single
# mention elsewhere in the document cannot satisfy both.
echo "  -- failed-read branch present in both interleaving procedures"
sec_a="$(awk '/^### Interleaving A/{f=1} /^### Interleaving B/{f=0} f' "$REPO_ROOT/$DOC")"
sec_b="$(awk '/^### Interleaving B/{f=1} /^## Resume prerequisites/{f=0} f' "$REPO_ROOT/$DOC")"

for pair in "A:$sec_a" "B:$sec_b"; do
  label="${pair%%:*}"
  body="${pair#*:}"
  if [ -z "$body" ]; then
    no "interleaving $label section is locatable"
  elif printf '%s' "$body" | grep -qF "unconfirmable" \
    && printf '%s' "$body" | grep -qiE "read (itself )?fails|live read fails"; then
    ok "interleaving $label specifies the failed-live-read branch"
  else
    no "interleaving $label specifies the failed-live-read branch"
  fi
done

# --- 4. the fsync gap is real, and marked as a gap ---------------------------
# The doc keeps fsync-per-record as a REQUIREMENT and marks it not-yet-shipped
# (issue #275). Two ways that can rot: the marker outlives the fix, or the
# requirement quietly disappears. Assert against the writer itself.
echo "  -- fsync gap marker vs. $AUDIT"
audit_has_fsync=1
grep -q "fsync" "$REPO_ROOT/$AUDIT" 2>/dev/null || audit_has_fsync=0

if [ "$audit_has_fsync" -eq 0 ]; then
  if has "$DOC" "not yet implemented" && has "$DOC" "#275"; then
    ok "fsync absent from $AUDIT, and the doc marks it a tracked gap (#275)"
  else
    no "fsync absent from $AUDIT, and the doc marks it a tracked gap (#275)"
  fi
else
  if has "$DOC" "not yet implemented"; then
    no "$AUDIT now fsyncs — the doc's not-yet-implemented marker is stale (see #275)"
  else
    ok "$AUDIT fsyncs and the doc no longer calls it a gap"
  fi
fi

# The atomic-append guarantee the doc leans on for resume correctness must still
# be a single append in the writer.
# shellcheck disable=SC2016  # a literal needle: `$file` is the variable name as it
                            # appears in audit-log.sh's source, not one to expand.
if grep -q 'printf .*>> "\$file"' "$REPO_ROOT/$AUDIT" 2>/dev/null; then
  ok "audit writer still emits each record in one append (doc's atomicity claim)"
else
  no "audit writer still emits each record in one append (doc's atomicity claim)"
fi

# --- summary -----------------------------------------------------------------
echo
echo "write-back-idempotency-doc.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
