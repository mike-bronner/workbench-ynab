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

# --- unparseable config (issue #283) ----------------------------------------
#
# A config.json that is present but does NOT parse must fail closed, not read
# back as "no fields set". The four fixtures cover both jq failure routes:
# a parse error (truncated, trailing comma, bare word) and "no JSON value was
# ever produced" (a zero-byte file, which `jq empty` would accept silently).
#
# Each fixture gets its own path rather than reusing one, so a failing case is
# named in the message and can be re-run in isolation.
BAD_TRUNCATED="$SANDBOX/bad-truncated.json"
printf '{ "timezone": "UTC", "tax_year": 2031\n' > "$BAD_TRUNCATED"

BAD_TRAILING_COMMA="$SANDBOX/bad-trailing-comma.json"
printf '{ "timezone": "UTC", "tax_year": 2031, }\n' > "$BAD_TRAILING_COMMA"

BAD_NOT_JSON="$SANDBOX/bad-not-json.json"
printf 'this is not json at all\n' > "$BAD_NOT_JSON"

BAD_EMPTY="$SANDBOX/bad-empty.json"
: > "$BAD_EMPTY"

# _cfg — every malformed fixture returns non-zero, names the file on stderr, and
# emits NOTHING on stdout, so a caller reading `"${value:-default}"` cannot mistake
# a corrupt file for an unset field.
test_cfg_malformed_config_fails_closed() {
  local bad out err rc
  for bad in "$BAD_TRUNCATED" "$BAD_TRAILING_COMMA" "$BAD_NOT_JSON" "$BAD_EMPTY"; do
    rc=0
    out="$(YNAB_CONFIG_FILE="$bad" _cfg '.timezone' 2>/dev/null)" || rc=$?
    [ "$rc" -ne 0 ] || fail "_cfg should return non-zero on $(basename "$bad")"
    assert_eq "" "$out" "_cfg emits nothing on stdout for $(basename "$bad")"

    err="$(YNAB_CONFIG_FILE="$bad" _cfg '.timezone' 2>&1 >/dev/null || true)"
    assert_contains "$err" "$bad"           "_cfg error names the config path for $(basename "$bad")"
    assert_contains "$err" "not valid JSON" "_cfg error says the file is not valid JSON for $(basename "$bad")"
  done
}

# _require_config — same four fixtures. It advances past its file-exists and
# jq-available checks (both hold here) and stops on the parse check, with wording
# distinct from those two messages so the user is pointed at the right repair.
test_require_config_malformed_fails_closed() {
  local bad err rc
  for bad in "$BAD_TRUNCATED" "$BAD_TRAILING_COMMA" "$BAD_NOT_JSON" "$BAD_EMPTY"; do
    rc=0
    err="$(YNAB_CONFIG_FILE="$bad" _require_config 2>&1)" || rc=$?
    [ "$rc" -ne 0 ] || fail "_require_config should return non-zero on $(basename "$bad")"
    assert_contains "$err" "$bad"           "_require_config error names the config path for $(basename "$bad")"
    assert_contains "$err" "not valid JSON" "_require_config error states the JSON is invalid for $(basename "$bad")"
    # Distinct from the other two guard messages — a corrupt file is neither an
    # absent file nor an absent jq, and must not be reported as either.
    case "$err" in
      *"config not found"*) fail "_require_config reported a corrupt file as missing: $(basename "$bad")" ;;
      *"jq is required"*)   fail "_require_config reported a corrupt file as missing jq: $(basename "$bad")" ;;
    esac
  done
}

# The three LEGITIMATE empties keep the old contract exactly: empty stdout,
# return 0, and nothing on stderr. That is what makes a non-zero _cfg mean one
# thing only — the file is present and does not parse. Pinned here as exit codes
# and stderr, which the pre-existing test_absent_fields / test_jq_absent /
# test_require_config_absent cases (kept unchanged above) do not assert.
test_cfg_legitimate_empties_succeed_silently() {
  local missing="$SANDBOX/does-not-exist.json" empty_bin out err rc
  empty_bin="$SANDBOX/empty-bin-legit"
  mkdir -p "$empty_bin"

  # 1. config file missing
  rc=0; err="$(YNAB_CONFIG_FILE="$missing" _cfg '.timezone' 2>&1 >/dev/null)" || rc=$?
  assert_eq "0" "$rc" "_cfg returns 0 when the config file is missing"
  assert_eq "" "$err" "_cfg is silent on stderr when the config file is missing"

  # 2. jq unavailable — PATH pointed at an empty dir, confined to the subshell.
  rc=0; err="$(PATH="$empty_bin" YNAB_CONFIG_FILE="$FIXTURE" _cfg '.timezone' 2>&1 >/dev/null)" || rc=$?
  assert_eq "0" "$rc" "_cfg returns 0 when jq is unavailable"
  assert_eq "" "$err" "_cfg is silent on stderr when jq is unavailable"
  out="$(PATH="$empty_bin" YNAB_CONFIG_FILE="$FIXTURE" _cfg '.timezone' 2>/dev/null || true)"
  assert_eq "" "$out" "_cfg emits nothing on stdout when jq is unavailable"

  # 3. field absent / explicitly null in a file that parses fine
  rc=0; err="$(YNAB_CONFIG_FILE="$FIXTURE" _cfg '.report.output_dir' 2>&1 >/dev/null)" || rc=$?
  assert_eq "0" "$rc" "_cfg returns 0 when the field is absent"
  assert_eq "" "$err" "_cfg is silent on stderr when the field is absent"
  rc=0; err="$(YNAB_CONFIG_FILE="$FIXTURE" _cfg '.budget.id' 2>&1 >/dev/null)" || rc=$?
  assert_eq "0" "$rc" "_cfg returns 0 when the field is explicitly null"
  assert_eq "" "$err" "_cfg is silent on stderr when the field is explicitly null"
}

# A file whose whole content is a valid JSON scalar still PARSES, so it must not
# trip the new guard — the check keys on "did it parse", never on the value's
# truthiness. `null` and `false` are the two a value-keyed check (`jq -e .`, whose
# status is 1 for both) would misreport as corrupt; `0` and `""` are the rest of
# the falsy set, and `[]`/`{}` are the empty containers.
#
# The assertion is on _require_config's status and on the ABSENCE of the
# invalid-JSON message, not on _cfg's status: indexing a non-object with
# `.timezone` is a jq FILTER error (exit 5) for `false`/`0`/`""`/`[]`, which is
# pre-existing behaviour and a different failure from the parse guard. Pinning
# _cfg's status here would assert the wrong thing; pinning the message proves the
# parse guard itself stayed out of the way.
test_cfg_valid_json_scalars_are_not_parse_failures() {
  local scalar cfg="$SANDBOX/scalar.json" rc err
  for scalar in 'null' 'false' '0' '""' '[]' '{}'; do
    printf '%s\n' "$scalar" > "$cfg"
    rc=0; YNAB_CONFIG_FILE="$cfg" _require_config >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "_require_config treats a whole-file '$scalar' as parseable, not corrupt"
    err="$(YNAB_CONFIG_FILE="$cfg" _cfg '.timezone' 2>&1 >/dev/null || true)"
    case "$err" in
      *"not valid JSON"*) fail "_cfg reported a whole-file '$scalar' as unparseable JSON" ;;
    esac
  done
  # The two scalars an object path can actually be applied to also keep _cfg's
  # zero-status, empty-output contract — proving the guard is transparent on a
  # parseable file, not merely quiet.
  for scalar in 'null' '{}'; do
    printf '%s\n' "$scalar" > "$cfg"
    rc=0; YNAB_CONFIG_FILE="$cfg" _cfg '.timezone' >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "_cfg returns 0 for a whole-file '$scalar'"
    assert_eq "" "$(YNAB_CONFIG_FILE="$cfg" _cfg '.timezone')" "_cfg emits nothing for a whole-file '$scalar'"
  done
}

# End-to-end through real readers, not _cfg in isolation: both fail-closed
# _cfg_* readers must ERROR on a malformed file rather than report their field as
# absent and hand the caller a default.
#
# _cfg_tax_year is the sharper of the two — its absent case is a SUCCESS (the
# caller derives the year from the review date), so a corrupt file reading as
# "absent" would silently produce a different tax year with a zero exit and no
# message at all. _cfg_timezone already fails on empty, so this pins that it
# fails for the RIGHT reason: the parse error, not "timezone missing".
test_cfg_readers_fail_closed_on_malformed_config() {
  local bad err rc out
  for bad in "$BAD_TRUNCATED" "$BAD_TRAILING_COMMA" "$BAD_NOT_JSON" "$BAD_EMPTY"; do
    rc=0
    out="$(YNAB_CONFIG_FILE="$bad" _cfg_tax_year 2>/dev/null)" || rc=$?
    [ "$rc" -ne 0 ] || fail "_cfg_tax_year should fail closed on $(basename "$bad"), not report 'no override'"
    assert_eq "" "$out" "_cfg_tax_year emits nothing on stdout for $(basename "$bad")"

    rc=0
    out="$(YNAB_CONFIG_FILE="$bad" _cfg_timezone 2>/dev/null)" || rc=$?
    [ "$rc" -ne 0 ] || fail "_cfg_timezone should fail closed on $(basename "$bad")"
    assert_eq "" "$out" "_cfg_timezone emits nothing on stdout for $(basename "$bad")"

    err="$(YNAB_CONFIG_FILE="$bad" _cfg_timezone 2>&1 >/dev/null || true)"
    assert_contains "$err" "not valid JSON" "_cfg_timezone reports the parse failure, not 'timezone missing', for $(basename "$bad")"
    case "$err" in
      *"config.timezone is required"*) fail "_cfg_timezone blamed a missing timezone on a corrupt file: $(basename "$bad")" ;;
    esac
  done
}

run_tests
