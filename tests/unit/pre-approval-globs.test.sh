#!/usr/bin/env bash
#
# tests/unit/pre-approval-globs.test.sh — pin the write-tool pre-approval set
# and its permission notes (issue #54, M4-11).
#
# The pre-approval globs are declared in the tool-name SSoT
# (skills/protocol/ynab-tools.md, "## Pre-approval globs"): the read-phase globs
# and the tight Sprint-4 write set. These tests guard the invariants that are
# easy to break and expensive to get wrong on a financial write path:
#   * every declared pre-approval glob uses the exact plugin-namespaced prefix —
#     a bare mcp__ynab__ form silently fails to match and never pre-approves, and
#     the swap guard (bin/check-tool-name-sources.sh) does NOT catch a wrong
#     namespace (its pattern only matches the CORRECT prefix), so this is the
#     only gate on that regression (AC: wrong-namespace catch);
#   * the delete verb is ABSENT from the pre-approval set and the family glob is
#     never used for pre-approval — either would grant a ledger-deleting verb
#     standing permission, bypassing its M4-8 confirmation path;
#   * the exact tight set is pinned (2 read globs + 4 write tools), so silently
#     widening it (e.g. adding delete or create) fails the build;
#   * the permission notes doc (docs/mcp-capability-map.md) explains the
#     namespacing, the /ynab-apply (M4-5) gate, and the withheld delete verb.
#
# To keep this file itself clean under bin/check-tool-name-sources.sh, it never
# inlines a full concrete tool name: the plugin prefix and the operation
# suffixes are separate literals, composed only at runtime. (The bare prefix and
# the `..._ynab_*` family glob are exempt from the guard; a full `..._ynab_<op>`
# name is not, so it must never appear here as one literal token.)
#
# Follows the repo harness convention (tests/lib/assert.sh): raw bash with
# `set -euo pipefail`, `test_*` functions, `run_tests`. Auto-discovered by
# scripts/test.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"

SSOT="$REPO_ROOT/skills/protocol/ynab-tools.md"
MAP="$REPO_ROOT/docs/mcp-capability-map.md"

# The correct plugin-namespaced prefix, built from parts so the composed full
# names below never appear as a single literal token in this file.
PREFIX="mcp__plugin_workbench-ynab_ynab__"

# Every line inside the "## Pre-approval globs" section (up to the next "## "
# heading — the "### Read phase" / "### Write phase" subheadings do NOT terminate
# it) that starts with `mcp__`. Extracting `^mcp__` rather than `^$PREFIX` is
# deliberate: a bad bare-form entry (mcp__ynab__…) is captured here and then
# fails the prefix assertion, which is the whole point.
preapproval_set() {
  awk '/^## Pre-approval globs/{f=1;next} /^## /{f=0} f' "$SSOT" \
    | grep '^mcp__' || true
}

# The SSoT section exists and declares a non-empty pre-approval set.
test_preapproval_section_present_and_nonempty() {
  assert_file_exists "$SSOT"
  grep -qE '^## Pre-approval globs' "$SSOT" \
    || fail "SSoT is missing the '## Pre-approval globs' section"
  local set; set="$(preapproval_set)"
  [ -n "$set" ] || fail "the pre-approval section declares no mcp__ entries"
}

# AC: every declared pre-approval glob begins with the exact namespaced prefix.
# Catches a wrong-namespace regression (e.g. the non-resolving mcp__ynab__ form).
test_every_glob_uses_the_namespaced_prefix() {
  local set; set="$(preapproval_set)"
  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      "$PREFIX"*) : ;;
      *) fail "pre-approval entry does not start with $PREFIX: [$line]" ;;
    esac
  done <<EOF
$set
EOF
}

# The bare, non-resolving mcp__ynab__ form appears nowhere in the SSoT. The
# correct prefix contains 'workbench-ynab_ynab__', never the bare 'mcp__ynab__'.
test_no_bare_namespace_anywhere_in_ssot() {
  if grep -qF 'mcp__ynab__' "$SSOT"; then
    fail "SSoT contains the non-resolving bare 'mcp__ynab__' form"
  fi
}

# AC: the exact tight set is pinned — the two read globs plus the four write
# tools, and nothing else. Widening it (adding delete/create, or the family
# glob) changes the count or membership and fails here.
test_preapproval_set_is_the_exact_tight_six() {
  local set; set="$(preapproval_set)"
  local count; count="$(printf '%s\n' "$set" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  assert_eq "6" "$count" "pre-approval set must be exactly 2 read globs + 4 write tools"

  # Read-phase globs.
  assert_exact_line "$set" "${PREFIX}ynab_list_*"  "read glob ynab_list_* is declared"
  assert_exact_line "$set" "${PREFIX}ynab_get_*"   "read glob ynab_get_* is declared"
  # Write-phase tools — the four M4 write verbs, by full name.
  assert_exact_line "$set" "${PREFIX}ynab_update_transaction"  "write tool update_transaction is declared"
  assert_exact_line "$set" "${PREFIX}ynab_update_transactions" "write tool update_transactions is declared"
  assert_exact_line "$set" "${PREFIX}ynab_update_category"     "write tool update_category is declared"
  assert_exact_line "$set" "${PREFIX}ynab_reconcile_account"   "write tool reconcile_account is declared"
}

# AC: the delete verb is absent from the pre-approval set, and the family glob is
# never used for pre-approval — either would blanket-grant a ledger-deleting verb.
test_delete_and_family_glob_are_excluded_from_preapproval() {
  local set; set="$(preapproval_set)"
  if printf '%s\n' "$set" | grep -qxF -- "${PREFIX}ynab_delete_transaction"; then
    fail "delete_transaction is in the pre-approval set — it must keep its M4-8 confirmation path"
  fi
  if printf '%s\n' "$set" | grep -qxF -- "${PREFIX}ynab_create_transaction"; then
    fail "create_transaction is in the pre-approval set — no M4 write path creates transactions"
  fi
  if printf '%s\n' "$set" | grep -qxF -- "${PREFIX}ynab_*"; then
    fail "the family glob is in the pre-approval set — it would sweep in the delete verb"
  fi
}

# The SSoT documents the delete exclusion inline, pointing at the M4-8 path.
test_ssot_documents_delete_exclusion() {
  local body; body="$(cat "$SSOT")"
  assert_contains "$body" "delete_transaction" "SSoT names the withheld delete verb"
  assert_contains "$body" "M4-8" "SSoT points the delete exclusion at the M4-8 confirmation path"
}

# AC: a permission-notes section explains the namespacing, the /ynab-apply gate,
# and the withheld delete verb. It lives in the allowlisted capability map (the
# human-readable permission contract), which may hold concrete names/snippets.
test_permission_notes_present_in_capability_map() {
  assert_file_exists "$MAP"
  local body; body="$(cat "$MAP")"
  assert_contains "$body" "Permission notes" "capability map has a Permission notes section"
  assert_contains "$body" "mcp__ynab__" \
    "permission notes explain why the bare mcp__ynab__ form must NOT be used"
  assert_contains "$body" "/ynab-apply" "permission notes name the /ynab-apply approval gate"
  assert_contains "$body" "M4-5" "permission notes tie the human gate to M4-5"
  assert_contains "$body" "M4-8" "permission notes tie the withheld delete verb to M4-8"
}

run_tests
