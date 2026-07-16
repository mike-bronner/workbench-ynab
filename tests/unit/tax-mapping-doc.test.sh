#!/usr/bin/env bash
# Unit tests for docs/tax-mapping.md — the tax-engine reference doc
# (issue #26, M3-7). Run directly: tests/unit/tax-mapping-doc.test.sh
#
# Pins the doc's AC-mandated invariants so a future edit can't silently drop
# them: the seven required sections, the canonical not-tax-advice disclaimer
# (byte-for-byte, per issue #18 and tests/report-disclaimer.test.sh), the
# skills/data-dir split statement, the dollars-not-milliunits rule, the
# stderr-only logging rule, the code-is-source-of-truth statement, and the
# worked schedC.27a example. Style mirrors tests/unit/us-tax-lines.test.sh:
# raw bash, `set -u`, PASS/FAIL counters, non-zero exit on any failure.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FILE="$REPO_ROOT/docs/tax-mapping.md"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
no() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# assert_contains <desc> <literal> — passes when the doc contains <literal>.
assert_contains() {
  local desc="$1" needle="$2"
  if grep -qF -- "$needle" "$FILE" 2>/dev/null; then
    ok "$desc"
  else
    no "$desc"
  fi
}

echo "tax-mapping-doc.test.sh — docs/tax-mapping.md invariants"

if [ ! -f "$FILE" ]; then
  no "docs/tax-mapping.md exists"
  echo ""
  echo "passed: $PASS  failed: $((FAIL))"
  exit 1
fi
ok "docs/tax-mapping.md exists"

# --- the seven AC sections -----------------------------------------------------
assert_contains "section 1 (concept and split)"   "## 1. Concept and split"
assert_contains "section 2 (schema reference)"    "## 2. Schema reference"
assert_contains "section 3 (default US ruleset)"  "## 3. The default US ruleset"
assert_contains "section 4 (mapping engine)"      "## 4. The mapping engine"
assert_contains "section 5 (customizing)"         "## 5. Customizing your profile"
assert_contains "section 6 (privacy)"             "## 6. Privacy"
assert_contains "section 7 (how M2 consumes it)"  "## 7. How the review skill consumes the engine"

# --- canonical disclaimer, byte-for-byte (issue #18) ---------------------------
assert_contains "canonical not-tax-advice disclaimer" \
  "⚠️ Estimates only — not tax advice. Consult a qualified professional before filing or paying."

# --- the skills / data-dir / MCP split (milestone-brief requirement) -----------
# Needle deliberately drops the leading `~` (shellcheck SC2088 flags a
# tilde-leading literal even as a grep needle); the path is still pinned.
assert_contains "data-dir path stated" \
  "/.claude/plugins/data/workbench-ynab-claude-workbench/"
assert_contains "config survives plugin updates" "survives plugin updates"
assert_contains "MCP gets only the Keychain token" \
  "The vendored YNAB MCP receives only the Keychain token"
assert_contains "namespaced MCP tools cited" "mcp__plugin_workbench-ynab_ynab__"

# --- units, logging, source-of-truth -------------------------------------------
assert_contains "dollars-not-milliunits rule" \
  "Every monetary amount in a tax profile is in US dollars."
assert_contains "stderr-only logging rule" "stdout is the JSON-RPC channel"
assert_contains "code is the source of truth" "The code is the source of truth."

# --- mapping-engine essentials --------------------------------------------------
assert_contains "worked example resolves to schedC.27a" '"taxLineId": "schedC.27a"'
assert_contains "unclassified outcome documented" "unclassified"
assert_contains "example template cross-referenced" "tax-profile.example.json"
assert_contains "setup command cross-linked" "/workbench-ynab:setup"

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
