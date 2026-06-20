#!/usr/bin/env bash
#
# tests/lib/assert.sh — shared assertion helpers + a tiny runner for the
# raw-bash test suite.
#
# CHOSEN BASH CONVENTION (recorded here and in docs/testing.md):
#   * Raw bash, NOT bats-core. Rationale: the plugin's whole premise is
#     "nothing to install" — vendored MCP, system node/jq/security, no
#     npx-on-demand. A test runner that needs `brew install bats-core` would
#     break that and the no-node_modules / offline guarantee. Raw bash needs
#     only what the plugin already requires.
#
# Each bash test file:
#   1. starts with `#!/usr/bin/env bash` and `set -euo pipefail`
#   2. sources THIS file
#   3. defines one or more `test_<name>` functions (a failed assertion or any
#      non-zero command fails that test)
#   4. ends by calling `run_tests`
#
# `run_tests` discovers every `test_*` function, runs each in an isolated
# subshell, prints a per-test ✓/✗ line, and returns non-zero if any failed.
# Zero dependencies beyond system bash + jq.

# assert_eq <expected> <actual> [message]
assert_eq() {
  if [ "$1" != "$2" ]; then
    printf '  assert_eq failed: expected [%s], got [%s]%s\n' "$1" "$2" "${3:+ — $3}" >&2
    return 1
  fi
}

# assert_contains <haystack> <needle> [message]
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *)
      printf '  assert_contains failed: [%s] does not contain [%s]%s\n' "$1" "$2" "${3:+ — $3}" >&2
      return 1
      ;;
  esac
}

# assert_file_exists <path> — a regular file must exist (not a directory).
assert_file_exists() {
  if [ ! -f "$1" ]; then
    printf '  assert_file_exists failed: %s is not an existing file\n' "$1" >&2
    return 1
  fi
}

# assert_dir_exists <path> — a directory must exist.
assert_dir_exists() {
  if [ ! -d "$1" ]; then
    printf '  assert_dir_exists failed: %s is not an existing directory\n' "$1" >&2
    return 1
  fi
}

# assert_json_valid <file> — requires jq
assert_json_valid() {
  if ! jq empty "$1" >/dev/null 2>&1; then
    printf '  assert_json_valid failed: %s is not valid JSON\n' "$1" >&2
    return 1
  fi
}

# fail [message] — unconditional failure inside a test_* function
fail() {
  printf '  %s\n' "${1:-explicit fail}" >&2
  return 1
}

# run_tests — discover and run every test_* function defined by the caller.
run_tests() {
  local fns fn failed=0 total=0
  fns=$(declare -F | awk '{print $3}' | grep '^test_' || true)
  if [ -z "$fns" ]; then
    # A *.test.sh file that defines no test_* functions ran nothing. For a
    # harness whose job is to never pass silently, that is a failure (likely a
    # naming typo such as `mytest_foo`), not a green — return non-zero so
    # scripts/test.sh counts it as a failing group.
    printf '  ✗ no test_* functions found — a test file that ran nothing is a failure\n' >&2
    return 1
  fi
  for fn in $fns; do
    total=$((total + 1))
    if ( set -euo pipefail; "$fn" ); then
      printf '  ✓ %s\n' "$fn"
    else
      printf '  ✗ %s\n' "$fn" >&2
      failed=$((failed + 1))
    fi
  done
  if [ "$failed" -gt 0 ]; then
    printf '  %d/%d failed\n' "$failed" "$total" >&2
    return 1
  fi
  printf '  %d/%d passed\n' "$total" "$total"
  return 0
}
