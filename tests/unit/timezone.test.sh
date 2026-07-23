#!/usr/bin/env bash
#
# tests/unit/timezone.test.sh — unit tests for the timezone helpers in
# bin/config.sh (issue #31): _is_valid_timezone, _cfg_timezone, _today_in_tz.
#
# These own `config.timezone`, the single source of truth for every
# date-sensitive review computation. The load-time gate must FAIL CLOSED on a
# missing/invalid zone (never silently fall back to the host clock), and
# "today" must be derived in the configured timezone so a scheduled run and an
# interactive run agree on the window and the tax-year label.
#
# Follows the repo harness convention (issue #4, tests/lib/assert.sh): raw bash
# with `set -euo pipefail`, sources tests/lib/assert.sh, defines `test_*`
# functions, ends with `run_tests`. scripts/test.sh auto-discovers it. Run this
# file alone with `scripts/test.sh tests/unit/timezone.test.sh` or directly with
# `bash tests/unit/timezone.test.sh`.
#
# The boundary epochs below are FIXED and were verified against the tz database
# (Phoenix is UTC-7 year-round — no DST — so the day differs from UTC by design):
#   E1 = 1773643800  → America/Phoenix 2026-03-15 23:50, UTC 2026-03-16 06:50
#   E2 = 1777617600  → America/Phoenix 2026-04-30 23:40, UTC 2026-05-01 06:40
#   E3 = 1798785600  → America/Phoenix 2026-12-31 23:40, UTC 2027-01-01 06:40
# _today_in_tz's $YNAB_NOW_EPOCH seam injects them, so the assertions never
# depend on the wall clock.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"

LOADER="$REPO_ROOT/bin/config.sh"
# shellcheck source=/dev/null
source "$LOADER"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# Three fixtures: a valid timezone, timezone absent, and a syntactically-fine but
# nonexistent zone. Each test points YNAB_CONFIG_FILE at the one it needs.
FIX_OK="$SANDBOX/ok.json"
cat > "$FIX_OK" <<'JSON'
{ "schema_version": 2, "timezone": "America/Phoenix" }
JSON
FIX_MISSING="$SANDBOX/missing.json"
cat > "$FIX_MISSING" <<'JSON'
{ "schema_version": 2 }
JSON
FIX_INVALID="$SANDBOX/invalid.json"
cat > "$FIX_INVALID" <<'JSON'
{ "schema_version": 2, "timezone": "Mars/Phobos" }
JSON

# Boundary epochs (see header).
E1=1773643800   # near-midnight day difference
E2=1777617600   # month boundary
E3=1798785600   # year / tax-year boundary

# ── _is_valid_timezone — the fail-closed predicate ────────────────────────────

test_is_valid_timezone_accepts_real_zones() {
  local tz
  for tz in America/Phoenix UTC America/New_York America/Argentina/Buenos_Aires; do
    _is_valid_timezone "$tz" || fail "expected accept: $tz"
  done
}

test_is_valid_timezone_rejects_bad_input() {
  # Each of these must be rejected — the discriminating cases behind "fail
  # closed". Removing any one guard in _is_valid_timezone regresses a line here.
  local tz
  for tz in \
    "" \
    "Mars/Phobos" \
    "Not_A_Zone" \
    "../etc/passwd" \
    "/etc/localtime" \
    "America/Phoenix/" \
    "America Phoenix" \
    "America/Phoenix;rm" \
    "America/Phoenix\$TZ"
  do
    if _is_valid_timezone "$tz"; then
      fail "expected reject but accepted: [$tz]"
    fi
  done
}

# Path-traversal to a file that ACTUALLY EXISTS outside the tz database must
# still be rejected — the discriminating case that -f alone can't catch (the
# target exists), so it isolates the traversal/char-class guard. Points TZ_DB_DIR
# at a sandbox zoneinfo whose parent holds a real "secret" file.
test_is_valid_timezone_blocks_traversal_to_real_file() {
  local zi="$SANDBOX/zi"
  mkdir -p "$zi"
  : > "$zi/Local_Zone"            # a real zone file inside the db
  : > "$SANDBOX/secret"           # a real file one level OUTSIDE the db
  # Consumed by the sourced _is_valid_timezone (cross-file), so shellcheck can't
  # see the read; each test runs in its own subshell so this never leaks.
  # shellcheck disable=SC2034
  TZ_DB_DIR="$zi"
  _is_valid_timezone "Local_Zone" || fail "sanity: a real in-db zone should be accepted"
  [ -f "$zi/../secret" ] || fail "sanity: the traversal target must really exist"
  if _is_valid_timezone "../secret"; then
    fail "traversal to a real out-of-db file was accepted"
  fi
}

# ── _cfg_timezone — the load-time gate ────────────────────────────────────────

test_cfg_timezone_valid_reads_back() {
  local out err
  out="$(YNAB_CONFIG_FILE="$FIX_OK" _cfg_timezone)"
  assert_eq "America/Phoenix" "$out" "_cfg_timezone echoes the configured zone"
  err="$(YNAB_CONFIG_FILE="$FIX_OK" _cfg_timezone 2>&1 1>/dev/null)"
  assert_eq "" "$err" "_cfg_timezone is silent on the happy path"
}

test_cfg_timezone_missing_fails_closed() {
  local err rc=0
  err="$(YNAB_CONFIG_FILE="$FIX_MISSING" _cfg_timezone 2>&1)" || rc=$?
  assert_eq "1" "$rc" "_cfg_timezone exits non-zero when timezone is absent"
  assert_contains "$err" "required" "error says timezone is required"
  assert_contains "$err" "/workbench-ynab:setup" "error points at setup"
  # Fail CLOSED: it must NOT emit a fallback zone on stdout.
  local out
  out="$(YNAB_CONFIG_FILE="$FIX_MISSING" _cfg_timezone 2>/dev/null)" || true
  assert_eq "" "$out" "_cfg_timezone emits no host-clock fallback on stdout"
}

test_cfg_timezone_invalid_fails_closed() {
  local err rc=0
  err="$(YNAB_CONFIG_FILE="$FIX_INVALID" _cfg_timezone 2>&1)" || rc=$?
  assert_eq "1" "$rc" "_cfg_timezone exits non-zero on an invalid zone"
  assert_contains "$err" "not a valid IANA" "error names the invalid-zone reason"
  assert_contains "$err" "Mars/Phobos" "error echoes the offending value"
}

# ── _today_in_tz — three boundary scenarios (AC #7) + determinism (AC #6) ──────

# (a) run within 30 min of midnight: the configured zone and UTC land on
# different calendar days — the day that decides 7-day-window inclusion.
test_today_near_midnight_day_boundary() {
  assert_eq "2026-03-15" "$(_today_in_tz America/Phoenix "$E1")" "Phoenix is still Mar 15 at 23:50"
  assert_eq "2026-03-16" "$(_today_in_tz UTC "$E1")"            "same instant is already Mar 16 in UTC"
}

# (b) run on the last/first day of a month: month-boundary detection differs.
test_today_month_boundary() {
  assert_eq "2026-04-30" "$(_today_in_tz America/Phoenix "$E2")" "Phoenix is the last day of April"
  assert_eq "2026-05-01" "$(_today_in_tz UTC "$E2")"            "same instant is May 1 in UTC"
}

# (c) run on Dec 31 / Jan 1: the tax-year label (leading year) differs — the
# case that feeds GAP-15's year-boundary behaviour.
test_today_year_boundary_tax_year() {
  local phx utc
  phx="$(_today_in_tz America/Phoenix "$E3")"
  utc="$(_today_in_tz UTC "$E3")"
  assert_eq "2026-12-31" "$phx" "Phoenix is still Dec 31, 2026"
  assert_eq "2027-01-01" "$utc" "same instant is Jan 1, 2027 in UTC"
  # The tax-year label is the calendar year of the authoritative today.
  assert_eq "2026" "$(printf '%s' "$phx" | cut -c1-4)" "tax-year label is 2026 in the configured zone"
  assert_eq "2027" "$(printf '%s' "$utc" | cut -c1-4)" "host-clock UTC would mislabel the tax year as 2027"
}

# AC #6 — a scheduled run and an interactive run at the SAME instant, both going
# through _today_in_tz with the same configured zone, agree on the date. The
# helper is a pure function of (tz, instant); the $YNAB_NOW_EPOCH seam pins the
# instant so this proves agreement rather than clock luck.
test_today_scheduled_equals_interactive() {
  local scheduled interactive
  scheduled="$(_today_in_tz America/Phoenix "$E3")"
  interactive="$(YNAB_NOW_EPOCH="$E3" _today_in_tz America/Phoenix)"
  assert_eq "$scheduled" "$interactive" "same instant + zone yields the same today via arg or env seam"
  assert_eq "2026-12-31" "$interactive" "and it is the configured-zone date, not the host-clock date"
}

run_tests
