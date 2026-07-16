#!/usr/bin/env bash
#
# tests/unit/ci-gate-hardening.test.sh — pin the silent-coverage hardening of
# the #16 CI gate (issue #191) so a "harmless" edit can't quietly reopen it:
#
#   * the docs-links job's lychee globs stay RECURSIVE ('assets/**/*.md'
#     'docs/**/*.md') — the non-recursive originals let a broken link in
#     nested markdown (assets/tax/README.md, docs/decisions/*.md, …) pass
#     silently;
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
    "args: --offline --include-fragments --no-progress 'assets/**/*.md' 'docs/**/*.md'" \
    "docs-links must scan assets/ and docs/ recursively (issue #191)"
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

test_ci_doc_documents_recursive_globs() {
  assert_contains "$ci_doc" "assets/**/*.md" "docs/ci.md must document the recursive assets glob"
  assert_contains "$ci_doc" "docs/**/*.md" "docs/ci.md must document the recursive docs glob"
}

test_ci_doc_records_the_sha_pin_policy() {
  assert_contains "$ci_doc" "Third-party actions are pinned to a full commit SHA" \
    "docs/ci.md must record the third-party SHA-pin policy (issue #191)"
}

run_tests
