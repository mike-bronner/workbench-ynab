#!/usr/bin/env bash
#
# tests/unit/release-workflow.test.sh — pin the release-automation invariants
# (issue #74, design M5-5) across .github/workflows/release.yml,
# .github/workflows/update-marketplace-sha.yml, and docs/ci.md.
#
# Workflows only run on GitHub's runners, so these tests are static contract
# checks over the workflow text — the repo-idiomatic way (cf.
# tests/unit/pre-approval-globs.test.sh) to guard the properties that are easy
# to break in a "harmless" edit and expensive to get wrong on a release path:
#   * the guards (SemVer + tag-exists) stay ahead of every write;
#   * the bundle-integrity proof and the test suite gate BEFORE commit/tag —
#     reordering steps below the tag would ship an unverified release;
#   * the sole version-bump target stays .claude-plugin/plugin.json (issue
#     #75): the frozen vendored marker must never become a bump target, and no
#     wheel/uv build step may reappear from the bujo ancestor;
#   * the sterile-event chain (gh workflow run) that makes the marketplace pin
#     fire at all;
#   * the pin workflow's portability (plugin name read from plugin.json),
#     annotated-tag dereference, loud missing-token failure, and silent no-ops;
#   * concurrency/permissions posture of both workflows;
#   * the DEVELOPER_SETTINGS_TOKEN documentation contract in docs/ci.md.
#
# Follows the repo harness convention (tests/lib/assert.sh): raw bash with
# `set -euo pipefail`, `test_*` functions, `run_tests`. Auto-discovered by
# scripts/test.sh. Zero dependencies beyond system bash + grep.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"

RELEASE="$REPO_ROOT/.github/workflows/release.yml"
PIN="$REPO_ROOT/.github/workflows/update-marketplace-sha.yml"
CI_DOC="$REPO_ROOT/docs/ci.md"

release=$(cat "$RELEASE")
pin=$(cat "$PIN")

# first_line <pattern> <file> — line number of the first fixed-string match.
first_line() { grep -nF -- "$1" "$2" | head -1 | cut -d: -f1; }

# --- release.yml: trigger + inputs ------------------------------------------

test_release_workflow_exists() {
  assert_file_exists "$RELEASE"
}

test_release_dispatch_inputs() {
  assert_contains "$release" "workflow_dispatch:" "must trigger via workflow_dispatch"
  for input in version description; do
    # The input block must exist and be required (steps read both unguarded).
    block=$(awk -v key="      ${input}:" '$0 == key {f=1} f {print} f && /required:/ {exit}' "$RELEASE")
    assert_contains "$block" "required: true" "input '$input' must be required"
  done
}

# --- release.yml: guards run before any write --------------------------------

test_release_semver_guard() {
  assert_contains "$release" '^[0-9]+\.[0-9]+\.[0-9]+$' "must validate SemVer X.Y.Z"
  assert_contains "$release" "::error::Version must be SemVer" "rejection must be an ::error:: annotation"
}

test_release_tag_exists_guard() {
  assert_contains "$release" 'git rev-parse "v$NEW_VERSION"' "must check the tag does not already exist"
  assert_contains "$release" "::error::Tag v" "tag-exists rejection must be an ::error:: annotation"
}

test_release_guards_precede_writes() {
  validate=$(first_line "Version must be SemVer" "$RELEASE")
  bump=$(first_line "name: Bump version" "$RELEASE")
  commit=$(first_line "name: Commit, tag, push" "$RELEASE")
  [ "$validate" -lt "$bump" ] || fail "SemVer/tag guards (line $validate) must precede the version bump (line $bump)"
  [ "$bump" -lt "$commit" ] || fail "version bump (line $bump) must precede commit/tag (line $commit)"
}

# --- release.yml: frozen bundle, sole bump target ----------------------------

test_release_bumps_plugin_json_only() {
  assert_contains "$release" ".claude-plugin/plugin.json" "must bump plugin.json"
  # Issue #75: the vendored marker is frozen provenance — never a bump target.
  bump_step=$(awk '/name: Bump version/{f=1} f && /name: Run the test suite/{exit} f' "$RELEASE")
  case "$bump_step" in
    *vendored.json*) fail "the bump step must never touch vendor/ynab-mcp/vendored.json (frozen, issue #75)" ;;
  esac
}

test_release_has_no_wheel_build() {
  # The bujo ancestor built a wheel; this repo's bundle is committed + frozen.
  for forbidden in "uv build" "setup-uv" ".whl"; do
    case "$release" in
      *"$forbidden"*) fail "release.yml must not contain '$forbidden' — the vendored bundle is frozen, never rebuilt" ;;
    esac
  done
}

test_release_verifies_bundle_before_tagging() {
  assert_contains "$release" "tests/lib/bundle-integrity.sh" "must use the shared integrity library (issue #78)"
  assert_contains "$release" "bi_assert_integrity" "must run the checksum + offline-boot proof"
  verify=$(first_line "bi_assert_integrity" "$RELEASE")
  commit=$(first_line "name: Commit, tag, push" "$RELEASE")
  [ "$verify" -lt "$commit" ] || fail "bundle integrity (line $verify) must gate before commit/tag (line $commit)"
  assert_contains "$release" "::error::Vendored bundle integrity check failed" "a drift must fail with a descriptive error"
}

# --- release.yml: tests gate the release -------------------------------------

test_release_runs_test_suite_before_tagging() {
  assert_contains "$release" "bash scripts/test.sh" "must run the single suite entrypoint"
  suite=$(first_line "bash scripts/test.sh" "$RELEASE")
  assets=$(first_line "npm --prefix assets ci" "$RELEASE")
  commit=$(first_line "name: Commit, tag, push" "$RELEASE")
  [ "$suite" -lt "$commit" ] || fail "test suite (line $suite) must gate before commit/tag (line $commit)"
  # assets/ deps install strictly AFTER the dependency-free suite, so no
  # node_modules exists while the offline-boot proof runs (mirrors test.yml).
  [ -n "$assets" ] || fail "the assets/ integration suite must gate the release too"
  [ "$suite" -lt "$assets" ] || fail "scripts/test.sh (line $suite) must run before npm ci (line $assets) to keep the offline proof faithful"
  [ "$assets" -lt "$commit" ] || fail "assets suite (line $assets) must gate before commit/tag (line $commit)"
}

# --- release.yml: commit / tag / release / chain -----------------------------

test_release_commits_as_actions_bot() {
  assert_contains "$release" 'git config user.name "github-actions[bot]"' "must commit as github-actions[bot]"
  assert_contains "$release" "41898282+github-actions[bot]@users.noreply.github.com" "must use the bot noreply email"
}

test_release_annotated_tag_and_pushes() {
  assert_contains "$release" 'git tag -a "v${NEW_VERSION}"' "tag must be annotated"
  assert_contains "$release" "git push origin main" "must push main"
  assert_contains "$release" 'git push origin "v${NEW_VERSION}"' "must push the tag"
}

test_release_creates_github_release() {
  assert_contains "$release" 'gh release create "v${NEW_VERSION}"' "must create the GitHub release"
  assert_contains "$release" '--title "v${NEW_VERSION} — ${DESC}"' "release title must be 'vX.Y.Z — description'"
  assert_contains "$release" "update-marketplace-sha.yml" "notes/chain must reference the SHA pin"
}

test_release_chains_marketplace_pin_explicitly() {
  # GITHUB_TOKEN-created releases emit sterile events; the chain must be
  # explicit or the pin never fires.
  assert_contains "$release" "gh workflow run update-marketplace-sha.yml" "must trigger the pin via gh workflow run"
}

test_release_concurrency_and_permissions() {
  assert_contains "$release" "group: release" "concurrency group must be 'release'"
  assert_contains "$release" "cancel-in-progress: false" "a running release must never be cancelled"
  assert_contains "$release" "contents: write" "needs contents: write to push"
  assert_contains "$release" "actions: write" "needs actions: write to chain the pin workflow"
}

# --- update-marketplace-sha.yml ----------------------------------------------

test_pin_workflow_exists() {
  assert_file_exists "$PIN"
}

test_pin_triggers() {
  assert_contains "$pin" "release:" "must trigger on release"
  assert_contains "$pin" "types: [published]" "must trigger on published releases"
  assert_contains "$pin" "workflow_dispatch:" "must support manual backfill"
  assert_contains "$pin" "tag:" "backfill must accept an optional tag input"
  assert_contains "$pin" "required: false" "the tag input must be optional (defaults to latest release)"
  assert_contains "$pin" "gh release view" "omitted tag must fall back to the latest release"
}

test_pin_reads_plugin_name_from_manifest() {
  assert_contains "$pin" "jq -r '.name' .claude-plugin/plugin.json" "plugin name must come from plugin.json, never hardcoded"
  # The plugin's own name must not appear as a hardcoded pin target anywhere.
  case "$pin" in
    *'--arg name "workbench-ynab"'*) fail "plugin name must not be hardcoded in the jq pin" ;;
  esac
}

test_pin_dereferences_annotated_tags() {
  assert_contains "$pin" "git/refs/tags/" "must resolve the tag ref"
  assert_contains "$pin" 'git/tags/$OBJECT_SHA' "must dereference annotated tags to the commit SHA"
}

test_pin_targets_marketplace() {
  assert_contains "$pin" "mike-bronner/claude-workbench" "must push to the marketplace repo"
  assert_contains "$pin" ".claude-plugin/marketplace.json" "must edit the marketplace manifest"
  assert_contains "$pin" ".source.sha = " "must set source.sha for the matching entry"
}

test_pin_fails_loudly_without_token() {
  assert_contains "$pin" "DEVELOPER_SETTINGS_TOKEN" "must use the cross-repo PAT secret"
  assert_contains "$pin" "::error::DEVELOPER_SETTINGS_TOKEN secret is not set" "missing token must be a hard ::error::"
  # The error branch must exit non-zero — never silently skip the push.
  guard=$(awk '/DEVELOPER_SETTINGS_TOKEN secret is not set/{f=1} f{print} f && /exit 1/{exit}' "$PIN")
  assert_contains "$guard" "exit 1" "missing token must exit 1"
}

test_pin_noop_paths_exit_zero() {
  assert_contains "$pin" "nothing to pin" "unmatched plugin name must be a silent no-op"
  assert_contains "$pin" "git diff --cached --quiet" "already-pinned SHA must be detected"
  assert_contains "$pin" "already pinned" "already-pinned SHA must be a silent no-op"
}

test_pin_concurrency_and_permissions() {
  assert_contains "$pin" "group: update-marketplace-sha" "concurrency group must be 'update-marketplace-sha'"
  assert_contains "$pin" "cancel-in-progress: false" "a running pin must never be cancelled"
  assert_contains "$pin" "contents: read" "workflow permissions stay read-only (the PAT does the cross-repo write)"
}

# --- documentation contract ---------------------------------------------------

test_ci_doc_documents_the_token() {
  assert_file_exists "$CI_DOC"
  doc=$(cat "$CI_DOC")
  assert_contains "$doc" "DEVELOPER_SETTINGS_TOKEN" "docs/ci.md must document the secret"
  assert_contains "$doc" "fine-grained" "must say it is a fine-grained PAT"
  assert_contains "$doc" "Contents: Read and write" "must state the required permission scope"
  assert_contains "$doc" "mike-bronner/claude-workbench" "must scope the token to the marketplace repo"
}

test_security_md_references_ci_secret() {
  assert_contains "$(cat "$REPO_ROOT/SECURITY.md")" "DEVELOPER_SETTINGS_TOKEN" "SECURITY.md must acknowledge the CI secret"
}

run_tests
