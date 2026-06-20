#!/usr/bin/env bash
#
# check-tool-name-sources.test.sh — self-test for the swap-ready guard (issue #87).
#
# Self-contained: no test framework required. Run directly:
#   bash tests/check-tool-name-sources.test.sh
# Exits 0 if all assertions pass, 1 otherwise. Slots into the repo-wide test
# entrypoint from issue #4 (tests/unit/ + scripts/test.sh) once it lands.
#
# The guard (bin/check-tool-name-sources.sh) is the *test* for issue #87's
# central invariant (no concrete YNAB tool name outside the allowlist). This
# file is the test for the test: it proves the guard catches a planted name on
# every scanned surface, honours the allowlist, ignores the bare prefix / family
# glob, and passes on a clean tree.
#
# It runs the guard against a throwaway sandbox repo, so it never mutates the
# real tree. The forbidden token is assembled at runtime from two harmless
# fragments — the bare prefix (never matched by the guard) and an operation
# suffix — so THIS file contains no literal concrete name and stays clean when
# the guard scans tests/.

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/../bin/check-tool-name-sources.sh"

# Assemble a concrete tool name without ever writing one literally in this file.
PREFIX='mcp__plugin_workbench-ynab_ynab__'          # bare prefix — never matched
CONCRETE="${PREFIX}ynab_list_budgets"               # a real, matchable name
GLOB="${PREFIX}ynab_*"                              # family glob — never matched

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0
fail=0

# Lay down a minimal sandbox repo with the guard and the allowlisted files.
reset_sandbox() {
  rm -rf "$SANDBOX"
  mkdir -p "$SANDBOX/bin" "$SANDBOX/skills/protocol" "$SANDBOX/docs" \
           "$SANDBOX/agents" "$SANDBOX/hooks" "$SANDBOX/assets" \
           "$SANDBOX/commands" "$SANDBOX/vendor"
  cp "$GUARD" "$SANDBOX/bin/check-tool-name-sources.sh"
  chmod +x "$SANDBOX/bin/check-tool-name-sources.sh"
  # Allowlisted files exist but start clean.
  : > "$SANDBOX/skills/protocol/ynab-tools.md"
  : > "$SANDBOX/docs/mcp-capability-map.md"
  : > "$SANDBOX/agents/ynab-orchestrator.md"
  : > "$SANDBOX/README.md"
}

# run_case "<description>" <expected-exit> <file-relative-to-sandbox> "<content>"
run_case() {
  local desc="$1" expected="$2" file="$3" content="$4"
  reset_sandbox
  if [ -n "$file" ]; then
    mkdir -p "$SANDBOX/$(dirname "$file")"
    printf '%s\n' "$content" > "$SANDBOX/$file"
  fi
  local actual=0
  ( cd "$SANDBOX" && bash bin/check-tool-name-sources.sh ) >/dev/null 2>&1 || actual=$?
  if [ "$actual" -eq "$expected" ]; then
    echo "  ✓ $desc (exit $actual)"
    pass=$((pass + 1))
  else
    echo "  ✖ $desc — expected exit $expected, got $actual"
    fail=$((fail + 1))
  fi
}

echo "Self-test: guard catches violations on every scanned surface"
run_case "concrete name in a skill is caught"        1 "skills/review.md"   "uses $CONCRETE"
run_case "concrete name in a hook is caught"         1 "hooks/probe.sh"     "TOOL=$CONCRETE"
run_case "concrete name in a bin script is caught"   1 "bin/probe.sh"       "TOOL=$CONCRETE"
run_case "concrete name in a test is caught"         1 "tests/probe.sh"     "TOOL=$CONCRETE"
run_case "concrete name in README is caught"         1 "README.md"          "see $CONCRETE"
run_case "concrete name in JSON config is caught"    1 "config.json"        "{\"tool\": \"$CONCRETE\"}"
run_case "concrete name in an asset is caught"       1 "assets/contract.md" "apply via $CONCRETE"
run_case "concrete name in a command is caught"      1 "commands/run.md"    "calls $CONCRETE"

echo "Self-test: allowlist and derivation-rule exemptions pass"
run_case "concrete name in the SSoT is permitted"        0 "skills/protocol/ynab-tools.md" "$CONCRETE"
run_case "concrete name in the capability map permitted" 0 "docs/mcp-capability-map.md"    "$CONCRETE"
run_case "concrete name in the orchestrator permitted"   0 "agents/ynab-orchestrator.md"   "tools: $CONCRETE"
run_case "bare prefix alone is not flagged"              0 "skills/review.md"              "prefix is $PREFIX"
run_case "family glob alone is not flagged"              0 "skills/review.md"              "glob is $GLOB"
run_case "concrete name inside vendor/ is ignored"       0 "vendor/index.cjs"             "$CONCRETE"
run_case "clean tree passes"                             0 ""                              ""

echo
echo "Passed: $pass   Failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "✓ Guard self-test green."
