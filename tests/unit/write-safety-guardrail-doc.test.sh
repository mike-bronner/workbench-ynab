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
# dropped before matching, and the section ends at the next `### `. Both headings
# name their constant (`(ALLOWED_TOOLS)`), and the doc repeats several verbs in
# surrounding prose, so a whole-file or heading-inclusive match would stay green
# on exactly the regression this file exists to catch.
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

# doc_section_verbs <heading-prefix> — the bare verb suffixes bulleted in the
# `### ` section whose heading starts with <heading-prefix>, sorted. The heading
# line itself is dropped (`next`), so the constant name in the heading can never
# satisfy a check meant to read the body.
doc_section_verbs() {
  awk -v want="$1" '
    index($0, "### ") == 1 { f = (index($0, want) == 1); next }
    f                      { print }
  ' "$DOC" \
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
  assert_section_matches_block '### 2. Namespaced tool allow-list' ALLOWED
}

# --- 2. the deny-list section mirrors DENIED_TOOLS ----------------------------
test_deny_list_section_matches_inventory() {
  assert_section_matches_block '### 3. Money-movement deny-list' DENIED
}

echo "write-safety-guardrail-doc.test.sh — the guardrail skill doc mirrors the inventory"
run_tests
