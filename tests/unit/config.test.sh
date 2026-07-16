#!/usr/bin/env bash
#
# tests/unit/config.test.sh — unit tests for bin/config.sh, the skills/commands
# config loader.
#
# Follows the repo test-harness convention (issue #4, tests/lib/assert.sh): raw
# bash with `set -euo pipefail`, sources tests/lib/assert.sh, defines `test_*`
# functions, and ends with `run_tests`. scripts/test.sh auto-discovers it via the
# `*.test.sh` glob — run the whole suite with `scripts/test.sh`, this file alone
# with `scripts/test.sh tests/unit/config.test.sh`, or directly with
# `bash tests/unit/config.test.sh`.
#
# run_tests runs each test_* in an isolated subshell. The loader's documented
# test seam, YNAB_CONFIG_FILE, is injected per call as a command-prefix
# (`YNAB_CONFIG_FILE=... _cfg ...`) — the same idiom the sibling suites use — so
# each scenario points the loader at its own fixture without mutating a global or
# leaking into other tests. One mktemp sandbox + EXIT trap holds the fixtures for
# the whole run; the EXIT trap is reset inside run_tests' per-test subshells, so
# the sandbox survives until the file's main shell exits.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"

LOADER="$REPO_ROOT/bin/config.sh"
EXAMPLE="$REPO_ROOT/assets/config.example.json"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

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

# Source the loader once to define _cfg/_require_config. It only DEFINES those
# functions and the YNAB_CONFIG_FILE var (no side effects at load time); each
# test below overrides YNAB_CONFIG_FILE per call, so the loader's default path is
# never read.
# shellcheck source=/dev/null
source "$LOADER"

# present fields — _cfg returns the configured value.
test_present_fields() {
  assert_eq "Sandbox Budget" "$(YNAB_CONFIG_FILE="$FIXTURE" _cfg '.budget.name')"               "_cfg '.budget.name'"
  assert_eq "1"              "$(YNAB_CONFIG_FILE="$FIXTURE" _cfg '.schema_version')"             "_cfg '.schema_version'"
  assert_eq "single"         "$(YNAB_CONFIG_FILE="$FIXTURE" _cfg '.tax_profile.filing_status')" "_cfg '.tax_profile.filing_status'"
  assert_eq "C"              "$(YNAB_CONFIG_FILE="$FIXTURE" _cfg '.tax_profile.schedules[0]')"   "_cfg array element '.tax_profile.schedules[0]'"
  assert_eq "2"              "$(YNAB_CONFIG_FILE="$FIXTURE" _cfg '.tax_profile.schedules | length')" "_cfg jq filter '.tax_profile.schedules | length'"
}

# absent fields — _cfg returns empty (caller applies its own default).
test_absent_fields() {
  assert_eq "" "$(YNAB_CONFIG_FILE="$FIXTURE" _cfg '.report.output_dir')" "_cfg '.report.output_dir' (key absent)"
  assert_eq "" "$(YNAB_CONFIG_FILE="$FIXTURE" _cfg '.budget.id')"         "_cfg '.budget.id' (value is null)"
  assert_eq "" "$(YNAB_CONFIG_FILE="$FIXTURE" _cfg '.business.name')"     "_cfg '.business.name' (object absent)"
  # caller-side default kicks in when _cfg is empty
  local out_dir
  out_dir="$(YNAB_CONFIG_FILE="$FIXTURE" _cfg '.report.output_dir')"; out_dir="${out_dir:-/fallback/dir}"
  assert_eq "/fallback/dir" "$out_dir" "caller default applies on empty"
}

# config present — _require_config succeeds, emitting nothing on a zero exit.
test_require_config_present() {
  local err rc=0
  err="$(YNAB_CONFIG_FILE="$FIXTURE" _require_config 2>&1)" || rc=$?
  assert_eq "0" "$rc"  "_require_config exit code with config present"
  assert_eq "" "$err" "_require_config emits nothing when config present"
}

# config absent — guard errors, points at setup, non-zero exit.
test_require_config_absent() {
  local missing="$SANDBOX/does-not-exist.json" err rc=0
  err="$(YNAB_CONFIG_FILE="$missing" _require_config 2>&1)" || rc=$?
  assert_eq       "1" "$rc"  "_require_config exit code is non-zero"
  assert_contains "$err" "config not found"      "error names the missing path"
  assert_contains "$err" "/workbench-ynab:setup" "error points at /workbench-ynab:setup"
  assert_eq       "" "$(YNAB_CONFIG_FILE="$missing" _cfg '.budget.name')" "_cfg returns empty when config file is missing"
}

# jq absent — guard errors, names jq, non-zero exit.
test_jq_absent() {
  # Config file present, so the guard advances past the file check to the jq
  # check. Run with PATH pointed at an empty dir so `command -v jq` fails; the
  # command-substitution subshell confines the PATH change, leaving the rest of
  # the suite untouched. _require_config relies only on bash builtins, so it
  # still runs.
  local empty_bin err rc=0
  empty_bin="$SANDBOX/empty-bin"
  mkdir -p "$empty_bin"
  err="$(PATH="$empty_bin" YNAB_CONFIG_FILE="$FIXTURE" _require_config 2>&1)" || rc=$?
  assert_eq       "1" "$rc"               "_require_config exit code is non-zero when jq absent"
  assert_contains "$err" "jq is required" "error names jq as required"
  assert_contains "$err" "install jq"     "error tells the user to install jq"
}

# shipped example config reads through the loader.
test_example_config() {
  assert_file_exists "$EXAMPLE"
  assert_eq "2" "$(YNAB_CONFIG_FILE="$EXAMPLE" _cfg '.schema_version')" "example schema_version is the current schema version"
  # every required top-level key is present and reads back non-empty
  local path val
  for path in '.budgets[0].label' '.tax_profile.filing_status' '.persona.name' '.report.output_dir'; do
    val="$(YNAB_CONFIG_FILE="$EXAMPLE" _cfg "$path")"
    [ -n "$val" ] || fail "example $path empty"
  done
}

run_tests
