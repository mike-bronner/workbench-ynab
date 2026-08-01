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
#      author deferring to the map lands on a wrong-but-map-conformant name. Each
#      row is checked against the wiring `assets/test/e2e-write-back.test.js`
#      actually drives through the real executor.
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
AUDIT="bin/audit-log.sh"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
no() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# has <file> <literal> — literal (non-regex) match anywhere in the file.
has() { grep -qF -- "$2" "$REPO_ROOT/$1" 2>/dev/null; }

# assert_in <file> <desc> <literal>
assert_in() {
  if has "$1" "$3"; then ok "$2"; else no "$2"; fi
}

echo "write-back-idempotency-doc.test.sh — doc claims vs. the code they describe"

# --- 0. the document exists (AC #1) ------------------------------------------
if [ -f "$REPO_ROOT/$DOC" ]; then
  ok "$DOC exists"
else
  no "$DOC exists"
  echo "FATAL: design document missing — remaining assertions would be vacuous."
  exit 1
fi

# --- 1. tie-breaker verbs: doc row  <->  real e2e wiring ---------------------
# Each pair is (verb, op type it serves). The verb must appear BOTH in the doc's
# table AND in the wiring the e2e harness drives through the real applyChangeset.
# Checking only the doc would pass on a fabricated name; checking only the code
# would pass while the doc named something else entirely.
echo "  -- live-read verbs cross-checked against $E2E"
for pair in "get_transaction:categorize" "get_category:allocate" "get_account:reconcile"; do
  verb="${pair%%:*}"
  optype="${pair##*:}"
  if ! has "$DOC" "$verb"; then
    no "doc names \`$verb\` as the $optype tie-breaker verb"
  elif ! has "$E2E" "TOOLS.$verb"; then
    no "e2e wiring really resolves \`$verb\` (doc claims it for $optype)"
  else
    ok "$optype tie-breaker \`$verb\` — named in doc AND wired in e2e"
  fi
done

# The two verbs above that the capability map cannot resolve must be flagged as
# such, with the tracking issue cited — otherwise a reader silently substitutes a
# map-conformant wrong answer, which is how this defect recurred.
assert_in "$DOC" "capability-map gap cites issue #247" "#247"

# `get_month` is the specific wrong answer for allocate (it appears on the
# allocate path, but only in the advisory dry-run preview, never as the drift
# read). Pin both halves: the doc must warn about it, and the e2e wiring must NOT
# use it as the allocate live read.
if has "$DOC" "get_month" && ! has "$E2E" "TOOLS.get_month"; then
  ok "doc warns off \`get_month\` for allocate, and e2e confirms it is not wired there"
else
  no "doc warns off \`get_month\` for allocate, and e2e confirms it is not wired there"
fi

# --- 2. the reconcile fail-closed premise, read from source ------------------
echo "  -- reconcile vacuity premise cross-checked against $SCHEMA and $RECONCILE"

# The doc argues reconcile is the ONLY op type whose before/after carry no
# `required` array, which is what makes `before: {}` schema-valid there alone.
# Read that straight out of the schema so the argument dies with the schema.
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
if grep -q 'printf .*>> "\$file"' "$REPO_ROOT/$AUDIT" 2>/dev/null; then
  ok "audit writer still emits each record in one append (doc's atomicity claim)"
else
  no "audit writer still emits each record in one append (doc's atomicity claim)"
fi

# --- summary -----------------------------------------------------------------
echo
echo "write-back-idempotency-doc.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
