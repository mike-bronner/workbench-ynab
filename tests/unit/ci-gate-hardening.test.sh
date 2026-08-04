#!/usr/bin/env bash
#
# tests/unit/ci-gate-hardening.test.sh — pin the silent-coverage hardening of
# the #16 CI gate (issue #191) so a "harmless" edit can't quietly reopen it:
#
#   * the docs-links job's lychee globs stay RECURSIVE ('assets/**/*.md'
#     'docs/**/*.md') — the non-recursive originals let a broken link in
#     nested markdown (assets/tax/README.md, docs/decisions/*.md, …) pass
#     silently — and keep covering the root README.md (issue #71), whose
#     links to the docs/ set would otherwise sit in a link-check blind spot;
#   * the same globs keep covering the AGENT-FACING markdown, 'skills/**/*.md'
#     and 'commands/**/*.md' (issue #260) — those 26 files carried 95 relative
#     links with no gate at all, and a dangling path there is a live defect,
#     not a reading annoyance: a skill-following agent is instructed to open
#     the file and finds nothing;
#   * lycheeverse/lychee-action — the repo's first third-party action — stays
#     pinned to a full commit SHA with a trailing version comment, never a
#     mutable tag a publisher could repoint;
#   * scripts/lint.sh's JSON check fails closed on an empty file list
#     (behavioral: run against a scratch git repo with zero tracked JSON),
#     mirroring scripts/test.sh's "never green having run nothing" guard;
#   * docs/ci.md keeps documenting the recursive globs and the SHA-pin policy.
#
# Workflow checks are static contract checks over the workflow text — the
# repo-idiomatic way (cf. tests/unit/release-workflow.test.sh) since workflows
# only run on GitHub's runners. The lint.sh checks are behavioral, with a
# stubbed `shellcheck` on PATH so the suite keeps its bash+jq+git-only posture.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"

CI_YML="$REPO_ROOT/.github/workflows/ci.yml"
CI_DOC="$REPO_ROOT/docs/ci.md"

ci_yml=$(cat "$CI_YML")
ci_doc=$(cat "$CI_DOC")

# --- docs-links: recursive globs ---------------------------------------------

test_docs_links_globs_are_recursive() {
  assert_contains "$ci_yml" \
    "args: --offline --include-fragments --no-progress 'assets/**/*.md' 'docs/**/*.md' 'README.md' 'skills/**/*.md' 'commands/**/*.md'" \
    "docs-links must scan assets/, docs/ (issue #191), skills/ and commands/ (issue #260) recursively, plus the root README.md (issue #71)"
}

# Each directory gets its own assertion as well as the exact-args one above:
# dropping a single glob is the realistic regression (a "tidy up the args line"
# edit), and a per-directory failure names which coverage was lost instead of
# only reporting that a long string stopped matching.
test_docs_links_covers_each_directory() {
  failed=0
  for glob in "'assets/**/*.md'" "'docs/**/*.md'" "'README.md'" \
              "'skills/**/*.md'" "'commands/**/*.md'"; do
    if ! printf '%s\n' "$ci_yml" | grep -qF -- "$glob"; then
      echo "  docs-links no longer passes the $glob input to lychee" >&2
      failed=1
    fi
  done
  return "$failed"
}

# The agent-facing half of the markdown set is the whole point of issue #260 —
# assert it separately from the loop above so a revert that keeps the docs/
# globs but drops skills/ or commands/ fails with the issue named.
test_docs_links_covers_the_agent_facing_markdown() {
  args_line=$(printf '%s\n' "$ci_yml" | grep -F 'args: --offline --include-fragments')
  failed=0
  for glob in "'skills/**/*.md'" "'commands/**/*.md'"; do
    case "$args_line" in
      *"$glob"*) ;;
      *)
        echo "  the docs-links args line dropped $glob — agent-facing links are unguarded again (issue #260)" >&2
        failed=1
        ;;
    esac
  done
  return "$failed"
}

test_docs_links_old_nonrecursive_globs_are_gone() {
  if printf '%s\n' "$ci_yml" | grep -qF "'assets/*.md'"; then
    echo "  ci.yml still passes the non-recursive 'assets/*.md' glob" >&2
    return 1
  fi
  if printf '%s\n' "$ci_yml" | grep -qF "'docs/*.md'"; then
    echo "  ci.yml still passes the non-recursive 'docs/*.md' glob" >&2
    return 1
  fi
}

# --- docs-links: third-party action pinned to a commit SHA --------------------

test_lychee_action_pinned_to_full_commit_sha() {
  if ! printf '%s\n' "$ci_yml" | grep -qE 'uses: lycheeverse/lychee-action@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+'; then
    echo "  lycheeverse/lychee-action must be pinned to a 40-hex commit SHA with a trailing '# vX.Y.Z' comment" >&2
    return 1
  fi
}

test_no_action_rides_a_mutable_lychee_tag() {
  if printf '%s\n' "$ci_yml" | grep -qE 'uses: lycheeverse/[^@]+@v[0-9]'; then
    echo "  a lycheeverse action is back on a mutable version tag — third-party actions pin to a commit SHA" >&2
    return 1
  fi
}

# --- lint.sh: JSON check fails closed on an empty file list -------------------

# scratch_repo <dir> — a minimal git repo holding only scripts/lint.sh, with a
# no-op `shellcheck` stub on PATH so the run isolates the JSON check.
make_scratch_repo() {
  mkdir -p "$1/scripts" "$1/stub"
  cp "$REPO_ROOT/scripts/lint.sh" "$1/scripts/lint.sh"
  printf '#!/bin/sh\nexit 0\n' > "$1/stub/shellcheck"
  chmod +x "$1/stub/shellcheck"
  git -C "$1" init -q
  git -C "$1" add scripts/lint.sh
}

test_lint_fails_closed_on_zero_tracked_json_files() {
  tmp=$(mktemp -d)
  make_scratch_repo "$tmp"
  status=0
  out=$(cd "$tmp" && PATH="$tmp/stub:$PATH" bash scripts/lint.sh 2>&1) || status=$?
  rm -rf "$tmp"
  assert_eq 1 "$status" "lint.sh must exit 1 when git ls-files finds no JSON"
  assert_contains "$out" "no tracked JSON files found" "the guard must say why it failed"
  case "$out" in
    *"✓ all JSON files parse"*)
      echo "  lint.sh printed the JSON success line having validated nothing" >&2
      return 1
      ;;
  esac
}

test_lint_json_check_still_passes_with_tracked_json() {
  tmp=$(mktemp -d)
  make_scratch_repo "$tmp"
  printf '{ "ok": true }\n' > "$tmp/ok.json"
  git -C "$tmp" add ok.json
  status=0
  out=$(cd "$tmp" && PATH="$tmp/stub:$PATH" bash scripts/lint.sh 2>&1) || status=$?
  rm -rf "$tmp"
  assert_eq 0 "$status" "lint.sh must pass with a valid tracked JSON file present"
  assert_contains "$out" "✓ all JSON files parse"
}

# --- docs/ci.md stays in sync --------------------------------------------------

# Both glob checks below are SCOPED to the passage they name. A whole-document
# `assert_contains` would be satisfied by the copy-paste recipe near the end of
# the file, which already lists every glob — so it would stay green even if the
# job table and the prose both went stale, which is the drift that misleads a
# reader.

# The docs-links row of the CI job table. Matched on the row shape (first cell
# names the job, second cell is the runner) rather than on the literal
# backticked cell text, which keeps the pattern free of shell metacharacters.
docs_links_table_row() {
  printf '%s\n' "$ci_doc" | grep -E '^\|[^|]*docs-links[^|]*\| ubuntu \|'
}

# The "offline and recursive" prose paragraph, heading line through the next
# blank line.
docs_links_recursive_prose() {
  printf '%s\n' "$ci_doc" \
    | awk '/^\*\*The link check is offline and recursive\.\*\*/ { p = 1 } p && /^$/ { exit } p'
}

test_ci_doc_job_table_lists_every_glob() {
  row=$(docs_links_table_row)
  [ -n "$row" ] || { echo "  docs/ci.md has no docs-links row in the CI job table" >&2; return 1; }
  failed=0
  for glob in 'assets/**/*.md' 'docs/**/*.md' 'skills/**/*.md' 'commands/**/*.md' 'README.md'; do
    case "$row" in
      *"$glob"*) ;;
      *) echo "  docs/ci.md's docs-links job-table row no longer names $glob" >&2; failed=1 ;;
    esac
  done
  return "$failed"
}

test_ci_doc_recursive_prose_lists_every_recursive_glob() {
  prose=$(docs_links_recursive_prose)
  [ -n "$prose" ] || { echo "  docs/ci.md lost the 'offline and recursive' paragraph" >&2; return 1; }
  failed=0
  for glob in 'assets/**/*.md' 'docs/**/*.md' 'skills/**/*.md' 'commands/**/*.md'; do
    case "$prose" in
      *"$glob"*) ;;
      *) echo "  docs/ci.md's 'offline and recursive' paragraph no longer names $glob" >&2; failed=1 ;;
    esac
  done
  return "$failed"
}

# docs/ci.md's "run the gates locally" block is a copy-paste recipe — if it
# drifts from the workflow's args line, someone reproduces a narrower check
# locally, sees green, and pushes a link the real gate rejects.
test_ci_doc_local_lychee_recipe_matches_the_workflow_args() {
  workflow_args=$(printf '%s\n' "$ci_yml" | grep -F 'args: --offline --include-fragments' \
    | sed -e 's/^ *args: //')
  # Anchored: the job table earlier in the doc mentions the same command
  # inline, but only the copy-paste recipe starts a line with `lychee `.
  doc_args=$(printf '%s\n' "$ci_doc" | grep -E '^lychee --offline --include-fragments' \
    | sed -e 's/^lychee //')
  assert_eq "$workflow_args" "$doc_args" \
    "docs/ci.md's local lychee recipe must pass exactly the flags and globs the workflow does"
}

test_ci_doc_records_the_sha_pin_policy() {
  assert_contains "$ci_doc" "Third-party actions are pinned to a full commit SHA" \
    "docs/ci.md must record the third-party SHA-pin policy (issue #191)"
}

run_tests
