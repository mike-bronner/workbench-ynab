#!/usr/bin/env bash
#
# tests/unit/gitignore-tax-profile.test.sh — regression guard for AC #3 of
# issue #24 (M3-5).
#
# The live tax-profile.json is secret-adjacent personal financial data: it must
# NEVER be committable to this PUBLIC repo, while the anonymized
# tax-profile.example.json template MUST stay tracked so users have something to
# copy. This locks in the `.gitignore` rule that migration added — a future
# .gitignore reorg that silently drops the `tax-profile.json` line would re-open
# the door to committing real financial PII, and this test is what catches it.
#
# Raw bash, sources tests/lib/assert.sh; no framework to install (see
# docs/testing.md). Run directly:
#   bash tests/unit/gitignore-tax-profile.test.sh
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$SELF_DIR/../lib/assert.sh"

cd "$ROOT"

# is_ignored <path> — exit 0 iff git's ignore rules would block <path>.
# `git check-ignore` consults only the ignore rules, so it works on paths that
# don't exist on disk (the live profile never does in a clean checkout).
is_ignored() { git check-ignore -q -- "$1"; }

# A live tax-profile.json at the repo root must be ignored.
test_live_profile_ignored_at_root() {
  is_ignored "tax-profile.json" \
    || fail "tax-profile.json at the repo root must be git-ignored (AC #3)"
}

# ...and under any subdirectory too — the rule is filename-anchored, not path-anchored.
test_live_profile_ignored_in_subdir() {
  is_ignored "assets/tax/tax-profile.json" \
    || fail "a tax-profile.json under a subdir must be git-ignored (AC #3)"
}

# The anonymized template must NOT be ignored (distinct filename, stays shareable).
test_example_template_not_ignored() {
  if is_ignored "assets/tax/tax-profile.example.json"; then
    fail "tax-profile.example.json must stay tracked, not ignored (AC #3/#4)"
  fi
}

# ...and is in fact a tracked file, not merely un-ignored.
test_example_template_is_tracked() {
  git ls-files --error-unmatch -- "assets/tax/tax-profile.example.json" >/dev/null 2>&1 \
    || fail "tax-profile.example.json must be a tracked file in the repo"
}

run_tests
