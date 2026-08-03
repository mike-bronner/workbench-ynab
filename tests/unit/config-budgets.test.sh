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

# Duplicate labels — documented-unique in the schema (prose only; JSON Schema
# cannot enforce cross-item uniqueness), so the loader must collapse to the
# FIRST match rather than emit one line per duplicate. The entries disagree on
# write_back_enabled so a missing collapse would surface as "true\nfalse".
DUPLABEL="$SANDBOX/duplabel.json"
cat > "$DUPLABEL" <<'JSON'
{
  "schema_version": 2,
  "budgets": [
    { "label": "Twin", "role": "personal", "budget_name": "First Twin",  "write_back_enabled": true },
    { "label": "Twin", "role": "business", "budget_name": "Second Twin", "write_back_enabled": false }
  ]
}
JSON

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

# duplicate labels collapse to the FIRST matching entry — one value comes back,
# never one line per duplicate (a "true\nfalse" result would fail a naive
# [ "$x" = "false" ] guard). Mirrors _cfg_default_budget's .[0] collapse.
test_budget_field_duplicate_label_first_match_wins() {
  assert_eq "First Twin" "$(YNAB_CONFIG_FILE="$DUPLABEL" _cfg_budget_field 'Twin' 'budget_name')" "first matching entry wins on a duplicate label"
  assert_eq "true" "$(YNAB_CONFIG_FILE="$DUPLABEL" _cfg_budget_field 'Twin' 'write_back_enabled')" "boolean from the first entry only — never multi-line"
  assert_eq "1" "$(YNAB_CONFIG_FILE="$DUPLABEL" _cfg_budget_field 'Twin' 'budget_name' | wc -l | tr -d ' ')" "exactly one output line"
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

# unparseable (issue #283) — the budget helpers read the file through
# _migrate_config, a SECOND read path that does not go through _cfg, so it
# carries its own parse guard. Without it a corrupt config reads back as "no
# budgets": _cfg_default_budget would emit nothing and its caller would fall
# through to a default budget, which is the same silent fail-open as reading a
# missing file.
#
# The two fixtures cover both jq failure routes — a parse error and "no JSON
# value was ever produced" (a zero-byte file). Each helper must return non-zero
# AND emit nothing on stdout.
#
# Every helper call runs with `set +o pipefail`, and that is the whole point of
# the test rather than an aside. This FILE sets `pipefail`, and under it a
# `_migrate_config | jq …` pipeline would report _migrate_config's failure for
# free — so the assertions below would pass whether or not the helpers capture
# _migrate_config's output, and would prove nothing about the helpers themselves
# (verified: reverting the capture to a pipe leaves this file 7/7 green while
# pipefail is on). A sourced loader cannot assume the caller's shell options —
# only bin/report-writer.sh and bin/ynab-prune.sh set pipefail; a skill or
# slash-command running these helpers inline need not — so pipefail-off is the
# condition that actually discriminates the fix.
test_malformed_config_fails_closed() {
  local bad_parse="$SANDBOX/bad-parse.json" bad_empty="$SANDBOX/bad-empty.json"
  printf '{ "schema_version": 2, "budgets": [ }\n' > "$bad_parse"
  : > "$bad_empty"

  local bad out rc err
  for bad in "$bad_parse" "$bad_empty"; do
    rc=0; out="$(set +o pipefail; YNAB_CONFIG_FILE="$bad" _migrate_config 2>/dev/null)" || rc=$?
    [ "$rc" -ne 0 ] || fail "_migrate_config should fail closed on $(basename "$bad")"
    assert_eq "" "$out" "_migrate_config emits nothing for $(basename "$bad")"

    rc=0; out="$(set +o pipefail; YNAB_CONFIG_FILE="$bad" _cfg_budgets 2>/dev/null)" || rc=$?
    [ "$rc" -ne 0 ] || fail "_cfg_budgets should fail closed on $(basename "$bad") without pipefail, not report 'no budgets'"
    assert_eq "" "$out" "_cfg_budgets emits nothing for $(basename "$bad")"

    rc=0; out="$(set +o pipefail; YNAB_CONFIG_FILE="$bad" _cfg_budget_field 'Sandbox Business' 'role' 2>/dev/null)" || rc=$?
    [ "$rc" -ne 0 ] || fail "_cfg_budget_field should fail closed on $(basename "$bad") without pipefail"
    assert_eq "" "$out" "_cfg_budget_field emits nothing for $(basename "$bad")"

    rc=0; out="$(set +o pipefail; YNAB_CONFIG_FILE="$bad" _cfg_default_budget 2>/dev/null)" || rc=$?
    [ "$rc" -ne 0 ] || fail "_cfg_default_budget should fail closed on $(basename "$bad") without pipefail, not fall through to a default"
    assert_eq "" "$out" "_cfg_default_budget emits nothing for $(basename "$bad")"

    # The error names the file and says why — not a bare non-zero.
    err="$(set +o pipefail; YNAB_CONFIG_FILE="$bad" _cfg_budgets 2>&1 >/dev/null || true)"
    assert_contains "$err" "$bad"           "_cfg_budgets error names the config path for $(basename "$bad")"
    assert_contains "$err" "not valid JSON" "_cfg_budgets error says the file is not valid JSON for $(basename "$bad")"
  done
}

# A parseable config must still read normally with pipefail OFF — the capture
# rewrite must not have changed the success path. Without this, a "fix" that
# simply returned non-zero unconditionally would satisfy the fail-closed test
# above.
test_helpers_unchanged_without_pipefail() {
  local budgets
  budgets="$(set +o pipefail; YNAB_CONFIG_FILE="$MULTI" _cfg_budgets)"
  assert_eq "2" "$(jq 'length' <<<"$budgets")" "_cfg_budgets still reads both entries without pipefail"
  assert_eq "Sandbox Business" "$(set +o pipefail; YNAB_CONFIG_FILE="$MULTI" _cfg_default_budget | jq -r '.label')" \
    "_cfg_default_budget still resolves the default without pipefail"
  assert_eq "false" "$(set +o pipefail; YNAB_CONFIG_FILE="$MULTI" _cfg_budget_field 'Sandbox Business' 'write_back_enabled')" \
    "_cfg_budget_field still reads a boolean false without pipefail"
}

run_tests
