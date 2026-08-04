#!/usr/bin/env bash
#
# tests/unit/watchdog.test.sh — unit tests for tests/lib/watchdog.sh, the shared
# poll-and-kill timeout helper (issue #188).
#
# Follows the repo test-harness convention (tests/lib/assert.sh): raw bash with
# `set -euo pipefail`, sources tests/lib/assert.sh, defines `test_*` functions,
# ends with `run_tests`. scripts/test.sh auto-discovers it via the `*.test.sh`
# glob.
#
# bash-3.2-lane: the watchdog's process-group kill is job-control behaviour, and
# job control differs across bash majors — the TIMEOUT path must be proven on
# macOS's bash 3.2, not only on the ubuntu runner's bash 5.x (issue #188).
#
# The headline test is test_timeout_reaps_command_substitution_grandchild: it
# pins the ACTUAL bug — a killed watchdog used to strand the grandchild doing the
# expensive work. Because all four call sites (persona-loader's render_tmpl_timed
# and run_voice_timed, html-escape's escape_timed, report-writer's overlong
# output-dir guard) now route their kill through watchdog_run, pinning the helper
# pins every site at once.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/watchdog.sh"
# The ticking payload + the "no descendant survived" assertion, shared with the
# four per-call-site orphan tests (issue #251) so all five use ONE fixture.
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/orphan-probe.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# ---- fixtures ---------------------------------------------------------------

# The grandchild ticker lives in tests/lib/orphan-probe.sh as
# orphan_probe_tick_forever: a payload shaped like the real call sites, whose
# expensive non-terminating work runs inside a NESTED COMMAND SUBSTITUTION so it
# is a grandchild of the subshell watchdog_run backgrounds. It ticks a marker
# file so liveness stays observable from the parent after the kill.

# Pass-path payloads. Defined at top level (like the fixtures above) rather than
# inside their test_* functions so shellcheck can see they are real definitions;
# nested ones trip SC2329 because watchdog_run invokes them indirectly, by name.
emit_ok()   { printf 'payload-stdout'; return 0; }
emit_err()  { printf 'payload-stderr' >&2; return 0; }
exit_two()  { return 2; }

# ---- the regression this file exists for ------------------------------------

# #188: the pre-fix idiom (`kill -9 "$pid"`) killed only the backgrounded
# subshell, leaving the command-substitution grandchild reparented to init and
# still burning CPU. With the process-group kill the whole tree dies, so the
# marker STOPS growing once the watchdog returns.
#
# Mutation-checked: reverting watchdog.sh's group kill to a bare
# `kill -9 "$pid"` makes this test fail (the tick count keeps climbing).
test_timeout_reaps_command_substitution_grandchild() {
  local marker="$SANDBOX/grandchild-ticks" rc=0
  : >"$marker"

  watchdog_run 1 orphan_probe_tick_forever "$marker" >/dev/null 2>&1 || rc=$?
  assert_eq "124" "$rc" "an overrunning command must report the 124 timeout contract"

  # orphan_probe_no_survivors samples across a window several ticks wide (the
  # ticker fires every 0.2 s) so a survivor is caught rather than raced past —
  # and fails closed if the marker never ticked at all, since a flat 0 → 0 count
  # would otherwise "pass" while proving nothing.
  orphan_probe_no_survivors "$marker" \
    || fail "no descendant may survive the watchdog — the grandchild was stranded"
}

# NOTE ON COVERAGE: the group kill depends on `set -m` giving the job its own
# process group, but there is deliberately no separate "assert pgid == pid" test.
# Probing a pgid portably is not possible here — `$$` still expands to the
# ORIGINAL shell's pid inside a bash subshell, $BASHPID does not exist on the
# bash 3.2 target, and `ps -o pgid=` is unsupported by busybox ps (verified: it
# returns empty on bash:5 Alpine). The test above already covers the mechanism
# behaviourally and portably: deleting `set -m` from watchdog.sh makes it fail
# (mutation-checked), because without a process group the group kill degrades to
# the old single-process kill and the grandchild survives.

# ---- contract preservation: the pass path must be untouched -----------------

test_success_status_and_stdout_pass_through() {
  local out rc=0
  out="$(watchdog_run 10 emit_ok)" || rc=$?
  assert_eq "0" "$rc" "a successful command must return 0"
  assert_eq "payload-stdout" "$out" "stdout must pass through unchanged"
}

test_nonzero_status_propagates_unchanged() {
  local rc=0
  watchdog_run 10 exit_two >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "the command's own exit status must propagate, not be flattened"
}

test_stderr_is_routed_to_the_caller_redirect() {
  local rc=0
  watchdog_run 10 emit_err >/dev/null 2>"$SANDBOX/err-cap" || rc=$?
  assert_eq "0" "$rc" "fixture must succeed"
  assert_eq "payload-stderr" "$(cat "$SANDBOX/err-cap")" \
    "the command's stderr must reach the caller's redirect, un-swallowed"
}

# The reap must not leak bash's job-control "Terminated: 9" notice into a
# captured stderr stream — several call sites assert on captured stderr, so
# noise there would be a real (and confusing) failure.
test_timeout_emits_no_job_control_noise_on_stderr() {
  local rc=0
  watchdog_run 1 sleep 30 >/dev/null 2>"$SANDBOX/noise-cap" || rc=$?
  assert_eq "124" "$rc" "sleep 30 under a 1 s watchdog must time out"
  assert_eq "" "$(cat "$SANDBOX/noise-cap")" \
    "the timeout reap must not print a job-control notice to the caller's stderr"
}

# `set -m` is enabled around the fork; it must be restored afterwards so the
# helper never changes the calling shell's mode (job control on for the rest of a
# test file would alter signal handling and job notification for everything).
test_job_control_state_is_restored() {
  local rc=0
  case "$-" in *m*) fail "precondition: job control must start OFF in this test" ;; *) : ;; esac
  watchdog_run 10 true >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "fixture must succeed"
  case "$-" in
    *m*) fail "watchdog_run left job control ON — it must restore the caller's shell state" ;;
    *) : ;;
  esac
}

run_tests
