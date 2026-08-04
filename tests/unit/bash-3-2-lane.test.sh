#!/usr/bin/env bash
#
# tests/unit/bash-3-2-lane.test.sh — keeps ci.yml's `bash-3-2` job honest
# (issue #231).
#
# The lane runs an explicit, closed file list rather than `scripts/test.sh`
# auto-discovery, because the full suite is not known to be 3.2-safe end to end.
# The cost of that choice is drift: a hand-kept enumeration omits every NEW
# 3.2/BSD-relevant test file by default, which is how bin/ynab-prune.sh,
# bin/path-expand.sh, and the secret-scan guard stayed Linux-only after landing.
#
# So membership is declared at the file that needs it — a marker line in the
# test file's own header — and THIS test is what makes the marker binding:
#
#   * every test file carrying the marker is listed in the lane's run: step;
#   * every file listed in the lane's run: step carries the marker;
#   * docs/ci.md's job table and local-repro command name the same set.
#
# Forget to add a marked file to the lane and CI fails in the PR that adds it,
# instead of the file silently never running on macOS. Removing a file from the
# lane means deleting its marker AND its list entries — deliberate, and visible
# in the diff.
#
# This file itself is NOT a lane member: it is a static contract check over
# workflow and doc text (the repo-idiomatic shape, cf.
# tests/unit/ci-gate-hardening.test.sh and tests/unit/release-workflow.test.sh),
# with no platform-dependent behaviour to prove.
#
# Harness convention (issue #4): raw bash, sources tests/lib/assert.sh,
# test_* functions, run_tests. scripts/test.sh auto-discovers this file.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"

CI_YML="$REPO_ROOT/.github/workflows/ci.yml"
CI_DOC="$REPO_ROOT/docs/ci.md"
TESTING_DOC="$REPO_ROOT/docs/testing.md"
SECRET_SCAN_YML="$REPO_ROOT/.github/workflows/secret-scan.yml"

# The marker regex, kept in one place. Written as a variable (never as a literal
# at the start of a comment line in this file) so the guard does not match
# itself when it scans tests/.
MARKER_RE='^# bash-3\.2-lane:'

# --- extraction ---------------------------------------------------------------

# lane_block — just the `bash-3-2:` job's YAML, from its key to the next
# top-level job key. Job keys sit at 2-space indent; every line inside the job
# is indented further (or is a 2-space-indented comment), so "column 3 holds a
# non-space, non-#" is exactly the "next job starts here" signal.
lane_block() {
  awk '
    /^  bash-3-2:/ { inblock = 1; next }
    inblock && /^  [^[:space:]#]/ { inblock = 0 }
    inblock
  ' "$CI_YML"
}

# lane_run_line — the lane step that invokes the suite runner.
lane_run_line() {
  lane_block | grep -E '^[[:space:]]*run: bash scripts/test\.sh' || true
}

# files_after_runner <line> — the whitespace-separated arguments following
# `scripts/test.sh` on a runner invocation, one per line, sorted.
files_after_runner() {
  printf '%s\n' "$1" \
    | sed -E 's|^.*scripts/test\.sh||' \
    | tr '[:space:]' '\n' \
    | sed '/^$/d' \
    | sort
}

# lane_files — the lane's explicit file list, sorted.
lane_files() {
  files_after_runner "$(lane_run_line)"
}

# marked_files — every file under tests/ carrying the lane marker, sorted,
# repo-root-relative.
marked_files() {
  ( cd "$REPO_ROOT" && grep -rl -- "$MARKER_RE" tests | sort )
}

# doc_repro_line — docs/ci.md's copy-pasteable local reproduction of the lane.
doc_repro_line() {
  # shellcheck disable=SC2016 # `$PATH` is literal text in the documented command
  grep -E '^PATH="/bin:\$PATH" bash scripts/test\.sh ' "$CI_DOC" || true
}

# doc_table_row — the `bash-3-2` row of the job table in docs/ci.md. Scoped to
# the row on purpose: every lane filename also appears elsewhere in the document
# (the repro command, the prose), so a whole-file grep would pass even if the
# row named the wrong set.
doc_table_row() {
  # shellcheck disable=SC2016 # the backticks are literal markdown, not a subshell
  grep -F '| `bash-3-2` |' "$CI_DOC" || true
}

# require_nonempty <list> <label> — every check below iterates a list extracted
# from a file. An extraction that silently yields nothing would make its loop
# body run zero times and the test pass having asserted nothing, so each looping
# test states its non-emptiness precondition rather than relying on a sibling
# test to notice.
require_nonempty() {
  [ -n "$1" ] || fail "$2 came back empty — the check below would assert nothing"
}

# The files whose lane membership is itself an acceptance criterion of the issue
# that put them there (#231 for the original six; #270 for the scanning-grep pin,
# whose behavioural cases only discriminate on the macOS runner's BSD grep).
# Pinned BY NAME as well as by set-equality below: set-equality alone is
# satisfied by dropping a file from the marker AND the lane at the same time,
# which is exactly the regression this guard exists to stop.
REQUIRED_MEMBERS='tests/persona-loader.test.sh
tests/secret-scan.test.sh
tests/unit/grep-locale-pin.test.sh
tests/unit/html-escape.test.sh
tests/unit/report-writer.test.sh
tests/unit/watchdog.test.sh
tests/unit/ynab-prune.test.sh'

# --- the lane list is real, explicit, and closed -------------------------------

test_lane_step_exists() {
  local line
  line="$(lane_run_line)"
  [ -n "$line" ] || fail "ci.yml's bash-3-2 job has no 'run: bash scripts/test.sh …' step"
}

test_lane_list_is_explicit_not_auto_discovery() {
  # A bare `bash scripts/test.sh` would run the WHOLE suite on the macOS runner
  # — the auto-discovery this lane deliberately does not use. It yields zero
  # arguments, so a non-empty argument list is the check.
  local n
  n="$(lane_files | wc -l | tr -d '[:space:]')"
  [ "$n" -gt 0 ] || fail "the bash-3-2 lane passes no file arguments — it must run an explicit, closed list, not scripts/test.sh auto-discovery"
}

test_every_lane_file_exists_and_is_a_bash_test() {
  local f
  require_nonempty "$(lane_files)" "the bash-3-2 lane's file list"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    assert_file_exists "$REPO_ROOT/$f"
    case "$f" in
      *.test.sh) : ;;
      *) fail "bash-3-2 lane entry is not a *.test.sh file: $f" ;;
    esac
  done <<EOF
$(lane_files)
EOF
}

# --- the marker convention is binding in both directions -----------------------

test_marked_files_and_lane_list_agree() {
  # The whole point of the convention: writing the marker is what puts a file in
  # the lane. Any disagreement — a marked file missing from ci.yml, or a lane
  # entry with no marker — fails here, in the PR that introduced it.
  assert_eq "$(marked_files)" "$(lane_files)" \
    "the set of files carrying the bash-3.2 lane marker must equal the bash-3-2 job's file list in ci.yml"
}

test_every_marker_states_a_reason() {
  local f line
  require_nonempty "$(marked_files)" "the set of files carrying the lane marker"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    line="$(grep -E -- "$MARKER_RE" "$REPO_ROOT/$f" | head -1)"
    # Everything after the colon must be more than whitespace: the marker
    # documents WHY a file needs a real 3.2/BSD runner, not just that it does.
    case "$(printf '%s' "${line#*:}" | tr -d '[:space:]')" in
      '') fail "$f carries the lane marker with no reason after the colon" ;;
    esac
  done <<EOF
$(marked_files)
EOF
}

test_required_members_are_in_the_lane() {
  local f lane
  lane="$(lane_files)"
  while IFS= read -r f; do
    assert_exact_line "$lane" "$f" \
      "$f must run in the bash-3-2 lane (issue #231 acceptance criteria)"
  done <<EOF
$REQUIRED_MEMBERS
EOF
}

test_required_members_carry_the_marker() {
  local f marked
  marked="$(marked_files)"
  while IFS= read -r f; do
    assert_exact_line "$marked" "$f" \
      "$f must declare its lane membership with the bash-3.2 lane marker in its header"
  done <<EOF
$REQUIRED_MEMBERS
EOF
}

# --- docs/ci.md names the same set ---------------------------------------------

test_doc_repro_command_matches_the_lane() {
  local doc_line
  doc_line="$(doc_repro_line)"
  [ -n "$doc_line" ] || fail "docs/ci.md has no bash-3-2 local-repro command of the documented shape"
  assert_eq "$(lane_files)" "$(files_after_runner "$doc_line")" \
    "docs/ci.md's local-repro command must run exactly the lane's file list"
}

test_doc_table_row_names_every_lane_file() {
  local row f
  row="$(doc_table_row)"
  [ -n "$row" ] || fail "docs/ci.md's job table has no bash-3-2 row"
  require_nonempty "$(lane_files)" "the bash-3-2 lane's file list"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    assert_contains "$row" "$f" \
      "docs/ci.md's bash-3-2 table row must name $f"
  done <<EOF
$(lane_files)
EOF
}

test_doc_documents_the_marker_convention() {
  # shellcheck disable=SC2016 # the backticks are literal markdown, not a subshell
  assert_contains "$(cat "$CI_DOC")" \
    '**`bash-3-2` membership is a marker convention, enforced by a test.**' \
    "docs/ci.md must document how a file joins the lane, so a new 3.2-targeted test is added in its own PR"
  assert_contains "$(cat "$CI_DOC")" 'tests/unit/bash-3-2-lane.test.sh' \
    "docs/ci.md must name the guard that enforces the convention"
}

test_testing_doc_tells_contributors_how_to_join_the_lane() {
  # docs/ci.md explains the lane to someone reading about CI; docs/testing.md is
  # what someone WRITING a new test reads, so the how-to has to live there too or
  # the convention is documented where nobody will look for it.
  local doc
  doc="$(cat "$TESTING_DOC")"
  assert_contains "$doc" '## How to: put a new test in the bash-3.2 lane' \
    "docs/testing.md must tell a test author how to join the bash-3.2 lane"
  assert_contains "$doc" 'bash-3.2-lane:' \
    "docs/testing.md's how-to must show the marker syntax verbatim"
  assert_contains "$doc" 'tests/unit/bash-3-2-lane.test.sh' \
    "docs/testing.md must name the guard that catches a half-declared lane member"
}

# --- secret-scan.yml's ubuntu-only posture is deliberate and documented ---------

test_secret_scan_workflow_is_still_ubuntu_only() {
  # If a macOS leg is ever added, the documented rationale below stops being
  # true and must be rewritten — so pin the current posture rather than let the
  # doc and the workflow drift apart silently.
  assert_contains "$(cat "$SECRET_SCAN_YML")" 'runs-on: ubuntu-latest' \
    "secret-scan.yml's job runner should still be ubuntu-latest"
}

test_secret_scan_bsd_coverage_runs_in_the_lane() {
  # The substance of the ubuntu-only decision: bin/secret-scan.sh's grep rules
  # get their BSD execution from the macOS runner the repo already pays for.
  assert_exact_line "$(lane_files)" 'tests/secret-scan.test.sh' \
    "the secret-scan guard's BSD coverage depends on its self-test running in the bash-3-2 lane"
}

test_doc_documents_the_secret_scan_runner_decision() {
  # shellcheck disable=SC2016 # the backticks are literal markdown, not a subshell
  assert_contains "$(cat "$CI_DOC")" \
    '**`secret-scan.yml` stays `ubuntu-latest`; the BSD half runs in `bash-3-2`.**' \
    "docs/ci.md must record why secret-scan.yml is not run on macOS and where the BSD coverage lives instead"
}

run_tests
