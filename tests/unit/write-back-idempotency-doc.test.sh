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
#      type. The wrong verb has been written into this table twice (once
#      `list_accounts` for reconcile, once `get_month` for allocate) because the
#      capability map was missing `get_account`/`get_category` (issue #247), so an
#      author deferring to the map landed on a wrong-but-map-conformant name.
#      #247 added both verbs to the map and to the SSoT; the callout check below
#      now reads those two files to confirm the gap is really closed, rather than
#      taking the document's word for it.
#      EVERY row is checked against the wiring
#      `assets/test/e2e-write-back.test.js` actually drives through the real
#      executor, and the row count is itself asserted — a row added to the table
#      without a matching tuple below fails the suite rather than drifting
#      unchecked, which is how two rows went uncovered before.
#
# Assertions about the document are scoped to the row, bullet or callout they
# name, never a whole-file grep. Every verb in the tie-breaker table is also
# discussed in the prose below it, so an unscoped search stays green through a
# straight cell swap — the very drift class 1 exists to catch. The e2e side is
# scoped the same way, to the one `readLiveState` branch that serves the row:
# `get_transaction` is wired twice in that function alone, so a whole-file match
# cannot tell the two apart.
#
# Scoping also means EXCLUDING THE HEADING when a section is extracted. A heading
# that restates its own section's topic word ("…live YNAB unconfirmable") hands
# that word to any assertion searching the section, which then passes even when
# the body says the opposite. Where an assertion pins a specific outcome, it is
# scoped to that bullet, not to the section containing it.
#   2. Fail-closed premises. The document's reconcile vacuity argument rests on
#      `reconcileOp.before`/`.after` having no `required` array in the schema, and
#      on `isReconcileStale` existing to delegate to. Both are read from source.
#      Delegation is checked PER SUB-ACTION, not per op type: `isReconcileStale`
#      must guard `mark_cleared` AND `reconcile_account`, so a doc claiming
#      "production solved this" for `reconcile` as a whole is only true while both
#      branches really carry a guard. #282 shipped the second one, and the doc's
#      claim is pinned to that shipped branch in both directions, like the fsync
#      marker in class 3: guard gone → the doc must go back to flagging the gap;
#      guard present → the doc must not still call it not-yet-wired.
#   3. The fsync gap — CLOSED by #275, and pinned in both directions. The document
#      used to mark fsync-per-record a requirement that was not implemented; the
#      marker had to come down when the code landed, so the test asserts the state
#      matches the code: if `bin/audit-log.sh` gains an fsync and the doc still
#      calls it missing, this fails — and if the fsync is ever REMOVED while the
#      doc still states the guarantee, this fails too.
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

# The callout that used to flag `get_account` / `get_category` as unresolvable
# now claims the opposite: #247 closed the gap and every verb in the table
# resolves in the map. That is a claim about OTHER FILES, so read those files —
# a callout asserting its own correctness proves nothing.
#
# Scoped to the callout: both verbs and `#247` appear elsewhere in this document,
# so a whole-document check would survive the claim being deleted from here.
#
# The SSoT side is scoped to the tool-name LIST BLOCKS, not the whole file. Both
# files discuss both verbs in prose right beside their lists, so an unscoped grep
# would stay green if the name were dropped from the list itself — the exact
# regression this pins. `MAP_TABLE` is the capability table (rows starting `| <n> |`);
# `SSOT_LIST` is every prefixed name in the read/write fenced blocks of the SSoT.
# The namespaced names are composed at runtime from the bare prefix + suffix, so
# this file never holds a full concrete name and stays clean under
# bin/check-tool-name-sources.sh.
MAP="docs/mcp-capability-map.md"
SSOT="skills/protocol/ynab-tools.md"
NS_PREFIX="mcp__plugin_workbench-ynab_ynab__"

map_table="$(awk '/^\| # \| Logical operation \|/{f=1} f&&/^$/{exit} f' "$REPO_ROOT/$MAP")"
ssot_list="$(grep "^$NS_PREFIX" "$REPO_ROOT/$SSOT" || true)"

cap_gap="$(awk '/^> \*\*Capability-map gap/{f=1} f&&!/^>/{exit} f' "$REPO_ROOT/$DOC")"
gap_verbs_resolved=1
for verb in get_account get_category; do
  in_text "$map_table" "$NS_PREFIX""ynab_$verb" || gap_verbs_resolved=0
  in_text "$ssot_list" "$NS_PREFIX""ynab_$verb" || gap_verbs_resolved=0
done

if [ -z "$cap_gap" ]; then
  no "the capability-map-gap callout is locatable in $DOC"
elif ! in_text "$cap_gap" "#247"; then
  no "the capability-map-gap callout cites issue #247"
elif ! in_text "$cap_gap" "get_account" || ! in_text "$cap_gap" "get_category"; then
  no "the capability-map-gap callout names both once-unresolvable verbs"
elif [ "$gap_verbs_resolved" -ne 1 ]; then
  no "the callout claims the gap is closed, but \`get_account\`/\`get_category\` are missing from $MAP or $SSOT"
else
  ok "capability-map-gap closed — \`get_account\` + \`get_category\` are in BOTH $MAP and $SSOT, callout cites #247"
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

# The sibling guard, `reconcile_account`'s. The doc once claimed "production
# already solved this" for the `reconcile` op type as a whole while only
# `mark_cleared` was guarded, which would have sent an implementer to a guard half
# the op type never had. #282 shipped the second guard, and the doc's claim moved
# from "not yet wired" to "guarded". Pin the CLAIM to the SHIPPED LINE in both
# directions — the same marker-rot check section 4 runs for fsync:
#   guard absent  → the doc must go back to flagging the gap and citing #282
#   guard present → the doc must quote this exact guard line, and must NOT still
#                   call it not-yet-wired
# Quoting the line (not merely "the body is no longer the bare delegation") is
# what ties the marker's removal to the real code: any edit to the guard — a
# rename, a reformat, a deletion — fails here. A weaker "body differs from the old
# bare-delegation string" check would stay green on the first two (the body still
# differs, so the rot goes unseen); only the third trips it, because deleting the
# guard restores that exact string. Quoting the line is what covers the other two.
RA_GUARD='if (!hasComparableBaseline(op.before)) return true;'
recon_fn="$(awk '/^function isReconcileStale\(/{f=1} f{print} f&&/^}/{exit}' \
  "$REPO_ROOT/$RECONCILE")"
ra_branch="$(printf '%s\n' "$recon_fn" \
  | awk '/RECONCILE_ACCOUNT/{f=1} f{print} f&&/^  }/{exit}')"
# The branch's executable body: drop the `if (…) {` line, the closing brace,
# comment lines, and surrounding whitespace. Bare delegation === no baseline guard.
ra_body="$(printf '%s\n' "$ra_branch" \
  | sed -e '1d' -e '$d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
  | grep -v '^$' | grep -v '^//')"

# Scoped to the doc's own `reconcile_account` bullet, never the whole file: the
# phrase "Designed, not yet wired" is also used for the GAP-10 freshness gate, so
# a whole-document grep would stay green with this bullet's marker deleted. The
# cut stops at a blank line as well as at the next bullet/heading, so the prose
# paragraph under the list cannot lend the bullet vocabulary it does not have.
ra_doc="$(awk '
  substr($0, 1, 2) == "- " && index($0, "reconcile_account") { f = 1; print; next }
  f && (substr($0, 1, 2) == "- " || substr($0, 1, 1) == "#" || $0 == "") { exit }
  f { print }
' "$REPO_ROOT/$DOC" | tr '\n' ' ' | tr -s ' ')"

if [ -z "$recon_fn" ] || [ -z "$ra_branch" ]; then
  no "isReconcileStale's \`reconcile_account\` branch is locatable in $RECONCILE"
elif [ -z "$ra_doc" ]; then
  no "the doc has a \`reconcile_account\` bullet stating its guard status"
elif [ "$ra_body" = "return isStale(op.before, live);" ]; then
  if in_text "$ra_doc" "#282" && in_text "$ra_doc" "not yet wired"; then
    ok "\`reconcile_account\` still delegates bare to isStale — doc flags that gap, cites #282"
  else
    no "\`reconcile_account\` still delegates bare to isStale — doc must flag it and cite #282"
  fi
elif ! in_text "$ra_branch" "$RA_GUARD"; then
  no "\`reconcile_account\`'s branch carries neither the bare delegation nor the #282 guard — the doc's claim describes code that no longer exists"
elif ! grep -q 'function hasComparableBaseline(' "$REPO_ROOT/$RECONCILE" 2>/dev/null; then
  no "the \`reconcile_account\` guard calls hasComparableBaseline, and that function really exists in $RECONCILE"
elif in_text "$ra_doc" "not yet wired"; then
  no "\`reconcile_account\` is guarded now — the doc's not-yet-wired marker is stale (see #282)"
elif in_text "$ra_doc" "$RA_GUARD" && in_text "$ra_doc" "#282"; then
  ok "\`reconcile_account\` fails closed on a baseline-free \`before\`, and the doc quotes that exact guard and cites #282"
else
  no "\`reconcile_account\` fails closed on a baseline-free \`before\` — the doc's bullet must quote that guard line and cite #282"
fi

# Both sub-actions are guarded, so the doc's delegation rule is now unconditional
# for the `live == before` half. The old "everywhere except reconcile_account"
# carve-out must be gone; if it comes back while the guard is shipped, the two
# have drifted. Scoped to the paragraph that states the rule.
rule_para="$(awk '/^So "delegate to the op type/{f=1} f{print} f&&/^$/{exit}' \
  "$REPO_ROOT/$DOC" | tr '\n' ' ' | tr -s ' ')"
if [ -z "$rule_para" ]; then
  no "the doc states the \"delegate to the op type's own check\" rule"
elif in_text "$rule_para" "everywhere except"; then
  no "the delegation rule still carves out a sub-action while both are guarded (see #282)"
else
  ok "the delegation rule no longer carves out \`reconcile_account\`"
fi

# The doc says delegation answers "is it stale?", NOT "is it already applied",
# because `isReconcileStale` never reads `after`. That is the reason resume has to
# compute the `live == after` branch itself. If the function grows an `after`
# read, the doc's division of labour is wrong and must be rewritten.
if [ -n "$recon_fn" ] && ! in_text "$recon_fn" "op.after"; then
  ok "isReconcileStale reads only \`before\` — ALREADY-APPLIED genuinely has no delegate"
else
  no "isReconcileStale reads only \`before\` — ALREADY-APPLIED genuinely has no delegate"
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
# information.
#
# Scoped to the BULLET, never the section. Interleaving A's own heading reads
# `### Interleaving A — audit says "applied", live YNAB unconfirmable`, so a
# section-scoped check that swallows the heading is handed "unconfirmable" for
# free: the bullet's OUTCOME could be rewritten to the blind dispatch this whole
# document argues against and the check would stay green. B's heading happens not
# to carry the word, but that is luck rather than design, so both sides get the
# same bullet scoping. The assertions pin the outcome itself — the verdict word,
# the do-nothing instruction, and the explicit refusal to dispatch — because the
# verdict word alone is what the heading can forge.
echo "  -- failed-read branch present in both interleaving procedures"

# doc_between <start> <end> — the lines BETWEEN two heading regexes, the start
# heading EXCLUDED: `f` is set only after the print test, so the matched start
# line never prints and cannot lend its wording to an assertion below.
doc_between() {
  awk -v s="$1" -v e="$2" '$0 ~ e {f=0} f {print} $0 ~ s {f=1}' "$REPO_ROOT/$DOC"
}

# failed_read_bullet <section-text> — the one top-level list item about a failing
# live read, from its first line to the line before the next bullet or heading,
# flattened to a single line so an assertion is not defeated by where the
# document happens to wrap. Matched with string ops rather than a regex so no
# backslash has to survive `awk -v`.
failed_read_bullet() {
  printf '%s\n' "$1" | awk '
    substr($0, 1, 2) == "- " && index($0, "the live read") && index($0, "fails") {
      f = 1; print; next
    }
    f && (substr($0, 1, 2) == "- " || substr($0, 1, 1) == "#") { exit }
    f { print }
  ' | tr '\n' ' ' | tr -s ' '
}

sec_a="$(doc_between '^### Interleaving A' '^### Interleaving B')"
sec_b="$(doc_between '^### Interleaving B' '^## Resume prerequisites')"

for label in A B; do
  case "$label" in
    A) body="$sec_a" ;;
    B) body="$sec_b" ;;
  esac
  fr="$(failed_read_bullet "$body")"
  if [ -z "$body" ]; then
    no "interleaving $label section is locatable"
  elif [ -z "$fr" ]; then
    no "interleaving $label has a failed-live-read bullet"
  elif ! in_text "$fr" "unconfirmable"; then
    no "interleaving $label's failed-read bullet calls the outcome unconfirmable"
  elif ! in_text "$fr" "Do nothing to this op"; then
    no "interleaving $label's failed-read bullet says to do nothing to the op"
  elif ! printf '%s\n' "$fr" | grep -qE 'neither .* nor dispatch'; then
    no "interleaving $label's failed-read bullet refuses to dispatch outright"
  else
    ok "interleaving $label failed-read bullet — unconfirmable, do nothing, never dispatch"
  fi
done

# --- 4. the fsync guarantee is real, and stated as one ------------------------
# The doc keeps fsync-per-record as a REQUIREMENT; #275 shipped it and removed the
# not-yet-implemented marker. Two ways that can rot: the marker outlives the fix,
# or the code loses the fsync while the doc still promises it. Assert against the
# writer itself.
#
# The needle is the CALL, not the word. A whole-file `grep -q fsync` would now be
# satisfied by this writer's own prose — it explains fsync at length in comments —
# so deleting the actual syscall would leave the check green. Pin the executable
# line instead.
echo "  -- fsync guarantee vs. $AUDIT"
audit_has_fsync=1
grep -q '^    os\.fsync(fd)$' "$REPO_ROOT/$AUDIT" 2>/dev/null || audit_has_fsync=0

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
# be a single append in the writer. #275 moved the mechanism from a shell `>>`
# redirect to the python3 fsync shim, so the needle now pins the shim's two
# defining calls: an O_APPEND open, and ONE os.write of the whole record. A
# multi-write loop or a non-append open would break the doc's claim and fail here.
# This is a doc↔code consistency guard, so it inspects source by design; the
# BEHAVIOURAL proof that records never split lives in tests/unit/audit-log.test.sh
# (8 concurrent 100 KB appends, none torn).
if grep -q 'os\.O_APPEND' "$REPO_ROOT/$AUDIT" 2>/dev/null \
   && grep -q '^    n = os\.write(fd, data)$' "$REPO_ROOT/$AUDIT" 2>/dev/null; then
  ok "audit writer still emits each record in one append (doc's atomicity claim)"
else
  no "audit writer still emits each record in one append (doc's atomicity claim)"
fi

# --- summary -----------------------------------------------------------------
echo
echo "write-back-idempotency-doc.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
