#!/usr/bin/env bash
#
# tests/unit/write-safety-guardrail-doc.test.sh — the guardrail skill doc's verb
# bullets are pinned to the authoritative inventory (issue #257).
#
# skills/write-safety-guardrail.md is the human-readable contract for the money
# gate. Its §2 and §3 restate ALLOWED_TOOLS and DENIED_TOOLS from
# assets/write-safety-guardrail.js bullet for bullet, and nothing used to prove
# the two agree — no test read this file's verb content at all. A verb added to
# the inventory would leave the doc silently short, on the one surface a human
# consults to learn what may run against their money.
#
# Issue #257 offered two ways out: pin the doc, or mark it non-normative. Pinning
# is the one taken. The doc is on bin/check-tool-name-sources.sh's allowlist
# precisely because it must enumerate the exact verbs it gates, so "derived,
# read the .js instead" would strip a reader of the thing the allowlist entry
# exists to give them.
#
# Two assertions, in both directions per section:
#
#   1. §2's bullets are exactly ALLOWED_TOOLS.
#   2. §3's bullets are exactly DENIED_TOOLS.
#
# NOTE ON SCOPE. Bullets are read from each section's BODY — the heading line is
# dropped before matching, and the section ends at the next heading AT OR ABOVE
# its own level. Both headings name their constant (`(ALLOWED_TOOLS)`), and the
# doc repeats several verbs in surrounding prose, so a whole-file or
# heading-inclusive match would stay green on exactly the regression this file
# exists to catch.
#
# The "at or above its own level" part is load-bearing, not pedantry: closing a
# `### ` section only at the next `### ` ignores the stronger break, so §3 would
# run on through four intervening `## ` sections. Test 3 pins the boundary in
# both directions.
#
# This file never holds a concrete tool name: the bare prefix comes from
# tests/lib/mutating-inventory.sh (which the guard never matches) and the verb
# suffixes are read at runtime out of the allowlisted inventory. That keeps it
# clean under bin/check-tool-name-sources.sh.
#
# Follows the repo harness convention (tests/lib/assert.sh): raw bash with
# `set -euo pipefail`, `test_*` functions, `run_tests`. Auto-discovered by
# scripts/test.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/mutating-inventory.sh"

DOC="$REPO_ROOT/skills/write-safety-guardrail.md"
INVENTORY="$REPO_ROOT/assets/write-safety-guardrail.js"
BT='`'   # a literal backtick, kept out of command position

ALLOW_HEADING='### 2. Namespaced tool allow-list'
DENY_HEADING='### 3. Money-movement deny-list'

# doc_section_verbs <heading-prefix> [doc] — the bare verb suffixes bulleted in
# the section whose heading starts with <heading-prefix>, sorted. Reads $DOC
# unless a doc path is given; test 3 points it at a mutated copy.
#
# The heading line itself is dropped (`next`), so the constant name in the
# heading can never satisfy a check meant to read the body.
#
# A section closes at the next heading whose level is AT OR ABOVE the wanted
# heading's own (`#`-count taken from <heading-prefix>, so the two can never
# drift apart). Closing only at the next `### ` would let a shallower `## `
# heading pass straight through: §3's next `### ` is four `## ` sections later,
# so every one of them read as part of §3's body. Deeper headings are real
# sub-sections and stay inside. A <heading-prefix> with no leading `#` yields no
# depth, matches no heading, and returns nothing — which the empty-set guard in
# assert_section_matches_block turns into a failure rather than agreement.
doc_section_verbs() {
  awk -v want="$1" '
    BEGIN  { match(want, /^#+/); depth = RLENGTH }
    /^#+ / { match($0, /^#+/)
             if (RLENGTH <= depth) { f = (index($0, want) == 1); next } }
    f      { print }
  ' "${2:-$DOC}" \
    | grep -oE -- "- \`$YNAB_TOOL_PREFIX""ynab_[a-z_]+\`" \
    | sed -e "s/^- \`$YNAB_TOOL_PREFIX//" -e 's/`$//' \
    | sort -u
}

# diff_sets <a> <b> — lines present in <a> but not in <b>.
diff_sets() {
  comm -23 <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}

# assert_section_matches_block <heading-prefix> <ALLOWED|DENIED> — the section's
# bullets and the inventory block name exactly the same verbs. FAILS CLOSED on
# either side parsing empty: a renamed constant or a restructured section must
# not compare two empty sets and report agreement.
assert_section_matches_block() {
  local heading="$1" block="$2" doc_set inv_set only_doc only_inv
  doc_set="$(doc_section_verbs "$heading")"
  inv_set="$(mutating_inventory_verbs "$INVENTORY" "$block")" \
    || fail "${block}_TOOLS could not be read from the inventory — refusing to certify the doc against it"

  [ -n "$doc_set" ] || fail "no verb bullets parsed from the doc section '$heading' — extraction is broken or the section is gone"

  only_doc="$(diff_sets "$doc_set" "$inv_set")"
  only_inv="$(diff_sets "$inv_set" "$doc_set")"

  [ -z "$only_doc" ] || fail "bulleted under '$heading' but not in ${block}_TOOLS: $(echo "$only_doc" | tr '\n' ' ')"
  [ -z "$only_inv" ] || fail "in ${block}_TOOLS but not bulleted under '$heading': $(echo "$only_inv" | tr '\n' ' ')"
}

# --- 1. the allow-list section mirrors ALLOWED_TOOLS --------------------------
test_allow_list_section_matches_inventory() {
  assert_section_matches_block "$ALLOW_HEADING" ALLOWED
}

# --- 2. the deny-list section mirrors DENIED_TOOLS ----------------------------
test_deny_list_section_matches_inventory() {
  assert_section_matches_block "$DENY_HEADING" DENIED
}

# plant_bullet <doc> <heading-prefix> <bullet> — <doc> with <bullet> inserted
# just below the first `## ` heading that FOLLOWS <heading-prefix>'s section.
# That lands OUTSIDE the section by heading level but INSIDE the range a
# `### `-only terminator would sweep, which is precisely the gap under test.
plant_bullet() {
  awk -v want="$2" -v bullet="$3" '
    { print }
    index($0, want) == 1     { seen = 1; next }
    seen && /^## / && !done  { print ""; print bullet; done = 1 }
  ' "$1"
}

# --- 3. the section boundary respects heading level ---------------------------
# doc_section_verbs used to close a section only at the next `### `, so a `## `
# heading did not end it and §3 swept four unrelated `## ` sections into its
# body. Mutation-shaped, on scratch copies — the real doc is never written to.
# Both directions matter, and only the second is a safety failure:
#
#   (a) false positive — a tool-shaped bullet planted past the section's real
#       content is misattributed to it.
#   (b) false negative — a verb DELETED from the section's own bullets still
#       reads as present, because the same name occurs in the swept range. That
#       is the drift-masking case this whole file exists to prevent: the doc
#       stops naming a denied verb and the pin stays green.
#
# The scratch dir is file-scoped under an EXIT trap, matching
# tests/unit/docs-set.test.sh's drift cases. A RETURN trap would not do: `fail`
# returns non-zero, `set -e` unwinds the function, and the trap never runs —
# every red run would leave a temp dir behind.
BOUNDARY_DIR="$(mktemp -d)"
trap 'rm -rf "$BOUNDARY_DIR"' EXIT

test_section_ends_at_a_shallower_heading() {
  local denied victim decoy expected got
  denied="$(mutating_inventory_verbs "$INVENTORY" DENIED)" \
    || fail "DENIED_TOOLS could not be read from the inventory"

  # The decoy is an ALLOWED verb, so §3 can only ever report it via the sweep.
  decoy="$(mutating_inventory_verbs "$INVENTORY" ALLOWED | head -1)" \
    || fail "ALLOWED_TOOLS could not be read from the inventory"
  victim="$(printf '%s\n' "$denied" | head -1)"

  # Positive control first: an untouched copy still reports exactly DENIED, so a
  # failure below is the mutation and not a broken copy.
  got="$(doc_section_verbs "$DENY_HEADING" "$DOC")"
  [ "$got" = "$denied" ] || fail "the unmutated doc no longer reports DENIED_TOOLS for '$DENY_HEADING'"

  # (a) a bullet planted beyond the section must not be attributed to it.
  plant_bullet "$DOC" "$DENY_HEADING" "- ${BT}${YNAB_TOOL_PREFIX}${decoy}${BT}" > "$BOUNDARY_DIR/decoy.md"
  # The plant must actually have landed. If the doc ever restructures so that no
  # `## ` follows §3, plant_bullet is a no-op and this case would pass by
  # comparing the doc against itself — a green that checked nothing.
  cmp -s "$DOC" "$BOUNDARY_DIR/decoy.md" \
    && fail "plant_bullet changed nothing — no '## ' heading follows '$DENY_HEADING', so this case would prove nothing"
  got="$(doc_section_verbs "$DENY_HEADING" "$BOUNDARY_DIR/decoy.md")"
  [ "$got" = "$denied" ] \
    || fail "a bullet planted in a later '## ' section leaked into '$DENY_HEADING': $(echo "$got" | tr '\n' ' ')"

  # (b) deleting the verb's own bullet must go red even when the same verb is
  # bulleted further down, inside the range the old terminator swept.
  grep -vF -- "- ${BT}${YNAB_TOOL_PREFIX}${victim}${BT}" "$DOC" > "$BOUNDARY_DIR/base.md"
  plant_bullet "$BOUNDARY_DIR/base.md" "$DENY_HEADING" "- ${BT}${YNAB_TOOL_PREFIX}${victim}${BT}" > "$BOUNDARY_DIR/masked.md"
  expected="$(printf '%s\n' "$denied" | grep -vxF -- "$victim")"
  # A one-verb DENIED_TOOLS would make `expected` empty, and the extractor
  # returning nothing at all would then read as agreement. Fail closed instead.
  [ -n "$expected" ] \
    || fail "DENIED_TOOLS holds only '$victim' — removing it leaves an empty expectation that would certify anything"
  got="$(doc_section_verbs "$DENY_HEADING" "$BOUNDARY_DIR/masked.md")"
  [ "$got" = "$expected" ] \
    || fail "'$victim' was deleted from '$DENY_HEADING' and the extractor still reported it — a later section masked the drift"
}

echo "write-safety-guardrail-doc.test.sh — the guardrail skill doc mirrors the inventory"
run_tests
