#!/usr/bin/env bash
#
# tests/unit/harness-selftest.test.sh — proves the raw-bash harness works and
# that the committed fixtures are valid JSON. This is a real regression guard
# for the harness itself; later test issues add their own tests/**/*.test.sh
# alongside it using the same convention (source assert.sh, define test_*,
# call run_tests).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/tests/lib/assert.sh"

test_assert_helpers_work() {
  assert_eq "abc" "abc"
  assert_contains "hello world" "world"
  assert_exact_line "$(printf 'alpha\nbeta\ngamma')" "beta"
  assert_file_exists "$ROOT/scripts/test.sh"
  assert_dir_exists "$ROOT/tests"
}

# The harness's reason to exist is catching failures — so prove each helper
# actually fails on bad input. A regression that made an assert always return 0
# (the silent-green failure mode) would trip every check here. Each helper is
# run in a subshell so its non-zero return is observed, not propagated.
test_failing_assertions_are_caught() {
  if (assert_eq "a" "b") 2>/dev/null; then fail "assert_eq passed on unequal values"; fi
  if (assert_contains "abc" "z") 2>/dev/null; then fail "assert_contains passed on a missing needle"; fi
  # The whole point of assert_exact_line: a substring-only match must NOT pass.
  if (assert_exact_line "ynab_list_budgets_v2" "ynab_list_budgets") 2>/dev/null; then fail "assert_exact_line passed on a substring-only match"; fi
  if (assert_exact_line "$(printf 'alpha\ngamma')" "beta") 2>/dev/null; then fail "assert_exact_line passed on a missing line"; fi
  if (assert_file_exists "$ROOT/no/such/file") 2>/dev/null; then fail "assert_file_exists passed on a missing path"; fi
  if (assert_file_exists "$ROOT/tests") 2>/dev/null; then fail "assert_file_exists passed on a directory"; fi
  if (assert_dir_exists "$ROOT/scripts/test.sh") 2>/dev/null; then fail "assert_dir_exists passed on a regular file"; fi
  if (assert_json_valid "$ROOT/scripts/test.sh") 2>/dev/null; then fail "assert_json_valid passed on non-JSON"; fi
  if (fail "deliberate") 2>/dev/null; then fail "fail() returned zero"; fi
}

# run_tests must report non-zero when a test_* function fails, and must NOT pass
# silently when a file defines zero test_* functions. Each case runs in a fresh
# `bash -c` so declare -F sees only the functions defined there, in isolation
# from this file's own test_* functions.
test_run_tests_reports_failures() {
  if bash -c "set -euo pipefail; source '$ROOT/tests/lib/assert.sh'; test_x() { return 1; }; run_tests" >/dev/null 2>&1; then
    fail "run_tests returned 0 despite a failing test_* function"
  fi
  if bash -c "set -euo pipefail; source '$ROOT/tests/lib/assert.sh'; run_tests" >/dev/null 2>&1; then
    fail "run_tests returned 0 with zero test_* functions (silent no-op)"
  fi
}

# Regression guard for the non-final-failure fix (tests/lib/assert.sh, the
# `set +e; ( set -euo pipefail; "$fn" ); rc=$?; set -e` form): a failed
# assertion FOLLOWED BY further code must still fail the test. The other two
# self-tests use a function whose failing command is also its LAST command, so
# they pass identically under the old buggy `if ( set -euo pipefail; "$fn" )`
# pattern — where bash suspends `set -e` inside an if-condition subshell, the
# non-final failure is swallowed, and the trailing success turns the test
# green. Every *.test.sh in the repo leans on this fix; reverting it must go
# red here.
test_run_tests_nonfinal_failure_is_authoritative() {
  if bash -c "set -euo pipefail; source '$ROOT/tests/lib/assert.sh'; test_x() { assert_eq a b; true; }; run_tests" >/dev/null 2>&1; then
    fail "run_tests returned 0 when a NON-final assertion failed (trailing success masked it)"
  fi
}

# The headline contract (AC #6, what CI #16 depends on): scripts/test.sh must
# exit non-zero when any test fails. Drive the real entrypoint over a throwaway
# failing test file and assert the non-zero exit.
test_entrypoint_exits_nonzero_on_failure() {
  local tmp
  tmp="$(mktemp -d)"
  cat >"$tmp/deliberate-fail.test.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$ROOT/tests/lib/assert.sh"
test_must_fail() { assert_eq "1" "2"; }
run_tests
EOF
  if "$ROOT/scripts/test.sh" "$tmp/deliberate-fail.test.sh" >/dev/null 2>&1; then
    rm -rf "$tmp"
    fail "scripts/test.sh exited 0 for a failing test file"
  fi
  rm -rf "$tmp"
}

# Contradictory suite selectors must error (exit 2), never silently run nothing.
test_entrypoint_rejects_contradictory_flags() {
  if "$ROOT/scripts/test.sh" --bash --node >/dev/null 2>&1; then
    fail "scripts/test.sh --bash --node exited 0 instead of erroring"
  fi
}

# A selector that filters out EVERY on-disk test file must fail loudly (exit 1),
# never exit 0 having run nothing — the precise false-green this whole harness
# exists to prevent (scripts/test.sh:118-120). Build an isolated tree (a copy of
# the entrypoint + a tests/ dir holding ONLY a *.test.mjs) so discovery sees
# exactly one file, then run with --bash so the selector excludes it.
test_entrypoint_rejects_selector_that_excludes_all() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts" "$tmp/tests/unit"
  cp "$ROOT/scripts/test.sh" "$tmp/scripts/test.sh"
  cat >"$tmp/tests/unit/only-node.test.mjs" <<'EOF'
import test from 'node:test';
test('noop', () => {});
EOF
  if "$tmp/scripts/test.sh" --bash >/dev/null 2>&1; then
    rm -rf "$tmp"
    fail "scripts/test.sh --bash exited 0 when only *.test.mjs files exist (false green)"
  fi
  rm -rf "$tmp"
}

# The other side of that contract (AC #8): a clean checkout with NO test files on
# disk must exit 0 with the "no tests yet" message (scripts/test.sh:114-116) —
# distinct from the selector-excluded-everything failure above. Isolated tree
# again: copy the entrypoint, give it an empty tests/ dir.
test_entrypoint_clean_checkout_reports_no_tests() {
  local tmp out
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts" "$tmp/tests"
  cp "$ROOT/scripts/test.sh" "$tmp/scripts/test.sh"
  if ! out="$("$tmp/scripts/test.sh" 2>&1)"; then
    rm -rf "$tmp"
    fail "scripts/test.sh exited non-zero on a clean checkout with no test files (AC #8)"
  fi
  rm -rf "$tmp"
  assert_contains "$out" "no tests yet"
}

test_directory_layout_is_canonical() {
  assert_dir_exists "$ROOT/tests/unit"
  assert_dir_exists "$ROOT/tests/integration"
  assert_dir_exists "$ROOT/tests/snapshot"
  assert_dir_exists "$ROOT/tests/fixtures"
  assert_dir_exists "$ROOT/tests/fixtures/hostile"
}

test_fixtures_are_valid_json() {
  assert_json_valid "$ROOT/tests/fixtures/populated-budget.json"
  assert_json_valid "$ROOT/tests/fixtures/empty-budget.json"
  assert_json_valid "$ROOT/tests/fixtures/hostile/hostile-transactions.json"
  assert_json_valid "$ROOT/tests/fixtures/hostile/malformed-changeset.json"
}

test_populated_fixture_has_expected_shape() {
  local accounts txns
  accounts=$(jq '.data.budget.accounts | length' "$ROOT/tests/fixtures/populated-budget.json")
  txns=$(jq '.data.budget.transactions | length' "$ROOT/tests/fixtures/populated-budget.json")
  assert_eq "3" "$accounts" "populated budget should have 3 accounts"
  [ "$txns" -ge 1 ] || fail "populated budget should have at least one transaction"
}

run_tests
