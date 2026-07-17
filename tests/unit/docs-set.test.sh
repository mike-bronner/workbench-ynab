#!/usr/bin/env bash
# Unit tests for the release docs/ set (issue #71, M5-2): docs/persona.md,
# docs/methodology.md, docs/tax-mapping.md, docs/write-back-safety.md.
# Run directly: tests/unit/docs-set.test.sh
#
# Pins the set's AC-mandated invariants so a future edit can't silently drop
# them: every doc carries the canonical not-tax-advice tag (byte-for-byte, per
# issue #18), the methodology doc names all 12 implemented analysis sections and
# the milliunits rule, the persona doc covers the dispatch shape, the write-back
# safety doc enumerates the exact namespaced write tools and the batch-approval
# gate, and the README links all four docs. Style mirrors
# tests/unit/tax-mapping-doc.test.sh: raw bash, `set -u`, PASS/FAIL counters,
# non-zero exit on any failure.
#
# Concrete tool names are assembled at runtime from the bare prefix (never
# matched by bin/check-tool-name-sources.sh) so this file stays clean under the
# swap-ready guard — only docs/write-back-safety.md is allowlisted to hold them.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
no() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# assert_contains <file> <desc> <literal>
assert_contains() {
  local file="$1" desc="$2" needle="$3"
  if grep -qF -- "$needle" "$REPO_ROOT/$file" 2>/dev/null; then
    ok "$desc"
  else
    no "$desc"
  fi
}

TAG='⚠️ Estimates only — not tax advice. Consult a qualified professional before filing or paying.'
PREFIX='mcp__plugin_workbench-ynab_ynab__'   # bare prefix — guard-safe

echo "docs-set.test.sh — the issue #71 docs/ set invariants"

# --- every doc in the set exists and carries the canonical disclaimer ---------
# The AC says "prominent", not merely present: the tag must open the doc as a
# top-of-file blockquote (all four keep it within the first 10 lines).
for doc in docs/persona.md docs/methodology.md docs/tax-mapping.md docs/write-back-safety.md; do
  if [ -f "$REPO_ROOT/$doc" ]; then
    ok "$doc exists"
  else
    no "$doc exists"
    continue
  fi
  assert_contains "$doc" "$doc carries the canonical not-tax-advice tag" "$TAG"
  if head -10 "$REPO_ROOT/$doc" | grep -qF -- "> $TAG"; then
    ok "$doc disclaimer is prominent (top-of-file blockquote)"
  else
    no "$doc disclaimer is prominent (top-of-file blockquote)"
  fi
done

# --- methodology: the 12 sections as implemented, milliunits, generic ---------
for section in \
  "Transaction Classification" "Duplicate Detection" "Cost-Cutting" \
  "Uncategorized" "Stale Uncleared" "Budget Health" "Unusual / Large" \
  "Reconciliation Status" "Financial Health Score" "Forecast" \
  "Recommended Actions" "Tax Summary (YTD)"; do
  assert_contains docs/methodology.md "methodology names section: $section" "$section"
done
assert_contains docs/methodology.md "methodology states the milliunits rule" "milliunits — divide by"
# Pin the worked example, not just the prose — it fixes the ÷1000 relationship
# (a mutated divisor can't survive this string).
# shellcheck disable=SC2016  # a literal needle: no backtick expansion wanted
assert_contains docs/methodology.md "methodology pins the ÷1000 worked example" '`-12340` is `-12.34`'
assert_contains docs/methodology.md "methodology defers to the protocol skill" "skills/review/ynab-review.md"
assert_contains docs/methodology.md "methodology states owner specifics live in config" "config instance"

# --- persona: dispatch-format coverage -----------------------------------------
assert_contains docs/persona.md "persona covers the top-five dispatch shape" "top five findings"
assert_contains docs/persona.md "persona covers the severity emoji prefixes" "🔴 action required"
assert_contains docs/persona.md "persona covers the 🟡 severity tier" "🟡 attention needed"
assert_contains docs/persona.md "persona covers the 🟢 severity tier" "🟢 good/informational"
assert_contains docs/persona.md "persona covers the per-finding structure" '**Bold one-line statement.** 1–2 sentence action.'

# --- tax-mapping: the labeled owner example ------------------------------------
assert_contains docs/tax-mapping.md "tax-mapping labels the owner example" "The owner example — ONE labeled instance"
# Scope the value checks to the owner-example section (its heading up to the
# next ## heading): the same literals exist elsewhere in the doc, so a
# whole-file grep would stay green even if the section were deleted.
OWNER_EXAMPLE="$(awk '/^### The owner example/{f=1} f && /^## /{exit} f' "$REPO_ROOT/docs/tax-mapping.md")"
assert_owner() {
  local desc="$1" needle="$2"
  if printf '%s\n' "$OWNER_EXAMPLE" | grep -qF -- "$needle"; then
    ok "$desc"
  else
    no "$desc"
  fi
}
assert_owner "owner example: MFJ" '"filingStatus": "mfj"'
assert_owner "owner example: SE rate" "0.153"
assert_owner "owner example: medical AGI threshold" "0.075"
assert_owner "owner example: quarterly due dates" "Apr 15 / Jun 15 / Sep 15 / Jan 15"

# --- tax-mapping: generic schema table (AC 3a) and line catalog (AC 3c) ---------
# Content-pin one representative row of each table (both literals occur nowhere
# else in the doc), so gutting a table while leaving its heading can't stay green.
# shellcheck disable=SC2016  # literal needles: no backtick expansion wanted
assert_contains docs/tax-mapping.md "tax-mapping schema table pins the filingStatus field row" \
  '| `filingStatus` | enum | **Required.** `single` \| `mfj` \| `mfs` \| `hoh` \| `qw`. |'
# shellcheck disable=SC2016
assert_contains docs/tax-mapping.md "tax-mapping line catalog pins the schedSE row" \
  '| `schedSE` | SE | Self-employment tax (12.4% Social Security + 2.9% Medicare = 15.3%) |'

# --- write-back safety: model, gate, exact tools --------------------------------
assert_contains docs/write-back-safety.md "safety doc states the ledger-only promise" "ledger-only"
assert_contains docs/write-back-safety.md "safety doc states never-moves-money" "NEVER moves real money"
for op in Categorize Allocate "Fix duplicates" Reconcile; do
  assert_contains docs/write-back-safety.md "safety doc lists allowed op: $op" "$op"
done
assert_contains docs/write-back-safety.md "safety doc forbids transfers" "No transfers"
assert_contains docs/write-back-safety.md "safety doc forbids outbound payments" "No payments out of YNAB"
assert_contains docs/write-back-safety.md "safety doc forbids transaction creation" "No transaction creation"
assert_contains docs/write-back-safety.md "safety doc forbids account/default-budget mutation" "No account or default-budget mutation"
assert_contains docs/write-back-safety.md "safety doc states the batch gate" "One approval covers one batch"
for suffix in ynab_update_transaction ynab_update_transactions ynab_update_category \
              ynab_create_transaction ynab_create_transactions ynab_delete_transaction \
              ynab_reconcile_account; do
  assert_contains docs/write-back-safety.md "safety doc names ${suffix}" "${PREFIX}${suffix}"
done
assert_contains docs/write-back-safety.md "safety doc marks the create verbs denied" "denied (money movement)"

# --- README links all four docs --------------------------------------------------
for doc in docs/persona.md docs/methodology.md docs/tax-mapping.md docs/write-back-safety.md; do
  assert_contains README.md "README links $doc" "($doc)"
done

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
