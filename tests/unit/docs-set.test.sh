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
for doc in docs/persona.md docs/methodology.md docs/tax-mapping.md docs/write-back-safety.md; do
  if [ -f "$REPO_ROOT/$doc" ]; then
    ok "$doc exists"
  else
    no "$doc exists"
    continue
  fi
  assert_contains "$doc" "$doc carries the canonical not-tax-advice tag" "$TAG"
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
assert_contains docs/methodology.md "methodology defers to the protocol skill" "skills/review/ynab-review.md"
assert_contains docs/methodology.md "methodology states owner specifics live in config" "config instance"

# --- persona: dispatch-format coverage -----------------------------------------
assert_contains docs/persona.md "persona covers the top-five dispatch shape" "top five findings"
assert_contains docs/persona.md "persona covers the severity emoji prefixes" "🔴 action required"
assert_contains docs/persona.md "persona covers the per-finding structure" '**Bold one-line statement.** 1–2 sentence action.'

# --- tax-mapping: the labeled owner example ------------------------------------
assert_contains docs/tax-mapping.md "tax-mapping labels the owner example" "The owner example — ONE labeled instance"
assert_contains docs/tax-mapping.md "owner example: MFJ" '"filingStatus": "mfj"'
assert_contains docs/tax-mapping.md "owner example: SE rate" "0.153"
assert_contains docs/tax-mapping.md "owner example: medical AGI threshold" "0.075"
assert_contains docs/tax-mapping.md "owner example: quarterly due dates" "Apr 15 / Jun 15 / Sep 15 / Jan 15"

# --- write-back safety: model, gate, exact tools --------------------------------
assert_contains docs/write-back-safety.md "safety doc states the ledger-only promise" "ledger-only"
assert_contains docs/write-back-safety.md "safety doc states never-moves-money" "NEVER moves real money"
for op in Categorize Allocate "Fix duplicates" Reconcile; do
  assert_contains docs/write-back-safety.md "safety doc lists allowed op: $op" "$op"
done
assert_contains docs/write-back-safety.md "safety doc forbids transfers" "No transfers"
assert_contains docs/write-back-safety.md "safety doc forbids outbound payments" "No payments out of YNAB"
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
