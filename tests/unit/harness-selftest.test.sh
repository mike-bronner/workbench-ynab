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
  assert_file_exists "$ROOT/scripts/test.sh"
}

test_directory_layout_is_canonical() {
  assert_file_exists "$ROOT/tests/unit"
  assert_file_exists "$ROOT/tests/integration"
  assert_file_exists "$ROOT/tests/snapshot"
  assert_file_exists "$ROOT/tests/fixtures"
  assert_file_exists "$ROOT/tests/fixtures/hostile"
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
