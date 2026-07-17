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
# Pin each section to its TABLE ROW (`| N | **Name** |`), not a whole-file
# substring: "Financial Health Score" and "Tax Summary (YTD)" also appear in the
# naming-deviation prose above the table, so a whole-file grep for the bare name
# stays green even when the real table row is renamed (proven by mutation in
# review). The `| N | **Name** |` row shape has no decoy anywhere else in the doc.
methodology_row() {
  assert_contains docs/methodology.md "methodology table row $1: $2" "| $1 | **$2** |"
}
methodology_row 1 "Transaction Classification (tax-aware)"
methodology_row 2 "Duplicate Detection"
methodology_row 3 "Cost-Cutting"
methodology_row 4 "Uncategorized"
methodology_row 5 "Stale Uncleared"
methodology_row 6 "Budget Health"
methodology_row 7 "Unusual / Large"
methodology_row 8 "Reconciliation Status"
methodology_row 9 "Financial Health Score"
methodology_row 10 "Forecast"
methodology_row 11 "Recommended Actions"
methodology_row 12 "Tax Summary (YTD)"
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
# The other two persona AC bullets: the Hobbes default is configurable, and the
# rename config keys. Pin the standalone-default line and both config-key table
# rows so a future edit can't silently drop them.
# shellcheck disable=SC2016  # literal needles: backticks are content, not expansion
assert_contains docs/persona.md "persona documents the Hobbes standalone default" '**`"Hobbes"`** — the shipped standalone default'
# shellcheck disable=SC2016
assert_contains docs/persona.md "persona documents the persona.name config key" '| `persona.name` | string |'
# shellcheck disable=SC2016
assert_contains docs/persona.md "persona documents the persona.voice_overrides config key" '| `persona.voice_overrides` | string |'

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
# Pin each write tool to its VERDICT ROW, not a whole-file substring. Two traps
# the old whole-file grep fell into, both proven by mutation in review:
#   * substring overlap — `ynab_update_transaction` is a substring of
#     `…transactions`, so deleting the singular row still matched the plural;
#   * verdict drift — a lone "denied (money movement)" check stayed green even
#     when a create verb's row was flipped to ✅ allowed.
# assert_tool_row locates the UNIQUE table row by the backtick-bounded tool name
# (the trailing "` |" defeats the singular/plural overlap) and asserts that row
# carries the expected verdict, so a removed row OR a flipped verdict fails.
SAFETY_DOC="docs/write-back-safety.md"
BT='`'   # a literal backtick, kept out of command position
assert_tool_row() {
  local desc="$1" suffix="$2" verdict="$3" row
  row="$(grep -F -- "${BT}${PREFIX}${suffix}${BT} |" "$REPO_ROOT/$SAFETY_DOC" 2>/dev/null)"
  if [ -n "$row" ] && [ "$(printf '%s\n' "$row" | wc -l)" -eq 1 ] \
     && printf '%s' "$row" | grep -qF -- "$verdict"; then
    ok "$desc"
  else
    no "$desc"
  fi
}
# The five ledger-only ALLOWED write tools (ALLOWED_TOOLS in the guardrail).
for suffix in ynab_update_transaction ynab_update_transactions ynab_update_category \
              ynab_delete_transaction ynab_reconcile_account; do
  assert_tool_row "safety doc marks ${suffix} allowed" "$suffix" "✅ allowed"
done
# The five money-movement/mutation DENIED write tools (DENIED_TOOLS in the
# guardrail) — each pinned to a denied verdict, so flipping one to ✅ allowed fails.
for suffix in ynab_create_transaction ynab_create_transactions \
              ynab_create_receipt_split_transaction ynab_create_account \
              ynab_set_default_budget; do
  assert_tool_row "safety doc marks ${suffix} denied" "$suffix" "⛔ denied"
done

# --- README links all four docs --------------------------------------------------
for doc in docs/persona.md docs/methodology.md docs/tax-mapping.md docs/write-back-safety.md; do
  assert_contains README.md "README links $doc" "($doc)"
done

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
