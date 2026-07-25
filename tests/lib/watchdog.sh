#!/usr/bin/env bash
#
# tests/lib/watchdog.sh — the ONE portable "run this under a timeout" helper for
# the raw-bash suite (issue #188).
#
# WHY THIS FILE EXISTS
# --------------------
# macOS ships no timeout(1), so the suite's DoS/hang guards each grew their own
# poll-until-exit watchdog: background the work, poll `kill -0` once a second,
# and kill it if it overruns. Every copy killed only the DIRECT backgrounded
# child:
#
#     ( work ) &
#     pid=$!
#     ... kill -9 "$pid"        # <-- only the subshell
#
# That is a leak. Non-interactive bash has job control OFF, so the backgrounded
# subshell inherits the *test script's* process group, and the expensive work
# typically runs one level deeper — inside a nested command substitution, i.e. a
# GRANDCHILD of the killed subshell. SIGKILL to the subshell alone leaves that
# grandchild reparented to init (PPID 1), still burning CPU, on precisely the
# code path the watchdog exists to contain. The kill path only runs on a FAILED
# watchdog (a real regression or genuine DoS), so green CI never exercised it
# and the leak stayed invisible.
#
# THE FIX
# -------
# `set -m` (job control) around the `&` puts the job in its OWN process group
# with pgid == pid; the timeout branch then signals the whole GROUP (`-"$pid"`),
# reaping the entire descendant tree instead of one process. Job control is
# restored to its prior state immediately after the fork, so enabling it here
# never leaks into the caller's shell.
#
# Verified on the repo's documented bash 3.2 target (bash 3.2.57, macOS): the
# job really is a process-group leader, the group kill reaps the
# command-substitution grandchild, and the pass path is byte-for-byte unchanged.
# tests/unit/watchdog.test.sh pins all of that as a regression.
#
# NOT IN SCOPE: tests/lib/bundle-integrity.sh and tests/integration/
# offline-boot.test.sh also poll-and-kill, but they background a NODE BINARY
# directly (`bin/ynab-mcp` is `#!/usr/bin/env node`; offline-boot `exec`s node),
# so their $pid IS the process they mean to kill — there is no intervening shell
# subshell and no command-substitution grandchild to strand. They are a
# different shape, not this class.

# watchdog_run <secs> <command> [args...]
#
# Run <command> (a function, builtin, or external program, plus its args) in a
# background subshell under a <secs> watchdog.
#
#   * Returns 124 if the command overran — after killing its whole process
#     group, so no descendant survives the timeout.
#   * Otherwise returns the command's own exit status, unchanged.
#
# stdout/stderr are INHERITED, so callers redirect at the call site exactly as
# they would a plain invocation:
#
#     watchdog_run 20 my_fn arg >"$out_file" 2>"$err_file" || rc=$?
#
# The poll loop itself writes nothing to stdout, and the reap is stderr-silenced:
# whether a shell prints a job-control "Killed: 9" notice when reaping a signalled
# job is version- and build-dependent (none observed on bash 3.2.57 or 5.3, but
# this repo guarantees BOTH bash 3.2 and bash >= 5.0 — see the ci.yml dual-bash
# lanes), and call sites such as report-writer's assert on captured stderr. The
# contract "a timeout adds nothing to the caller's stderr" is pinned by
# tests/unit/watchdog.test.sh; silencing the reap is how it is kept portable.
#
# set -e safety: every internal command that may legitimately fail is guarded,
# so this is safe to call from `set -euo pipefail` test files. Callers that care
# about a non-zero result must still capture it (`|| rc=$?`), as with any
# command under `set -e`.
watchdog_run() {
  local secs="$1"; shift

  # Remember whether job control was already on, so `set -m` below is restored
  # rather than blindly cleared — never change the caller's shell state.
  local job_control_was_on=0
  case "$-" in *m*) job_control_was_on=1 ;; esac

  # Job control ON only across the fork: that is what gives the job its own
  # process group (pgid == pid), which the group kill below depends on.
  set -m
  "$@" &
  local pid=$!
  [ "$job_control_was_on" -eq 1 ] || set +m

  local waited=0 rc=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      # Kill the GROUP (the leading `-` on the pid), not just the direct child,
      # so command-substitution grandchildren die with it.
      #
      # Fall back to the bare pid if the group kill fails: if job control did
      # not take effect for any reason, no process group with this id exists,
      # and failing to kill ANYTHING would be strictly worse than the
      # single-process kill this replaced. Fail closed — always kill something.
      # `-"$pid"` can never name the caller's own group: $pid was just forked,
      # so it cannot equal an older ancestor's pid.
      { kill -9 -- -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
      } 2>/dev/null
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done

  # Normal exit: reap and propagate the command's own status untouched.
  { wait "$pid" || rc=$?; } 2>/dev/null
  return "$rc"
}
