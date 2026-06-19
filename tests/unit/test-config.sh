#!/usr/bin/env bash
# Unit tests for bin/config.sh — the skills/commands config loader.
# Run directly: tests/unit/test-config.sh
#
# Style mirrors workbench-core/hooks/test-session-warmup.sh: raw bash, `set -u`,
# PASS/FAIL counters, a mktemp sandbox, and a non-zero exit when anything fails.
# Slots into the repo-wide test entrypoint from issue #4 (tests/unit/ + scripts/test.sh).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOADER="$REPO_ROOT/bin/config.sh"
EXAMPLE="$REPO_ROOT/assets/config.example.json"
PASS=0
FAIL=0

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1)); echo "  ✅ $desc"
  else
    FAIL=$((FAIL + 1)); echo "  ❌ $desc — expected: [$expected] got: [$actual]"
  fi
}

assert_empty() {
  local desc="$1" actual="$2"
  if [ -z "$actual" ]; then
    PASS=$((PASS + 1)); echo "  ✅ $desc"
  else
    FAIL=$((FAIL + 1)); echo "  ❌ $desc — expected empty, got: [$actual]"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1)); echo "  ✅ $desc"
  else
    FAIL=$((FAIL + 1)); echo "  ❌ $desc — expected to find: [$needle] in: [$haystack]"
  fi
}

# Sandbox config with known values, so present/absent reads are deterministic.
FIXTURE="$SANDBOX/config.json"
cat > "$FIXTURE" <<'JSON'
{
  "schema_version": 1,
  "budget": { "name": "Sandbox Budget", "id": null },
  "tax_profile": { "filing_status": "single", "schedules": ["C", "SE"] },
  "persona": { "name": "Sandbox Persona" }
}
JSON

# Point the loader at the fixture via its documented test seam, then source it.
YNAB_CONFIG_FILE="$FIXTURE"
# shellcheck source=/dev/null
source "$LOADER"

echo "present fields — _cfg returns the configured value:"
assert_eq    "_cfg '.budget.name'"               "Sandbox Budget"  "$(_cfg '.budget.name')"
assert_eq    "_cfg '.schema_version'"            "1"               "$(_cfg '.schema_version')"
assert_eq    "_cfg '.tax_profile.filing_status'" "single"          "$(_cfg '.tax_profile.filing_status')"
assert_eq    "_cfg array element '.tax_profile.schedules[0]'" "C"  "$(_cfg '.tax_profile.schedules[0]')"
assert_eq    "_cfg jq filter '.tax_profile.schedules | length'" "2" "$(_cfg '.tax_profile.schedules | length')"

echo "absent fields — _cfg returns empty (caller applies its own default):"
assert_empty "_cfg '.report.output_dir' (key absent)"   "$(_cfg '.report.output_dir')"
assert_empty "_cfg '.budget.id' (value is null)"        "$(_cfg '.budget.id')"
assert_empty "_cfg '.business.name' (object absent)"    "$(_cfg '.business.name')"
# caller-side default kicks in when _cfg is empty
out_dir="$(_cfg '.report.output_dir')"; out_dir="${out_dir:-/fallback/dir}"
assert_eq    "caller default applies on empty"          "/fallback/dir" "$out_dir"

echo "config present — _require_config succeeds:"
err="$(_require_config 2>&1)"; rc=$?
assert_eq    "_require_config exit code with config present" "0" "$rc"
assert_empty "_require_config emits nothing when config present" "$err"

echo "config absent — guard errors, points at setup, non-zero exit:"
YNAB_CONFIG_FILE="$SANDBOX/does-not-exist.json"
err="$(_require_config 2>&1)"; rc=$?
assert_eq       "_require_config exit code is non-zero" "1" "$rc"
assert_contains "error names the missing path"   "$err" "config not found"
assert_contains "error points at /workbench-ynab:setup" "$err" "/workbench-ynab:setup"
assert_empty    "_cfg returns empty when config file is missing" "$(_cfg '.budget.name')"

echo "shipped example config reads through the loader:"
if [ -f "$EXAMPLE" ]; then
  YNAB_CONFIG_FILE="$EXAMPLE"
  assert_eq "example schema_version is an integer" "1" "$(_cfg '.schema_version')"
  # every required top-level key is present and reads back non-empty
  for path in '.budget.name' '.tax_profile.filing_status' '.persona.name' '.report.output_dir'; do
    val="$(_cfg "$path")"
    if [ -n "$val" ]; then PASS=$((PASS + 1)); echo "  ✅ example $path non-empty"; \
      else FAIL=$((FAIL + 1)); echo "  ❌ example $path empty"; fi
  done
else
  FAIL=$((FAIL + 1)); echo "  ❌ assets/config.example.json not found at $EXAMPLE"
fi

echo ""
echo "config loader: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
