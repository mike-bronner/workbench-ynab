#!/usr/bin/env bash
# Unit tests for the repo's version model — issue #75.
# Run directly: tests/unit/test-version.sh
#
# Style mirrors tests/unit/test-config.sh: raw bash, `set -u`, PASS/FAIL
# counters, and a non-zero exit when anything fails. Slots into the repo-wide
# test entrypoint from issue #4 (tests/unit/ + scripts/test.sh).
#
# Locks in the version invariants so release automation (issue #74 / M5-5) has
# exactly one bump target and no hidden ones can creep back in:
#   - the plugin's own version is 0.1.0 in .claude-plugin/plugin.json
#   - the vendored YNAB MCP version is frozen, provenance-only in
#     vendor/ynab-mcp/vendored.json (@dizzlkheinz/ynab-mcpb@0.26.10)
#   - no other manifest in the repo carries a standalone `version` field
#   - the README documents the model and names the sole bump target

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLUGIN_MANIFEST="$REPO_ROOT/.claude-plugin/plugin.json"
VENDORED="$REPO_ROOT/vendor/ynab-mcp/vendored.json"
CHANGESET_PKG="$REPO_ROOT/assets/package.json"
README="$REPO_ROOT/README.md"
PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1)); echo "  ✅ $desc"
  else
    FAIL=$((FAIL + 1)); echo "  ❌ $desc — expected: [$expected] got: [$actual]"
  fi
}

assert_ok() {
  # assert_ok <desc> <cmd...> — passes when the command exits 0
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "  ✅ $desc"
  else
    FAIL=$((FAIL + 1)); echo "  ❌ $desc — command failed: $*"
  fi
}

assert_fail() {
  # assert_fail <desc> <cmd...> — passes when the command exits non-zero
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    FAIL=$((FAIL + 1)); echo "  ❌ $desc — command unexpectedly succeeded: $*"
  else
    PASS=$((PASS + 1)); echo "  ✅ $desc"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1)); echo "  ✅ $desc"
  else
    FAIL=$((FAIL + 1)); echo "  ❌ $desc — missing: [$needle]"
  fi
}

command -v jq >/dev/null 2>&1 || { echo "jq is required to run this test; install jq"; exit 1; }

echo "plugin version is 0.1.0:"
# The literal acceptance-criterion check from issue #75.
assert_ok "jq -e '.version == \"0.1.0\"' .claude-plugin/plugin.json exits 0" \
  jq -e '.version == "0.1.0"' "$PLUGIN_MANIFEST"

echo "vendored YNAB MCP version is frozen provenance:"
if [ -f "$VENDORED" ]; then
  assert_eq "vendored.json name is @dizzlkheinz/ynab-mcpb" \
    "@dizzlkheinz/ynab-mcpb" "$(jq -r '.name' "$VENDORED")"
  assert_eq "vendored.json version is 0.26.10" \
    "0.26.10" "$(jq -r '.version' "$VENDORED")"
else
  FAIL=$((FAIL + 1)); echo "  ❌ vendor/ynab-mcp/vendored.json not found at $VENDORED"
fi

echo "no hidden extra bump target:"
# assets/package.json is a private validator manifest — it must NOT carry a
# standalone version field that release automation could mistake for a target.
assert_fail "assets/package.json has no .version field" \
  jq -e 'has("version")' "$CHANGESET_PKG"

# Repo-wide guard: the ONLY files with a top-level JSON `version` are the plugin
# manifest and the frozen vendored marker. Any new one is a hidden bump target.
# node_modules is pruned (alongside .git): assets/ declares real npm deps, so
# `npm install` is a normal workflow and node_modules/ is gitignored untracked
# cruft on disk — every dep's package.json carries a `version`, none of which is
# a real bump target, so scanning them would false-fail this guard.
unexpected=""
while IFS= read -r f; do
  [ "$f" = "$PLUGIN_MANIFEST" ] && continue
  [ "$f" = "$VENDORED" ] && continue
  if jq -e 'type == "object" and has("version")' "$f" >/dev/null 2>&1; then
    unexpected="${unexpected}${f} "
  fi
done <<EOF
$(find "$REPO_ROOT" \
  \( -path "$REPO_ROOT/.git" -o -name node_modules \) -prune -o \
  -name '*.json' -print)
EOF
assert_eq "only plugin.json and vendored.json carry a top-level version field" \
  "" "$(printf '%s' "$unexpected" | sed 's/[[:space:]]*$//')"

echo "README documents the version model:"
if [ -f "$README" ]; then
  readme="$(cat "$README")"
  assert_contains "README has a Versioning section" "$readme" "## Versioning"
  assert_contains "Versioning names the sole bump target" "$readme" ".claude-plugin/plugin.json"
  assert_contains "Versioning references the frozen vendored marker" "$readme" "vendor/ynab-mcp/vendored.json"
  # Positional guard: AC #3 requires the Versioning section sit BETWEEN
  # Architecture and License — not merely exist somewhere. The grep -qF checks
  # above would still pass if the section were moved after ## License or gutted
  # while the strings survived elsewhere; this asserts the actual ordering by
  # heading line number so the test proves placement, not just presence.
  arch_line="$(grep -n '^## Architecture' "$README" | head -1 | cut -d: -f1)"
  ver_line="$(grep -n '^## Versioning' "$README" | head -1 | cut -d: -f1)"
  lic_line="$(grep -n '^## License' "$README" | head -1 | cut -d: -f1)"
  if [ -n "$arch_line" ] && [ -n "$ver_line" ] && [ -n "$lic_line" ] \
     && [ "$arch_line" -lt "$ver_line" ] && [ "$ver_line" -lt "$lic_line" ]; then
    PASS=$((PASS + 1)); echo "  ✅ Versioning section sits between Architecture and License"
  else
    FAIL=$((FAIL + 1)); echo "  ❌ Versioning section not between Architecture and License — lines Architecture:[$arch_line] Versioning:[$ver_line] License:[$lic_line]"
  fi
else
  FAIL=$((FAIL + 1)); echo "  ❌ README.md not found at $README"
fi

echo ""
echo "version model: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
