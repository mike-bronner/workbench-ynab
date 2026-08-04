#!/usr/bin/env bash
#
# tests/unit/changelog-extract.test.sh — unit tests for
# scripts/changelog-extract.sh, the standalone CHANGELOG entry extractor
# `.github/workflows/release.yml` uses to build a release's "What changed"
# notes (issue #70).
#
# Follows the repo test-harness convention (tests/lib/assert.sh): raw bash with
# `set -euo pipefail`, sources tests/lib/assert.sh, defines `test_*` functions,
# ends with `run_tests`. scripts/test.sh auto-discovers it via the `*.test.sh`
# glob — run the whole suite with `scripts/test.sh`, this file alone with
# `scripts/test.sh tests/unit/changelog-extract.test.sh`, or directly with
# `bash tests/unit/changelog-extract.test.sh`.
#
# The script is EXECUTED here, never grepped: its whole reason for existing as
# a standalone file (rather than inline workflow shell) is that the extraction
# is provable outside a release run. Every expected value below is a hardcoded
# literal, written from the fixture by hand — never re-derived by calling the
# extractor a second time, which would pass no matter what the script does.
#
# The three exit codes are a contract release.yml branches on, so each gets its
# own test: 0 = entry extracted (empty body included), 3 = no entry, fall back
# to the dispatch description, 2 = extraction failed, fail the release.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"

SCRIPT="$REPO_ROOT/scripts/changelog-extract.sh"
FIXTURE="$REPO_ROOT/tests/fixtures/changelog-extract/CHANGELOG.md"

# assert_not_contains <haystack> <needle> [msg] — the shared lib has no
# negative form; the section-boundary tests need "content from the neighbouring
# section must be ABSENT from the extracted entry".
assert_not_contains() {
  case "$1" in
    *"$2"*)
      printf '  assert_not_contains failed: [%s] must NOT contain [%s]%s\n' "$1" "$2" "${3:+ — $3}" >&2
      return 1
      ;;
    *) : ;;
  esac
}

# extract <version> <path> — run the script, capturing BOTH stdout and the exit
# code without `set -e` aborting the test on the non-zero contract codes.
# Sets $out and $rc for the caller.
extract() {
  set +e
  out=$(bash "$SCRIPT" "$@" 2>/dev/null)
  rc=$?
  set -e
}

# --- exit 0: the entry is extracted, exactly ---------------------------------

test_extracts_the_entry_body_verbatim() {
  # Hardcoded literal, transcribed from the fixture by hand. It starts at the
  # lead-in (the blank line under the heading is trimmed) and ends at the last
  # bullet (the blank line before the next heading is trimmed).
  local expected
  expected='Lead-in for nine.

### Added

- Nine feature A
- Nine feature B

### Fixed

- Nine fix'
  extract 9.9.9 "$FIXTURE"
  assert_eq 0 "$rc" "a version present in the changelog must exit 0"
  assert_eq "$expected" "$out" "the extracted entry must be the section body, whitespace-trimmed"
}

test_entry_excludes_every_adjacent_section() {
  # The boundary rule is what a whole-file read would get wrong: content above
  # the heading, and content under the NEXT heading, must both stay out.
  extract 9.9.9 "$FIXTURE"
  assert_eq 0 "$rc" "9.9.9 must extract cleanly"
  assert_not_contains "$out" "Preamble prose" "file preamble must not leak into an entry"
  assert_not_contains "$out" "Unreleased bullet" "the [Unreleased] section must not leak into a released entry"
  assert_not_contains "$out" "## [9.9.8]" "the next section's heading must terminate the entry"
  assert_not_contains "$out" "Eight feature" "the next section's body must not leak into an entry"
  assert_not_contains "$out" "Ten feature" "no later section may leak into an entry"
}

test_last_section_runs_to_end_of_file() {
  # A section with no following `## [` heading must terminate at EOF, not
  # return nothing.
  local expected
  expected='### Added

- Six feature'
  extract 9.9.6 "$FIXTURE"
  assert_eq 0 "$rc" "the final section must extract cleanly"
  assert_eq "$expected" "$out" "the final section must run to end-of-file"
}

test_leading_v_is_stripped() {
  # release.yml's input is bare SemVer but its tags are `vX.Y.Z`; both spellings
  # must select the same entry.
  extract v9.9.9 "$FIXTURE"
  assert_eq 0 "$rc" "a v-prefixed version must resolve"
  assert_contains "$out" "- Nine feature A" "v9.9.9 must select the same entry as 9.9.9"
  assert_not_contains "$out" "Eight feature" "v-prefix handling must not widen the section boundary"
}

test_crlf_line_endings_are_normalized() {
  # The script promises `\n` output for a CRLF changelog. Without the CR strip
  # every extracted line would keep a trailing \r and this literal would differ.
  local tmp expected
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064  # expand $tmp now: the trap must not depend on a later value
  trap "rm -rf '$tmp'" RETURN
  printf '# Changelog\r\n\r\n## [1.2.3] - 2026-01-01\r\n\r\n### Added\r\n\r\n- CRLF bullet\r\n\r\n## [1.2.2] - 2025-12-31\r\n' > "$tmp/CHANGELOG.md"
  expected='### Added

- CRLF bullet'
  extract 1.2.3 "$tmp/CHANGELOG.md"
  assert_eq 0 "$rc" "a CRLF changelog must extract cleanly"
  assert_eq "$expected" "$out" "CR characters must be stripped from every extracted line"
}

test_runs_under_bare_bash_with_no_environment() {
  # The standalone contract: plain CLI args only, no Actions-only env vars and
  # no secrets. `env -i` proves it — anything reading GITHUB_*/inputs.* would
  # break here while passing under a normal shell.
  local out_i rc_i
  set +e
  out_i=$(env -i /usr/bin/env bash "$SCRIPT" 9.9.6 "$FIXTURE" 2>/dev/null)
  rc_i=$?
  set -e
  assert_eq 0 "$rc_i" "the script must run with an empty environment"
  assert_contains "$out_i" "- Six feature" "the extraction must not depend on any environment variable"
}

# --- exit 3: no entry — release.yml falls back to the dispatch description ----

test_absent_version_signals_fallback() {
  extract 7.7.7 "$FIXTURE"
  assert_eq 3 "$rc" "a version with no heading must exit 3 (fallback), not 0 or 2"
  assert_eq "" "$out" "the fallback path must print nothing"
}

test_version_match_is_exact_not_a_prefix() {
  # 9.9.1 is a prefix of the fixture's real 9.9.10 entry. A prefix match would
  # publish 9.9.10's notes under 9.9.1 — it must report "no entry" instead.
  extract 9.9.1 "$FIXTURE"
  assert_eq 3 "$rc" "9.9.1 must not match the ## [9.9.10] heading"
  assert_eq "" "$out" "a prefix near-miss must print nothing"
}

test_missing_changelog_file_signals_fallback() {
  extract 9.9.9 "$REPO_ROOT/tests/fixtures/changelog-extract/does-not-exist.md"
  assert_eq 3 "$rc" "an absent changelog must exit 3 (fallback), not fail the release"
  assert_eq "" "$out" "an absent changelog must print nothing"
}

# --- exit 0, empty: the section exists and is deliberately empty --------------

test_empty_section_is_success_not_fallback() {
  # This is the case the whole three-code contract exists for: 9.9.7's heading
  # is immediately followed by the next heading. "Present but empty" must NOT
  # be reported as "absent", or a deliberately-empty entry would silently
  # publish the dispatch description instead.
  extract 9.9.7 "$FIXTURE"
  assert_eq 0 "$rc" "an empty section must exit 0, never the fallback code 3"
  assert_eq "" "$out" "an empty section must return the empty string"
}

# --- exit 2: extraction failed — release.yml fails the run -------------------

test_wrong_argument_count_fails_loudly() {
  local rc_none rc_one rc_three
  set +e
  bash "$SCRIPT" >/dev/null 2>&1
  rc_none=$?
  bash "$SCRIPT" 9.9.9 >/dev/null 2>&1
  rc_one=$?
  bash "$SCRIPT" 9.9.9 "$FIXTURE" extra >/dev/null 2>&1
  rc_three=$?
  set -e
  assert_eq 2 "$rc_none" "no arguments must exit 2"
  assert_eq 2 "$rc_one" "a missing changelog path must exit 2"
  assert_eq 2 "$rc_three" "a surplus argument must exit 2"
}

test_non_semver_version_fails_loudly() {
  # Must be 2, never 3: a malformed version is a caller bug, and quietly
  # falling back would publish the dispatch description under it.
  local v
  for v in "" abc 1.2 1.2.3.4 "1.2.x" " 1.2.3"; do
    extract "$v" "$FIXTURE"
    assert_eq 2 "$rc" "a non-SemVer version [$v] must exit 2, not fall back"
  done
}

test_unreadable_changelog_path_fails_loudly() {
  # The path EXISTS but is not a readable regular file. Distinct from "absent"
  # on purpose — the caller's assumption is wrong and must surface, not fall
  # back to the dispatch description.
  local tmp
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064  # expand $tmp now: the trap must not depend on a later value
  trap "chmod -R u+rwx '$tmp' 2>/dev/null; rm -rf '$tmp'" RETURN

  extract 9.9.9 "$tmp"
  assert_eq 2 "$rc" "a directory at the changelog path must exit 2, not 3"

  printf '## [9.9.9] - 2026-01-02\n\n- hidden\n' > "$tmp/CHANGELOG.md"
  chmod 000 "$tmp/CHANGELOG.md"
  # A test running as root can read a 000 file, which would make the assertion
  # below vacuous rather than wrong — skip instead of asserting a falsehood.
  if [ -r "$tmp/CHANGELOG.md" ]; then
    return 0
  fi
  extract 9.9.9 "$tmp/CHANGELOG.md"
  assert_eq 2 "$rc" "an unreadable changelog must exit 2, not 3"
}

# --- the repo's own CHANGELOG.md is extractable ------------------------------

test_repo_changelog_entry_is_extractable() {
  # End-to-end against the real file the release will read: the shipped
  # CHANGELOG.md must actually yield notes for the released version, not just
  # parse in a fixture.
  extract 0.1.1 "$REPO_ROOT/CHANGELOG.md"
  assert_eq 0 "$rc" "the repo CHANGELOG.md must have an extractable [0.1.1] entry"
  assert_contains "$out" "productizes the April 2026 prototype" "the entry must carry its lead-in sentence"
  assert_contains "$out" "### Added" "the entry must keep its Keep-a-Changelog subheading"
  assert_not_contains "$out" "## [Unreleased]" "the [Unreleased] section must not leak into the release notes"
}

run_tests
