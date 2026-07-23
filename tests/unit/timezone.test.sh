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
  # Factory/posixrules/leapseconds/+VERSION are the zoneinfo housekeeping
  # artifacts that a bare `-f` existence check green-lit (issue #31): Factory
  # and posixrules are real TZif files (rejected by name — they map to UTC and
  # are not selectable zones), leapseconds and +VERSION are text files (rejected
  # by the TZif-magic gate). All four resolve to a silent host-clock-equivalent
  # date if accepted, so they must fail closed on ANY host — whether the file is
  # present (magic/name reject) or absent (`-f` reject).
  # factory/FACTORY (case-fold, resolvable on a case-insensitive FS) and
  # right/Factory (the leap-second mirror subtree) are the round-3 bypass vectors
  # of the same pseudo-zone class — rejected case-insensitively and by subtree.
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
    "America/Phoenix\$TZ" \
    "Factory" \
    "posixrules" \
    "leapseconds" \
    "+VERSION" \
    "factory" \
    "FACTORY" \
    "right/Factory"
  do
    if _is_valid_timezone "$tz"; then
      fail "expected reject but accepted: [$tz]"
    fi
  done
}

# Deterministic, host-independent proof that the final gate is a TZif check and
# not a bare `-f` existence check (issue #31, review round 2). Points TZ_DB_DIR
# at a sandbox holding: a genuine TZif zone (accepted), a text housekeeping file
# whose name would sail through the char-class guard (rejected by the magic
# check — the case `-f` alone can't catch), and a real TZif file named `Factory`
# (rejected by name even though its magic is valid). Dropping the TZif-magic
# gate makes the housekeeping case pass; dropping the Factory name-guard makes
# the pseudo-zone case pass — each regresses a line here.
test_is_valid_timezone_rejects_non_tzif_artifacts() {
  local zi="$SANDBOX/zi2"
  mkdir -p "$zi"
  printf 'TZif2\0\0\0' > "$zi/Real_Zone"        # a genuine compiled-zone signature
  printf '# not a zone, just leap-second text\n' > "$zi/Housekeeping"
  printf 'TZif2\0\0\0' > "$zi/Factory"          # real TZif magic, but a build artifact
  # shellcheck disable=SC2034
  TZ_DB_DIR="$zi"
  _is_valid_timezone "Real_Zone" || fail "a TZif zone file must be accepted"
  if _is_valid_timezone "Housekeeping"; then
    fail "a non-TZif housekeeping file was accepted (the -f-only leak)"
  fi
  if _is_valid_timezone "Factory"; then
    fail "the Factory pseudo-zone was accepted despite valid TZif magic"
  fi
}

# Deterministic, host-independent proof that the pseudo-zone deny-list closes the
# round-3 leak (issue #31): a case-insensitive filesystem resolves `factory` /
# `FACTORY` to the real `Factory` TZif file, and the `right/`/`posix/` leap-second
# mirror subtrees expose `right/Factory` — all UTC-equivalent pseudo-zones that a
# bare TZif-magic gate would green-light. Points TZ_DB_DIR at a sandbox holding a
# real (TZif-magic) file at each of those paths and asserts every one is rejected,
# while a genuine zone is still accepted. Dropping the case-fold on the name deny
# re-accepts factory/FACTORY; dropping the right/posix-prefix reject re-accepts
# the mirror zones — each regresses a line here, on ANY host (case-sensitive CI
# included, where the files exist under those exact names).
test_is_valid_timezone_rejects_case_and_mirror_pseudozones() {
  local zi="$SANDBOX/zi3"
  mkdir -p "$zi/right" "$zi/posix"
  printf 'TZif2\0\0\0' > "$zi/factory"           # lowercase pseudo-zone (case-fold vector)
  printf 'TZif2\0\0\0' > "$zi/FACTORY"           # uppercase pseudo-zone (collapses to the same inode on a case-insensitive FS)
  printf 'TZif2\0\0\0' > "$zi/right/Factory"     # leap-second mirror pseudo-zone
  printf 'TZif2\0\0\0' > "$zi/posix/Factory"     # POSIX-TZ mirror pseudo-zone
  printf 'TZif2\0\0\0' > "$zi/right/Real_Zone"   # mirror duplicate of a REAL zone — only the right/ subtree reject catches it (basename isn't a pseudo-zone)
  printf 'TZif2\0\0\0' > "$zi/posix/Real_Zone"   # POSIX-TZ mirror duplicate of a real zone
  printf 'TZif2\0\0\0' > "$zi/Real_Zone"         # sanity control: a genuine TZif zone stays accepted
  # shellcheck disable=SC2034
  TZ_DB_DIR="$zi"
  local tz
  # factory/FACTORY discriminate the case-fold on the name deny; right/posix/*
  # discriminate the mirror-subtree reject — right/Real_Zone in particular is NOT
  # caught by the basename deny, so it fails only if the subtree guard is present.
  for tz in factory FACTORY right/Factory posix/Factory right/Real_Zone posix/Real_Zone; do
    if _is_valid_timezone "$tz"; then
      fail "pseudo-zone bypass accepted despite valid TZif magic: [$tz]"
    fi
  done
  _is_valid_timezone "Real_Zone" || fail "sanity: a real TZif zone must still be accepted"
}

# Path-traversal to a file that ACTUALLY EXISTS outside the tz database must
# still be rejected — proving the rejection comes from the traversal/char-class
# guard (which fires on the `.` before the file lookup ever runs), not merely
# from a nonexistent target. Points TZ_DB_DIR at a sandbox zoneinfo whose parent
# holds a real "secret" file.
test_is_valid_timezone_blocks_traversal_to_real_file() {
  local zi="$SANDBOX/zi"
  mkdir -p "$zi"
  printf 'TZif2\0\0\0' > "$zi/Local_Zone"   # a real (TZif-magic) zone file inside the db
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
  # Fail CLOSED: as with the missing-zone sibling, isolate stdout so a stray
  # host-clock fallback on the invalid path would be caught here too.
  local out
  out="$(YNAB_CONFIG_FILE="$FIX_INVALID" _cfg_timezone 2>/dev/null)" || true
  assert_eq "" "$out" "_cfg_timezone emits no host-clock fallback on stdout for an invalid zone"
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

# The no-override production branch — `TZ="$tz" date +%Y-%m-%d`, the one every
# command actually calls — is otherwise never exercised: every assertion above
# injects an epoch, so dropping `TZ=` (or deleting the branch) would leave the
# suite green. The earlier version pinned `_today_in_tz UTC` against `date -u`,
# but the `test` CI job runs on `ubuntu-latest` with an ambient `TZ=UTC`, so the
# configured zone and the host clock were the SAME value there — the test could
# not tell "TZ applied" from "TZ dropped" (verified: stripping `TZ=` still passed
# 12/12 under TZ=UTC). Pin against a FAR-OFFSET zone (Pacific/Kiritimati, UTC+14)
# and its own independent `TZ=… date` read instead: for correct code the two
# always agree, while a dropped `TZ=` makes `got` the host-clock date, which
# differs from the Kiritimati date for the 14 h/day the two calendars diverge —
# so the regression is now catchable on the UTC host that gates this PR, not just
# on a non-UTC dev box. Bracketing tolerates a midnight tick between the reads.
test_today_no_epoch_uses_passed_zone_not_host_clock() {
  local tz="Pacific/Kiritimati"   # UTC+14 — the farthest-forward zone, so its date differs from the UTC CI host most of the day
  local before got after
  before="$(TZ="$tz" date +%Y-%m-%d)"
  got="$(YNAB_NOW_EPOCH='' _today_in_tz "$tz")"   # empty seam → the live-clock branch
  after="$(TZ="$tz" date +%Y-%m-%d)"
  if [ "$got" != "$before" ] && [ "$got" != "$after" ]; then
    fail "_today_in_tz $tz live-clock branch gave '$got', expected the $tz date '$before'/'$after' — the passed zone did not drive the result"
  fi
}

run_tests
