#!/usr/bin/env bash
#
# tests/unit/config-budgets.test.sh — unit tests for the multi-budget helpers in
# bin/config.sh (issue #84): _cfg_budgets, _cfg_budget_field,
# _cfg_default_budget, and the read-time legacy→multi migration
# (_migrate_config).
#
# Follows the repo test-harness convention (issue #4, tests/lib/assert.sh): raw
# bash with `set -euo pipefail`, sources tests/lib/assert.sh, defines `test_*`
# functions, and ends with `run_tests`. scripts/test.sh auto-discovers it via
# the `*.test.sh` glob.
#
# The loader's documented test seam, YNAB_CONFIG_FILE, is injected per call as a
# command-prefix (`YNAB_CONFIG_FILE=... _cfg_budgets`) — the same idiom
# tests/unit/config.test.sh uses — so each scenario points the loader at its own
# fixture without mutating a global or leaking into other tests.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"

LOADER="$REPO_ROOT/bin/config.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# Two-budget schema-v2 fixture: distinct labels, roles, id/name forms, and
# per-budget overrides — including a boolean `false` (write_back_enabled) that
# the `// empty` idiom would swallow.
MULTI="$SANDBOX/multi.json"
cat > "$MULTI" <<'JSON'
{
  "schema_version": 2,
  "budgets": [
    {
      "label": "Sandbox Personal",
      "role": "personal",
      "budget_name": "Sandbox Personal Budget",
      "monitoring_enabled": true,
      "write_back_enabled": true
    },
    {
      "label": "Sandbox Business",
      "role": "business",
      "budget_id": "b1e2c3d4-0000-4000-8000-000000000084",
      "business_category_group": "Sandbox Biz Group",
      "tax_profile_path": "/sandbox/tax/biz-profile.json",
      "write_back_enabled": false
    }
  ],
  "default_budget": "Sandbox Business"
}
JSON

# Same two entries, no default_budget key — _cfg_default_budget must fall back
# to the FIRST entry.
NODEFAULT="$SANDBOX/nodefault.json"
jq 'del(.default_budget)' "$MULTI" > "$NODEFAULT"

# default_budget set to a label that matches no entry — documented to emit
# nothing (a typo surfaces as empty, never as a silently different budget).
BADDEFAULT="$SANDBOX/baddefault.json"
jq '.default_budget = "No Such Label"' "$MULTI" > "$BADDEFAULT"

# Legacy schema-v1 fixture: singular `budget`, no `budgets` key.
LEGACY="$SANDBOX/legacy.json"
cat > "$LEGACY" <<'JSON'
{
  "schema_version": 1,
  "budget": { "name": "Sandbox Legacy Budget", "id": "11111111-2222-4333-8444-555555555555" },
  "persona": { "name": "Sandbox Persona" }
}
JSON

# Legacy fixture with a null id — the synthesized entry must omit budget_id
# rather than carry a null.
LEGACY_NULLID="$SANDBOX/legacy-nullid.json"
jq '.budget.id = null' "$LEGACY" > "$LEGACY_NULLID"

# Source the loader once to define the helpers. It only DEFINES functions and
# the YNAB_CONFIG_FILE var (no side effects at load time); each test overrides
# YNAB_CONFIG_FILE per call, so the loader's default path is never read.
# shellcheck source=/dev/null
source "$LOADER"

# (a) a two-budget config resolves to two distinct entries with no field
# cross-contamination between them.
test_two_budget_isolation() {
  local budgets
  budgets="$(YNAB_CONFIG_FILE="$MULTI" _cfg_budgets)"
  assert_eq "2"                "$(jq 'length' <<<"$budgets")"        "_cfg_budgets emits both entries"
  assert_eq "Sandbox Personal" "$(jq -r '.[0].label' <<<"$budgets")" "first entry keeps its label"
  assert_eq "Sandbox Business" "$(jq -r '.[1].label' <<<"$budgets")" "second entry keeps its label"
  # overrides stay with their own entry: the business category group must not
  # bleed into the personal entry, nor the personal budget_name into business.
  assert_eq "Sandbox Biz Group" "$(YNAB_CONFIG_FILE="$MULTI" _cfg_budget_field 'Sandbox Business' 'business_category_group')" "business override on the business entry"
  assert_eq "" "$(YNAB_CONFIG_FILE="$MULTI" _cfg_budget_field 'Sandbox Personal' 'business_category_group')" "business override absent from the personal entry"
  assert_eq "Sandbox Personal Budget" "$(YNAB_CONFIG_FILE="$MULTI" _cfg_budget_field 'Sandbox Personal' 'budget_name')" "personal budget_name on the personal entry"
  assert_eq "" "$(YNAB_CONFIG_FILE="$MULTI" _cfg_budget_field 'Sandbox Business' 'budget_name')" "personal budget_name absent from the business entry"
}

# (b) _cfg_budget_field returns the correct per-budget override for each label,
# including a boolean false (which the `// empty` idiom would swallow).
test_budget_field_per_label() {
  assert_eq "b1e2c3d4-0000-4000-8000-000000000084" "$(YNAB_CONFIG_FILE="$MULTI" _cfg_budget_field 'Sandbox Business' 'budget_id')" "budget_id by label"
  assert_eq "personal" "$(YNAB_CONFIG_FILE="$MULTI" _cfg_budget_field 'Sandbox Personal' 'role')" "role by label"
  assert_eq "/sandbox/tax/biz-profile.json" "$(YNAB_CONFIG_FILE="$MULTI" _cfg_budget_field 'Sandbox Business' 'tax_profile_path')" "tax_profile_path by label"
  assert_eq "true"  "$(YNAB_CONFIG_FILE="$MULTI" _cfg_budget_field 'Sandbox Personal' 'write_back_enabled')" "boolean true reads back"
  assert_eq "false" "$(YNAB_CONFIG_FILE="$MULTI" _cfg_budget_field 'Sandbox Business' 'write_back_enabled')" "boolean false reads back as 'false', not empty"
  assert_eq "" "$(YNAB_CONFIG_FILE="$MULTI" _cfg_budget_field 'No Such Label' 'role')" "unknown label emits nothing"
}

# (c) a legacy-only config (`budget` singular, no `budgets`) synthesizes a
# valid single-entry array — read-time only, the file is never rewritten.
test_legacy_migration() {
  local before budgets
  before="$(cat "$LEGACY")"
  budgets="$(YNAB_CONFIG_FILE="$LEGACY" _cfg_budgets)"
  assert_eq "1"                     "$(jq 'length' <<<"$budgets")"              "legacy config synthesizes one entry"
  assert_eq "Sandbox Legacy Budget" "$(jq -r '.[0].label' <<<"$budgets")"       "label is the legacy budget name"
  assert_eq "Sandbox Legacy Budget" "$(jq -r '.[0].budget_name' <<<"$budgets")" "budget_name carried over"
  assert_eq "11111111-2222-4333-8444-555555555555" "$(jq -r '.[0].budget_id' <<<"$budgets")" "budget_id carried over"
  assert_eq "personal"              "$(jq -r '.[0].role' <<<"$budgets")"        "synthesized role is personal"
  # schema_version stays 1 in the effective config — never auto-bumped.
  assert_eq "1" "$(YNAB_CONFIG_FILE="$LEGACY" _migrate_config | jq '.schema_version')" "migration leaves schema_version at 1"
  # the migration is in-memory: the file on disk is byte-for-byte untouched.
  assert_eq "$before" "$(cat "$LEGACY")" "migration never rewrites the config file"
  # a null legacy id is dropped, not carried as a null budget_id.
  assert_eq "false" "$(YNAB_CONFIG_FILE="$LEGACY_NULLID" _cfg_budgets | jq '.[0] | has("budget_id")')" "null legacy id is omitted from the synthesized entry"
}

# (d) _cfg_default_budget returns the matching entry when default_budget is
# set, the first entry when it is absent, and nothing on a label mismatch.
test_default_budget() {
  assert_eq "Sandbox Business" "$(YNAB_CONFIG_FILE="$MULTI" _cfg_default_budget | jq -r '.label')" "default_budget set → the matching entry"
  assert_eq "Sandbox Personal" "$(YNAB_CONFIG_FILE="$NODEFAULT" _cfg_default_budget | jq -r '.label')" "default_budget absent → the first entry"
  assert_eq "" "$(YNAB_CONFIG_FILE="$BADDEFAULT" _cfg_default_budget)" "default_budget matching no label emits nothing"
}

# unconfigured — every helper emits nothing when the config file is missing.
test_missing_config() {
  local missing="$SANDBOX/does-not-exist.json"
  assert_eq "" "$(YNAB_CONFIG_FILE="$missing" _cfg_budgets)"                    "_cfg_budgets empty when config missing"
  assert_eq "" "$(YNAB_CONFIG_FILE="$missing" _cfg_budget_field 'Any' 'role')"  "_cfg_budget_field empty when config missing"
  assert_eq "" "$(YNAB_CONFIG_FILE="$missing" _cfg_default_budget)"             "_cfg_default_budget empty when config missing"
}

run_tests
