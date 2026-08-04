#!/usr/bin/env bash
#
# scripts/changelog-extract.sh — print one version's CHANGELOG entry (issue #70).
#
# `.github/workflows/release.yml` calls this to build the GitHub Release's
# "What changed" section from CHANGELOG.md instead of from the `description`
# dispatch input. It is deliberately STANDALONE — plain CLI args, output on
# stdout, no Actions-only env vars and no secrets — so the same extraction runs
# under bare `bash` outside any workflow and is unit-testable
# (tests/unit/changelog-extract.test.sh).
#
# USAGE:
#   scripts/changelog-extract.sh <version> <changelog-path>
#
#   scripts/changelog-extract.sh 0.1.1 CHANGELOG.md
#   scripts/changelog-extract.sh v0.1.1 CHANGELOG.md   # leading `v` is stripped
#
# MATCHING: one optional leading `v` is stripped from <version>, then the
# remainder must match EXACTLY the version inside a `## [X.Y.Z]` heading —
# never a prefix, so `0.1.1` does not select `## [0.1.10]`. The extracted text
# is everything between that heading (exclusive) and the next `## [` heading or
# end-of-file (exclusive), with CR line endings normalized to `\n` and leading
# and trailing whitespace trimmed.
#
# EXIT CODES — the caller branches on these, and there are exactly three:
#   0  entry found. The entry is on stdout. An entry whose body is empty is
#      still a success and prints nothing: "the section exists and says
#      nothing" is a real, deliberate state, NOT a missing entry, so it must
#      not be confused with the fallback below.
#   3  no entry: the changelog file does not exist, or it has no heading
#      matching the normalized version. The caller substitutes its own text.
#   2  extraction failed: bad usage, a version that is not SemVer X.Y.Z, a
#      changelog path that exists but is not a readable regular file, or an
#      awk failure. The caller must FAIL rather than silently substitute — a
#      forward-only release must never publish notes it could not verify.
#
# Requirements: system bash + awk. Nothing else.
#
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: ${0##*/} <version> <changelog-path>" >&2
  exit 2
fi

VERSION="$1"
CHANGELOG="$2"

# Strip ONE optional leading `v`: release.yml's `version` input is documented
# as bare SemVer, but its tags are `vX.Y.Z`, so both spellings reach here.
NORMALIZED="${VERSION#v}"

if ! [[ "$NORMALIZED" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "${0##*/}: not a SemVer X.Y.Z version: $VERSION" >&2
  exit 2
fi

# A missing changelog is the documented fallback (3), not a failure. Anything
# that exists but cannot be read as a regular file is a failure (2): a
# directory or an unreadable file at the changelog path means the caller's
# assumptions are wrong, and quietly falling back would hide that.
if [ ! -e "$CHANGELOG" ]; then
  exit 3
fi
if [ ! -f "$CHANGELOG" ] || [ ! -r "$CHANGELOG" ]; then
  echo "${0##*/}: not a readable regular file: $CHANGELOG" >&2
  exit 2
fi

# awk exits 3 when no heading matched, so "absent" and "present but empty" stay
# distinguishable — both produce no stdout, and only the exit code tells them
# apart. Compare the bracketed version by EQUALITY after stripping the heading
# scaffolding, rather than by prefix match, so the exactness is structural.
set +e
entry=$(awk -v want="$NORMALIZED" '
  { sub(/\r$/, "") }                       # normalize CRLF line endings to \n
  /^## \[/ {
    if (found) { exit }                    # next version section — stop here
    heading = $0
    sub(/^## \[/, "", heading)
    sub(/\].*$/, "", heading)
    if (heading == want) { found = 1 }
    next
  }
  found { print }
  END { if (!found) { exit 3 } }
' "$CHANGELOG")
rc=$?
set -e

case "$rc" in
  0) : ;;
  3) exit 3 ;;
  *)
    echo "${0##*/}: awk failed (exit $rc) reading $CHANGELOG" >&2
    exit 2
    ;;
esac

# Trim leading and trailing whitespace. Command substitution already dropped
# trailing newlines; these two expansions remove any remaining leading and
# trailing whitespace run. When the entry is whitespace-only, the first
# expansion leaves the empty string — the "heading present, body empty" case,
# which stays exit 0.
entry="${entry#"${entry%%[![:space:]]*}"}"
entry="${entry%"${entry##*[![:space:]]}"}"

# Print nothing at all for an empty entry — no stray blank line.
if [ -n "$entry" ]; then
  printf '%s\n' "$entry"
fi
