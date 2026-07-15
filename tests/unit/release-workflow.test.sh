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

# guard_block <pattern> <file> — the guard's if-block: from the first line
# containing <pattern> (fixed string) through the closing `fi`. Asserting the
# guard's `exit` INSIDE this block (not anywhere in the file) is what makes
# the fail/no-op tests honest: delete the exit and the test goes red.
guard_block() { awk -v pat="$1" 'index($0, pat){f=1} f{print} f && /^ *fi$/{exit}' "$2"; }

# step_block <step-name> <next-step-name> <file> — everything from one step's
# `name:` line up to (excluding) the next step's.
step_block() { awk -v from="$1" -v to="$2" 'index($0, to){exit} index($0, from){f=1} f' "$3"; }

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
  guard=$(guard_block "Version must be SemVer" "$RELEASE")
  assert_contains "$guard" "exit 1" "an invalid version must exit 1, not merely print the error"
}

test_release_tag_exists_guard() {
  # The needle is the literal workflow text — $NEW_VERSION expands on the runner.
  # shellcheck disable=SC2016
  assert_contains "$release" 'git rev-parse "v$NEW_VERSION"' "must check the tag does not already exist"
  assert_contains "$release" "::error::Tag v" "tag-exists rejection must be an ::error:: annotation"
  guard=$(guard_block "::error::Tag v" "$RELEASE")
  assert_contains "$guard" "exit 1" "an existing tag must exit 1, not merely print the error"
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
  # The integrity step runs WITHOUT `set -e`, so this exit 1 is the SOLE thing
  # that aborts a release on a drifted bundle — it must exist inside the guard.
  guard=$(guard_block "Vendored bundle integrity check failed" "$RELEASE")
  assert_contains "$guard" "exit 1" "a drifted bundle must exit 1 — nothing else stops the release"
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
  # Needles are literal workflow text — ${NEW_VERSION} expands on the runner.
  # shellcheck disable=SC2016
  assert_contains "$release" 'git tag -a "v${NEW_VERSION}"' "tag must be annotated"
  assert_contains "$release" "git push origin main" "must push main"
  # shellcheck disable=SC2016
  assert_contains "$release" 'git push origin "v${NEW_VERSION}"' "must push the tag"
}

test_release_fails_on_noop_bump() {
  # An empty stage means the bump silently did nothing — the release must
  # abort, not commit an empty change and tag it.
  guard=$(guard_block "No changes staged" "$RELEASE")
  assert_contains "$guard" "::error::" "a no-op bump must be an ::error:: annotation"
  assert_contains "$guard" "exit 1" "a no-op bump must exit 1"
}

test_release_creates_github_release() {
  # Needles are literal workflow text — ${NEW_VERSION}/${DESC}/${PREV_TAG}
  # expand on the runner, never here.
  # shellcheck disable=SC2016
  assert_contains "$release" 'gh release create "v${NEW_VERSION}"' "must create the GitHub release"
  # shellcheck disable=SC2016
  assert_contains "$release" '--title "v${NEW_VERSION} — ${DESC}"' "release title must be 'vX.Y.Z — description'"
  # Scope the pin reference to the release-notes step itself — anywhere-in-file
  # would be satisfied by the header comment alone (the explicit trigger is
  # covered by test_release_chains_marketplace_pin_explicitly).
  notes=$(step_block "name: Create GitHub release" "name: Trigger marketplace SHA pin" "$RELEASE")
  assert_contains "$notes" "update-marketplace-sha.yml" "release notes must mention the auto-pin"
  # AC #8: the diff must be a clickable compare URL, not inline code.
  # shellcheck disable=SC2016
  assert_contains "$notes" '/compare/${PREV_TAG}...v${NEW_VERSION}' "diff must be a compare URL GitHub renders as a link"
  # PREV_TAG must exclude exactly the new tag: unanchored grep would also drop
  # e.g. v1.2.30 when releasing v1.2.3.
  # shellcheck disable=SC2016
  assert_contains "$notes" 'grep -vFx "v${NEW_VERSION}"' "previous-tag lookup must be fixed-string, whole-line anchored"
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
  # The needle is the literal workflow text — $OBJECT_SHA expands on the runner.
  # shellcheck disable=SC2016
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
  # Polarity matters: the guard must fire when the token is EMPTY (-z) — an
  # inverted -n would error on every healthy run and pass on the broken one.
  # The needle is the literal workflow text — ${GH_TOKEN:-} expands on the runner.
  # shellcheck disable=SC2016
  assert_contains "$pin" 'if [ -z "${GH_TOKEN:-}" ]' "the token guard must test emptiness (-z)"
  # The error branch must exit non-zero — never silently skip the push.
  guard=$(guard_block "DEVELOPER_SETTINGS_TOKEN secret is not set" "$PIN")
  assert_contains "$guard" "exit 1" "missing token must exit 1"
}

test_pin_noop_paths_exit_zero() {
  # Each no-op branch must actually exit 0 — asserting only the message
  # strings would stay green if the exits flipped to 1.
  noop=$(guard_block "nothing to pin" "$PIN")
  assert_contains "$noop" "exit 0" "unmatched plugin name must exit 0 (silent no-op)"
  assert_contains "$pin" "git diff --cached --quiet" "already-pinned SHA must be detected"
  noop=$(guard_block "already pinned" "$PIN")
  assert_contains "$noop" "exit 0" "already-pinned SHA must exit 0 (silent no-op)"
}

test_no_expression_splices_in_run_scripts() {
  # ${{ }} is substituted into the script text BEFORE bash parses it, so a
  # crafted tag name or dispatch input would execute as shell on a runner
  # that later holds the cross-repo PAT. Every dynamic value must thread
  # through env: and be read as a quoted shell variable.
  for wf in "$RELEASE" "$PIN"; do
    scripts=$(awk '/^ *run: \|/{f=1; next} f && $0 != "" && $0 !~ /^          /{f=0} f' "$wf")
    inline=$(grep -E '^[[:space:]]*run: [^|]' "$wf" || true)
    # The ${{ pattern is intentionally literal — it is GitHub expression
    # syntax being hunted, never a shell expansion.
    # shellcheck disable=SC2016
    case "$scripts$inline" in
      *'${{'*) fail "$(basename "$wf"): run: scripts must not splice \${{ }} expressions — thread values through env:" ;;
    esac
  done
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
