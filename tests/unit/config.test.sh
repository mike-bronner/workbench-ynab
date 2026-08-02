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
  # timezone (issue #31): required, present, and a valid IANA zone that reads
  # back through the fail-closed gate rather than merely as raw text.
  val="$(YNAB_CONFIG_FILE="$EXAMPLE" _cfg '.timezone')"
  [ -n "$val" ] || fail "example .timezone empty"
  _is_valid_timezone "$val" || fail "example .timezone is not a valid IANA zone: $val"
  assert_eq "$val" "$(YNAB_CONFIG_FILE="$EXAMPLE" _cfg_timezone)" "example timezone reads through _cfg_timezone"
}

# _cfg_tax_year — the OPTIONAL active-tax-year override (issue #17).
#
# Three distinct outcomes, each pinned separately: absent (echo nothing, succeed —
# the caller derives the year from the review date), valid (echo it), malformed
# (fail closed). The malformed cases matter most: silently ignoring a bad value
# would report a different year than the user asked for, with no signal at all.
test_cfg_tax_year() {
  local cfg="$SANDBOX/tax-year.json"

  # Absent -> empty output, exit 0. The absence is NOT an error; it is the default.
  printf '{ "timezone": "UTC" }\n' > "$cfg"
  assert_eq "" "$(YNAB_CONFIG_FILE="$cfg" _cfg_tax_year)" "_cfg_tax_year with the key absent"
  YNAB_CONFIG_FILE="$cfg" _cfg_tax_year >/dev/null 2>&1 \
    || fail "_cfg_tax_year should succeed when tax_year is absent"

  # An EXPLICIT null reads the same as an absent key — both mean "no override".
  # Pinned separately from the absent case because the two reach that answer by
  # different routes, and only this one proves an explicit null is not treated as
  # a malformed value once the guard stops keying on the rendered text.
  printf '{ "timezone": "UTC", "tax_year": null }\n' > "$cfg"
  assert_eq "" "$(YNAB_CONFIG_FILE="$cfg" _cfg_tax_year)" "_cfg_tax_year with an explicit null"
  YNAB_CONFIG_FILE="$cfg" _cfg_tax_year >/dev/null 2>&1 \
    || fail "_cfg_tax_year should succeed when tax_year is null"

  # Present and well-formed -> echoed verbatim.
  printf '{ "timezone": "UTC", "tax_year": 2031 }\n' > "$cfg"
  assert_eq "2031" "$(YNAB_CONFIG_FILE="$cfg" _cfg_tax_year)" "_cfg_tax_year with a valid year"

  # Malformed -> non-zero AND no value on stdout, so a caller using
  # `year="$(_cfg_tax_year)" || exit 1` stops instead of proceeding on a bad year.
  #
  # The table covers every falsy value the JSON types permit, because a guard
  # keyed on the RENDERED value rather than the JSON type swallows some of them:
  #   * false — jq's `//` discards it exactly like null, so it read as "unset"
  #   * ""    — `jq -r` renders it as an empty line, so it read as "unset"
  #   * 0     — survives both, and was already rejected by the four-digit check
  # The first two each independently return 0 with no override and no error under
  # a value-first guard (verified by reverting the guard); `0` is a boundary pin,
  # not a past defect.
  local bad
  for bad in '"2031"' '203' '20311' '2031.5' 'true' 'false' '0' '""' '"twenty"' '[]' '{}'; do
    printf '{ "timezone": "UTC", "tax_year": %s }\n' "$bad" > "$cfg"
    if YNAB_CONFIG_FILE="$cfg" _cfg_tax_year >/dev/null 2>&1; then
      fail "_cfg_tax_year should fail closed on tax_year=$bad"
    fi
    assert_eq "" "$(YNAB_CONFIG_FILE="$cfg" _cfg_tax_year 2>/dev/null || true)" \
      "_cfg_tax_year emits nothing on stdout for tax_year=$bad"
  done

  # The error is descriptive and names the offending key, not a bare non-zero.
  printf '{ "timezone": "UTC", "tax_year": "2031" }\n' > "$cfg"
  local err
  err="$(YNAB_CONFIG_FILE="$cfg" _cfg_tax_year 2>&1 >/dev/null || true)"
  case "$err" in
    *tax_year*) : ;;
    *) fail "_cfg_tax_year error should name config.tax_year, got: $err" ;;
  esac
}

run_tests
