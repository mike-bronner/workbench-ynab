#!/usr/bin/env bash
#
# tests/unit/tool-name-ssot-coverage.test.sh — the tool-name SSoT is COMPLETE
# (issue #247).
#
# bin/check-tool-name-sources.sh answers one direction: has a concrete tool name
# leaked OUT of the allowlist? It cannot answer the other: is a real tool MISSING
# from the two source-of-truth files? That second gap is the one #247 was opened
# for, and it caused two live defects — an author needing an account read found
# only `list_accounts` in the map and wrote that; an author needing a category
# read found only `get_month` and wrote that. Both were the repo-conformant
# choice given what the SSoT said, which is why the map's completeness is
# load-bearing rather than cosmetic.
#
# Six assertions, each reading the vendored bundle, the SSoT files, or the
# mutating-tool inventory as ground truth — never a document's claim about
# itself:
#
#   1. The two SSoT files agree, as SETS. docs/mcp-capability-map.md's capability
#      table and skills/protocol/ynab-tools.md's read + write lists must name
#      exactly the same tools. Adding a verb to one and forgetting the other is
#      the cheapest way to reopen #247 halfway.
#   2. Every adopted name is REAL. Each name in the SSoT must be a tool id the
#      vendored bundle actually registers, so a typo or a stale suffix left
#      behind by a re-vendor fails here instead of at call time.
#   3. Adopted + not-adopted PARTITIONS the registered set exactly. The map's
#      "Registered but not adopted" inventory carries every tool the rituals do
#      not use, with a reason. A bundle that registers a new tool therefore fails
#      this suite until someone classifies it — adopt it (both files) or record
#      why not. That is the mechanical guard against #247 reopening.
#   4. The map's allowlist table matches the guard's own ALLOWLIST array. The
#      table drifted once already (it listed six of the guard's seven files), and
#      it is the table a reader consults to learn where a name may live.
#   5. The two verbs #247 was opened for are actually adopted, by name — 1–3 are
#      structural and would stay green on a tree where neither had been added.
#   6. Every verb in the mutating-tool inventory is a tool the bundle really
#      registers (#257). Combined with 3, that makes the inventory's verbs
#      transitively complete in the capability map too: inventory ⊆ registered,
#      and registered = adopted ∪ not-adopted.
#
# NOTE ON SCOPE. Sets are extracted from the specific blocks that hold them — the
# capability table's numbered rows, the SSoT's fenced name lists, the inventory
# table's rows — never a whole-file grep. Both files mention most of these names
# in prose as well, so an unscoped match would stay green when a name is dropped
# from the list itself, which is the exact regression this file exists to catch.
#
# This file never holds a full concrete tool name: the bare prefix (which the
# guard never matches) and the operation suffixes are separate literals, composed
# only at runtime. That keeps it clean under bin/check-tool-name-sources.sh.
#
# Follows the repo harness convention (tests/lib/assert.sh): raw bash with
# `set -euo pipefail`, `test_*` functions, `run_tests`. Auto-discovered by
# scripts/test.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"

MAP="$REPO_ROOT/docs/mcp-capability-map.md"
SSOT="$REPO_ROOT/skills/protocol/ynab-tools.md"
GUARD="$REPO_ROOT/bin/check-tool-name-sources.sh"
BUNDLE="$REPO_ROOT/vendor/ynab-mcp/index.cjs"
INVENTORY="$REPO_ROOT/assets/write-safety-guardrail.js"   # the authoritative mutating-tool inventory
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/mutating-inventory.sh"

# The correct plugin-namespaced prefix, from the shared lib and kept on its own
# so no composed full name below ever appears as a single token in this file.
PREFIX="$YNAB_TOOL_PREFIX"

# --- ground truth: what the vendored bundle registers ------------------------
# The bundle is minified, so tool ids are read from the registration property
# (`name:"ynab_<op>"`) rather than any loose `ynab_[a-z_]+` match — the loose
# form also hits minifier identifiers and prose inside the bundle (e.g.
# `ynab_higher`), which would inflate the registered set with names that are not
# tools and make assertion 3 fail for the wrong reason.
registered_tools() {
  grep -oE 'name:"ynab_[a-z_]+"' "$BUNDLE" \
    | sed -e 's/^name:"//' -e 's/"$//' \
    | sort -u
}

# --- the capability table: the adopted set, per the human-readable contract ---
# Rows of the numbered capability table only: `| <n> | <logical> | <concrete> |`.
# The inventory table below it has no leading number, so it is never picked up
# here — the two sets must stay distinct for assertion 3 to mean anything.
map_adopted() {
  awk '/^\| # \| Logical operation \|/{f=1;next} f&&/^$/{exit} f&&/^\| [0-9]+ \|/' "$MAP" \
    | grep -oE "$PREFIX""ynab_[a-z_]+" \
    | sed "s/^$PREFIX//" \
    | sort -u
}

# --- the SSoT lists: the adopted set, per the machine-referenced file ---------
# Only the fenced read and write tool lists — a name is a whole line there. The
# pre-approval and family-glob sections repeat several names, so those sections
# are deliberately excluded; a name that lives ONLY in a pre-approval block is
# not an adopted tool.
ssot_adopted() {
  awk -v p="^## (Read|Write) tools" '
    $0 ~ p     { f = 1; next }
    /^## /     { f = 0 }
    f          { print }
  ' "$SSOT" \
    | grep -xE "$PREFIX""ynab_[a-z_]+" \
    | sed "s/^$PREFIX//" \
    | sort -u
}

# --- the inventory: registered tools the rituals deliberately do not use ------
# Rows of the "Registered but not adopted" table: `| \`ynab_<op>\` | <reason> |`.
# Bare suffixes by design — the inventory is a classification, not a second place
# a namespaced name lives.
map_not_adopted() {
  # shellcheck disable=SC2016  # the backticks are markdown code fences in the
                              # table cell being matched, not command substitution.
  awk '/^## Registered but not adopted/{f=1;next} /^## /{f=0} f&&/^\| `ynab_/' "$MAP" \
    | sed -E 's/^\| `(ynab_[a-z_]+)` \|.*/\1/' \
    | sort -u
}

# --- the guard's own allowlist, and the table that documents it ---------------
# The ALLOWLIST array entries are quoted repo-relative paths; the trailing
# comments after them are not part of the path.
guard_allowlist() {
  awk '/^ALLOWLIST=\(/{f=1;next} f&&/^\)/{exit} f' "$GUARD" \
    | sed -E 's/^[[:space:]]*"([^"]+)".*/\1/' \
    | grep -v '^[[:space:]]*$' \
    | sort -u
}

# The allowlist table in the map's "Single source of truth" section: markdown
# link rows whose first cell names a repo path. Paths appear either as a link
# target (`[`x`](../x)`) or as bare code (`` `docs/...` `` for the map itself),
# so take the first backticked cell and normalise it.
map_allowlist() {
  # shellcheck disable=SC2016  # the backticks are markdown code fences in the
                              # table cell being matched, not command substitution.
  awk '/^\| Permitted file \| Role \|/{f=1;next} f&&/^$/{exit} f&&/^\| /' "$MAP" \
    | sed -E 's/^\| \[?`([^`]+)`.*/\1/' \
    | grep -v '^|' \
    | sort -u
}

# diff_sets <a> <b> — lines present in <a> but not in <b>.
diff_sets() {
  comm -23 <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}

# --- 1. the two SSoT files name exactly the same tools -----------------------
test_ssot_files_agree_as_sets() {
  local map_set ssot_set only_map only_ssot
  map_set="$(map_adopted)"
  ssot_set="$(ssot_adopted)"

  [ -n "$map_set" ] || fail "no adopted tools parsed from the capability table — extraction is broken"
  [ -n "$ssot_set" ] || fail "no adopted tools parsed from the SSoT lists — extraction is broken"

  only_map="$(diff_sets "$map_set" "$ssot_set")"
  only_ssot="$(diff_sets "$ssot_set" "$map_set")"

  [ -z "$only_map" ] || fail "in the capability map but missing from the SSoT lists: $(echo "$only_map" | tr '\n' ' ')"
  [ -z "$only_ssot" ] || fail "in the SSoT lists but missing from the capability map: $(echo "$only_ssot" | tr '\n' ' ')"
}

# --- 2. every adopted name is a tool the bundle really registers --------------
test_adopted_tools_are_registered() {
  local registered phantom
  registered="$(registered_tools)"
  [ -n "$registered" ] || fail "no tool ids parsed from the vendored bundle — extraction is broken"

  phantom="$(diff_sets "$(map_adopted)" "$registered")"
  [ -z "$phantom" ] || fail "named in the SSoT but NOT registered by the vendored bundle: $(echo "$phantom" | tr '\n' ' ')"
}

# --- 3. adopted + not-adopted covers the registered set exactly ---------------
# This is the assertion that stops #247 reopening: a re-vendor that registers a
# new tool leaves it in neither set, and the suite goes red until someone decides
# which it is.
test_every_registered_tool_is_classified() {
  local registered adopted unadopted classified unclassified both stale
  registered="$(registered_tools)"
  adopted="$(map_adopted)"
  unadopted="$(map_not_adopted)"

  [ -n "$unadopted" ] || fail "no rows parsed from the 'Registered but not adopted' inventory — extraction is broken"

  both="$(comm -12 <(printf '%s\n' "$adopted") <(printf '%s\n' "$unadopted"))"
  [ -z "$both" ] || fail "listed as BOTH adopted and not-adopted: $(echo "$both" | tr '\n' ' ')"

  classified="$(printf '%s\n%s\n' "$adopted" "$unadopted" | sort -u)"
  unclassified="$(diff_sets "$registered" "$classified")"
  stale="$(diff_sets "$classified" "$registered")"

  [ -z "$unclassified" ] || fail "registered by the bundle but in neither SSoT list nor the not-adopted inventory: $(echo "$unclassified" | tr '\n' ' ')"
  [ -z "$stale" ] || fail "classified in the capability map but no longer registered by the bundle: $(echo "$stale" | tr '\n' ' ')"
}

# --- 4. the documented allowlist matches the guard's real allowlist -----------
test_allowlist_table_matches_the_guard() {
  local guard_set doc_set only_guard only_doc
  guard_set="$(guard_allowlist)"
  doc_set="$(map_allowlist)"

  [ -n "$guard_set" ] || fail "no entries parsed from the guard's ALLOWLIST array — extraction is broken"
  [ -n "$doc_set" ] || fail "no rows parsed from the map's allowlist table — extraction is broken"

  only_guard="$(diff_sets "$guard_set" "$doc_set")"
  only_doc="$(diff_sets "$doc_set" "$guard_set")"

  [ -z "$only_guard" ] || fail "allowlisted by the guard but undocumented in the map's table: $(echo "$only_guard" | tr '\n' ' ')"
  [ -z "$only_doc" ] || fail "documented in the map's table but not allowlisted by the guard: $(echo "$only_doc" | tr '\n' ' ')"
}

# --- 5. the two verbs #247 was opened for are actually adopted ----------------
# Assertions 1–3 are structural: they would stay green on a tree where neither
# verb had ever been added. This pins the issue's own outcome by name, on both
# files, so a revert of either edit fails loudly rather than shrinking two sets
# in step.
test_get_account_and_get_category_are_adopted() {
  local map_set ssot_set suffix
  map_set="$(map_adopted)"
  ssot_set="$(ssot_adopted)"
  for suffix in ynab_get_account ynab_get_category; do
    assert_exact_line "$map_set" "$suffix" "$suffix missing from the capability table"
    assert_exact_line "$ssot_set" "$suffix" "$suffix missing from the SSoT read/write lists"
  done
}

# --- 6. every mutating-inventory verb is a tool the bundle really registers ---
# The vendor pin (issue #257). assets/write-safety-guardrail.js is authoritative
# for WHICH verbs mutate, but vendor/ynab-mcp/index.cjs is the actual write
# surface, and nothing tied the two together: a re-vendor that renamed or
# dropped a mutating tool would leave the inventory naming a verb that no longer
# exists, and every mirror pinned to it would agree with each other about a
# fiction.
#
# This pins the direction a test CAN decide. The other direction — "a re-vendor
# added a mutating tool the inventory does not know about" — is not mechanically
# derivable, because the bundle does not mark a tool as mutating; that judgement
# is a human one. Assertion 3 above is what forces it: a newly registered tool
# fails this suite until someone classifies it in the capability map, and the
# classification is where "this one writes" gets noticed. So the inventory stays
# authoritative BY DECLARATION for mutating-ness, with assertion 3 as the gate
# that guarantees a human looks, and this assertion as the gate that guarantees
# the names it declares are real.
test_mutating_inventory_verbs_are_registered() {
  local inventory_set registered missing
  inventory_set="$(mutating_inventory_verbs "$INVENTORY")" \
    || fail "the mutating-tool inventory could not be read or parsed empty — refusing to certify the vendor pin"
  registered="$(registered_tools)"

  [ -n "$registered" ] || fail "no tool ids parsed from the vendored bundle — extraction is broken"

  missing="$(diff_sets "$inventory_set" "$registered")"
  [ -z "$missing" ] || fail "named by the mutating-tool inventory but not registered by the vendored bundle: $(echo "$missing" | tr '\n' ' ')"
}

echo "tool-name-ssot-coverage.test.sh — the SSoT names every tool the bundle registers"
run_tests
