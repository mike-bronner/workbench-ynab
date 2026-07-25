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
#   * the guards (SemVer + tag-exists + version monotonicity) stay ahead of
#     every write;
#   * the bundle-integrity proof and the test suite gate BEFORE commit/tag —
#     reordering steps below the tag would ship an unverified release;
#   * the sole version-bump target stays .claude-plugin/plugin.json (issue
#     #75): the frozen vendored marker must never become a bump target, and no
#     wheel/uv build step may reappear from the bujo ancestor;
#   * the supply-chain posture (issue #203): checkout persists no push
#     credential, and the credential appears only later, in the push URL;
#   * the credential-isolation posture (issue #252): the untrusted `assets/`
#     install runs in its own job with no write scope, gating `release` via
#     `needs:` — co-residency, not credential-on-disk, is what a backgrounded
#     dependency process exploits — and the marketplace clone embeds no PAT,
#     supplying it at push time only;
#   * the atomicity of the main+tag push (issue #203) — split back into two
#     pushes, a failed tag push strands a release the monotonicity guard then
#     refuses to re-run;
#   * the sterile-event chain (gh workflow run) that makes the marketplace pin
#     fire at all;
#   * the pin workflow's portability (plugin name read from plugin.json),
#     annotated-tag dereference, manual-backfill tag consumption, loud
#     missing-token and malformed-marketplace failures, silent no-ops, and the
#     bounded rebase/retry that survives a sibling repo's concurrent pin
#     (issue #203);
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
# the fail/no-op tests honest: delete the exit and the test goes red. Keying
# the block on the guard's CONDITION text (polarity included) extends that
# honesty one level up: invert the `if` with a one-character `!` and the
# pattern no longer matches, the block comes back empty, and the assertions
# inside it go red — so condition, error, and exit are pinned as one unit.
# (Patterns must stay backslash-free: awk -v escape-processes backslashes.)
guard_block() { awk -v pat="$1" 'index($0, pat){f=1} f{print} f && /^ *fi$/{exit}' "$2"; }

# step_block <step-name> <next-step-name> <file> — everything from one step's
# `name:` line up to (excluding) the next step's.
step_block() { awk -v from="$1" -v to="$2" 'index($0, to){exit} index($0, from){f=1} f' "$3"; }

# job_block <job-id> <file> — one job's YAML: from its `  <id>:` key through
# the line before the next job key. Job ids sit at exactly two spaces under
# `jobs:`; every key INSIDE a job is indented four or more, so the terminator
# regex cannot match a job's own `permissions:`/`steps:`. Scoping the issue
# #252 assertions to a job (not to the file) is what makes them honest: move
# the untrusted assets install back into the credentialed `release` job and
# the assertions flip sides, red.
job_block() {
  awk -v id="  $1:" '$0 == id {f=1} f && $0 != id && /^  [A-Za-z0-9_-]+:$/ {exit} f' "$2"
}

# job_step_block <job-id> <step-name> <next-step-name> <file> — step_block,
# scoped to a single job. `name: Checkout main` now appears in BOTH jobs
# (issue #252), so a file-wide step_block spans from the assets job's checkout
# into the release job's and would be satisfied by either one's
# `persist-credentials: false` — green with the release job's deleted.
#
# ONE awk over the file, deliberately not `job_block ... | awk`: this suite runs
# under `set -euo pipefail`, and an awk that `exit`s early closes the pipe on an
# upstream awk still block-writing into it — SIGPIPE, 141, and pipefail fails
# the whole test before a single assertion runs. Whether that fires depends on
# buffering, so it passes locally and fails on the runner. No pipe, no race.
job_step_block() {
  awk -v id="  $1:" -v from="$2" -v to="$3" '
    $0 == id { j = 1; next }
    j && /^  [A-Za-z0-9_-]+:$/ { exit }
    j && index($0, to) { exit }
    j && index($0, from) { f = 1 }
    f
  ' "$4"
}

# exec_only <text> — drop comment lines. Negative assertions ("this command
# must NOT appear here") have to run against executable YAML only: the
# rationale comments deliberately quote the very patterns they forbid.
exec_only() { printf '%s\n' "$1" | grep -v '^ *#' || true; }

# cont_block <pattern> <text> — one shell command in full: the first line
# containing <pattern> plus every backslash-continued line after it. Keying a
# clone/push URL assertion to the whole command (not one hand-picked line)
# survives reformatting — collapse the continuation onto one line and the
# assertions still see the URL.
cont_block() {
  printf '%s\n' "$2" | awk -v pat="$1" 'index($0, pat){f=1} f{print} f && !/\\$/{exit}'
}

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
  # Key the block on the condition itself, `!` included: inverting the guard
  # (accept garbage, reject valid versions) empties the block and goes red.
  # The needle is the literal workflow text — $NEW_VERSION expands on the runner.
  # shellcheck disable=SC2016
  guard=$(guard_block 'if ! [[ "$NEW_VERSION" =~' "$RELEASE")
  # shellcheck disable=SC2016
  [ -n "$guard" ] || fail 'the SemVer guard must reject on: if ! [[ "$NEW_VERSION" =~ ...'
  assert_contains "$guard" '=~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]' "must validate SemVer X.Y.Z"
  assert_contains "$guard" "::error::Version must be SemVer" "rejection must be an ::error:: annotation"
  assert_contains "$guard" "exit 1" "an invalid version must exit 1, not merely print the error"
}

test_release_tag_exists_guard() {
  # Key the block on the condition, polarity and all: `if git rev-parse`
  # succeeds when the tag EXISTS — an inverted `!` would re-tag existing
  # versions and abort every legitimate release.
  # The needle is the literal workflow text — $NEW_VERSION expands on the runner.
  # shellcheck disable=SC2016
  guard=$(guard_block 'if git rev-parse "v$NEW_VERSION"' "$RELEASE")
  # shellcheck disable=SC2016
  [ -n "$guard" ] || fail 'the tag-exists guard must abort on: if git rev-parse "v$NEW_VERSION"'
  assert_contains "$guard" "::error::Tag v" "tag-exists rejection must be an ::error:: annotation"
  assert_contains "$guard" "exit 1" "an existing tag must exit 1, not merely print the error"
}

test_release_version_monotonicity_guard() {
  # "Versions go forward only" must be enforced, not just documented: a lower
  # (or equal) never-tagged version passes SemVer + tag-exists and would
  # downgrade plugin.json, tag it, and pin the marketplace to the regression.
  # Key the block on the equality half of the condition, polarity included;
  # the sort -V half is pinned inside the block, its != polarity included.
  # Needles are literal workflow text — $NEW_VERSION/$CURRENT expand on the runner.
  # shellcheck disable=SC2016
  guard=$(guard_block 'if [ "$NEW_VERSION" = "$CURRENT" ] ||' "$RELEASE")
  # shellcheck disable=SC2016
  [ -n "$guard" ] || fail 'the monotonicity guard must reject on: if [ "$NEW_VERSION" = "$CURRENT" ] || ...'
  # shellcheck disable=SC2016
  assert_contains "$guard" 'sort -V | tail -1)" != "$NEW_VERSION"' "the new version must be the sort -V max of {current, new}"
  assert_contains "$guard" "::error::Versions go forward only" "a downgrade must be an ::error:: annotation"
  assert_contains "$guard" "exit 1" "a downgrade must exit 1, not merely print the error"
}

test_release_guards_precede_writes() {
  # All three guards (SemVer + tag-exists + monotonicity) live in the single
  # "Validate version" step — pin that STEP ahead of every write, then pin
  # each guard's condition INSIDE it. Relocating any one guard below a write
  # moves its condition out of this step's block and goes red; ordering the
  # step alone (or one guard's message text, as before) would not.
  validate=$(first_line "name: Validate version" "$RELEASE")
  bump=$(first_line "name: Bump version" "$RELEASE")
  commit=$(first_line "name: Commit, tag, push" "$RELEASE")
  [ "$validate" -lt "$bump" ] || fail "Validate version step (line $validate) must precede the version bump (line $bump)"
  [ "$bump" -lt "$commit" ] || fail "version bump (line $bump) must precede commit/tag (line $commit)"
  # Scope to the release job: `name: Set up Node` also names a step in the
  # assets-tests job ABOVE this one (issue #252), and a file-wide step_block
  # would hit that terminator first and come back empty.
  step=$(job_step_block "release" "name: Validate version" "name: Set up Node" "$RELEASE")
  [ -n "$step" ] || fail "the release job must have a 'Validate version' step"
  # Needles are literal workflow text — $NEW_VERSION/$CURRENT expand on the runner.
  # shellcheck disable=SC2016
  assert_contains "$step" 'if ! [[ "$NEW_VERSION" =~' "the SemVer guard must live inside the Validate version step"
  # shellcheck disable=SC2016
  assert_contains "$step" 'if git rev-parse "v$NEW_VERSION"' "the tag-exists guard must live inside the Validate version step"
  # shellcheck disable=SC2016
  assert_contains "$step" 'if [ "$NEW_VERSION" = "$CURRENT" ] ||' "the monotonicity guard must live inside the Validate version step"
}

# --- release.yml: frozen bundle, sole bump target ----------------------------

test_release_gates_on_the_tree_the_assets_suite_tested() {
  # The issue #252 job split buys isolation at the cost of a SECOND checkout of
  # a moving `main`: without this re-check, the assets/ suite could pass on one
  # tree while a later commit is the one bumped, tagged and released. The
  # single-job version could not drift; this restores that guarantee.
  assets_job=$(job_block "assets-tests" "$RELEASE")
  assert_contains "$assets_job" "outputs:" "the assets-tests job must publish the commit it tested"
  assert_contains "$assets_job" "sha: \${{ steps.tested.outputs.sha }}" "the published output must be the recorded SHA"
  # Needles are literal workflow text — $(git rev-parse HEAD) runs on the runner.
  # shellcheck disable=SC2016
  assert_contains "$assets_job" 'sha=$(git rev-parse HEAD)' "the tested commit must be read from the checked-out tree, not assumed"
  # Key the block on the condition, polarity included: inverted, it aborts
  # every healthy release and waves through exactly the drift it exists to
  # catch. The -z half is the fail-closed limb — a gate that cannot read its
  # input has not passed.
  # Needles are literal workflow text — $TESTED_SHA/$HEAD_SHA expand on the runner.
  # shellcheck disable=SC2016
  guard=$(guard_block 'if [ -z "$TESTED_SHA" ] || [ "$TESTED_SHA" != "$HEAD_SHA" ]' "$RELEASE")
  # shellcheck disable=SC2016
  [ -n "$guard" ] || fail 'the drift gate must abort on: if [ -z "$TESTED_SHA" ] || [ "$TESTED_SHA" != "$HEAD_SHA" ]'
  assert_contains "$guard" "::error::" "a moved main must be an ::error:: annotation"
  assert_contains "$guard" "exit 1" "a moved main must exit 1, never fall through into the release"
  # It is only a gate if it runs ahead of the writes.
  gate=$(first_line "name: Assert main has not moved" "$RELEASE")
  bump=$(first_line "name: Bump version" "$RELEASE")
  [ -n "$gate" ] || fail "the release job must re-check main against the tested SHA"
  [ "$gate" -lt "$bump" ] || fail "the drift gate (line $gate) must run before the version bump (line $bump)"
}

test_release_bumps_plugin_json_only() {
  bump_step=$(awk '/name: Bump version/{f=1} f && /name: Run the test suite/{exit} f' "$RELEASE")
  # Scope the positive assertion to the bump step itself — anywhere-in-file
  # is satisfied by the header comment alone, so it would stay green even if
  # the bump were rewritten to target the wrong file. Pinning the write
  # (`mv` destination) inside the step is what makes this test honest.
  assert_contains "$bump_step" "mv tmp.json .claude-plugin/plugin.json" "the bump step's write target must be .claude-plugin/plugin.json"
  # Issue #75: the vendored marker is frozen provenance — never a bump target.
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
  # Shell flags, stated accurately (issue #203): Actions runs every `run:`
  # under a `bash -e {0}` wrapper, so `-e` is ALWAYS active and `set` can only
  # add flags — the step is NOT `-e`-less, as an earlier comment here and in
  # the workflow both claimed. `set -euo pipefail` says so explicitly, and
  # matches every other step in the file. Consequence for the guard below: a
  # failed `source` aborts on `-e`, while a drifted bundle returns non-zero
  # from an `if !` condition, which `-e` deliberately exempts — so the guard is
  # what turns that specific case into a polished ::error:: abort.
  integrity=$(step_block "name: Verify vendored bundle integrity" "name: Bump version" "$RELEASE")
  assert_contains "$integrity" "set -euo pipefail" "the integrity step must declare -euo pipefail (-e is active regardless, under Actions' bash -e wrapper)"
  # Key the block on the condition, `!` included: inverted, a drifted bundle
  # sails through while a good one is blocked — the block comes back empty and
  # the test goes red.
  guard=$(guard_block 'if ! bi_assert_integrity' "$RELEASE")
  [ -n "$guard" ] || fail "the integrity guard must abort on: if ! bi_assert_integrity"
  assert_contains "$guard" "::error::Vendored bundle integrity check failed" "a drift must fail with a descriptive error"
  assert_contains "$guard" "exit 1" "a drifted bundle must exit 1 — nothing else converts it into a release abort"
}

# --- release.yml: tests gate the release -------------------------------------

test_release_runs_test_suite_before_tagging() {
  # Order the STEPS by their `name:` lines, never by their command text: the
  # commands are also quoted in the surrounding rationale comments, so a
  # command-keyed first_line resolves to prose and reports a bogus ordering.
  suite=$(first_line "run: bash scripts/test.sh" "$RELEASE")
  commit=$(first_line "name: Commit, tag, push" "$RELEASE")
  [ -n "$suite" ] || fail "must run the single suite entrypoint (run: bash scripts/test.sh)"
  [ "$suite" -lt "$commit" ] || fail "test suite (line $suite) must gate before commit/tag (line $commit)"
  # The offline-boot proof inside scripts/test.sh is only faithful with NO
  # node_modules on the resolution path. Since issue #252 that is a separate-VM
  # guarantee rather than a step-ordering one — the assets/ install lives in the
  # `assets-tests` job — so what has to hold here is that the release job
  # installs nothing at all. Gating of the assets suite is asserted by
  # test_release_assets_suite_is_isolated_from_the_push_credential.
  release_exec=$(exec_only "$(job_block "release" "$RELEASE")")
  case "$release_exec" in
    *"npm "*) fail "the release job must install/run no npm packages — node_modules would break the offline-boot proof and untrusted install scripts would share a runner with the push credential (issue #252)" ;;
  esac
}

# --- release.yml: commit / tag / release / chain -----------------------------

test_release_commits_as_actions_bot() {
  assert_contains "$release" 'git config user.name "github-actions[bot]"' "must commit as github-actions[bot]"
  assert_contains "$release" "41898282+github-actions[bot]@users.noreply.github.com" "must use the bot noreply email"
}

test_release_annotated_tag_and_atomic_push() {
  # Needles are literal workflow text — ${NEW_VERSION} expands on the runner.
  # shellcheck disable=SC2016
  assert_contains "$release" 'git tag -a "v${NEW_VERSION}"' "tag must be annotated"
  # Issue #203: main and the tag must land in ONE atomic push. As two
  # sequential pushes they are not atomic — a tag push failing after main was
  # already bumped strands the release half-done, and the monotonicity guard
  # then rejects a same-version re-run ($NEW_VERSION = $CURRENT), leaving no
  # automated tag-backfill path. Scope every assertion to the push step so a
  # header comment cannot satisfy them.
  push=$(step_block "name: Commit, tag, push" "name: Create GitHub release" "$RELEASE")
  assert_contains "$push" "git push --atomic" "main and the tag must be pushed in a single atomic transaction"
  assert_contains "$push" "refs/heads/main:refs/heads/main" "the atomic push must carry main"
  # shellcheck disable=SC2016
  assert_contains "$push" 'refs/tags/v${NEW_VERSION}:refs/tags/v${NEW_VERSION}' "the atomic push must carry the tag"
  # Exactly ONE push in the step. This is the assertion that actually pins
  # atomicity: splitting the refs back into `git push origin main` +
  # `git push origin "v$NEW_VERSION"` keeps all three needles above satisfiable
  # in comments but takes this count to 2 and goes red.
  count=$(printf '%s\n' "$push" | grep -c "git push" || true)
  assert_eq "1" "$count" "the commit/tag/push step must contain exactly one git push (found $count)"
}

test_release_checkout_persists_no_credential_for_untrusted_deps() {
  # Issue #203 — supply chain; defence in depth since the #252 job split.
  # actions/checkout defaults to writing the job's GITHUB_TOKEN (this workflow
  # grants it contents: write + actions: write) into .git/config, where it
  # lives for the whole job. persist-credentials: false leaves nothing on disk
  # to steal. Scope to the RELEASE job's checkout: `name: Checkout main` now
  # appears in both jobs, and a file-wide step_block would stay green on the
  # assets job's copy alone.
  checkout=$(job_step_block "release" "name: Checkout main" "name: Validate version" "$RELEASE")
  [ -n "$checkout" ] || fail "the release job must check out main"
  assert_contains "$checkout" "persist-credentials: false" \
    "the release job's checkout must not persist the push credential into .git/config"
  # The credential must then be supplied explicitly at push time instead —
  # otherwise persist-credentials: false just breaks the release.
  push=$(step_block "name: Commit, tag, push" "name: Create GitHub release" "$RELEASE")
  # The needle is literal workflow text — ${GH_TOKEN}/${GITHUB_REPOSITORY}
  # expand on the runner.
  # shellcheck disable=SC2016
  assert_contains "$push" 'https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git' \
    "the release push must authenticate explicitly, since checkout persists no credential"
  # The credential must materialize exactly ONCE, in that push URL. A second
  # occurrence is a second place it can leak from.
  # shellcheck disable=SC2016
  count=$(grep -cF 'x-access-token:${GH_TOKEN}' "$RELEASE" || true)
  assert_eq "1" "$count" "the push credential must appear exactly once, in the push URL (found $count)"
}

test_release_assets_suite_is_isolated_from_the_push_credential() {
  # Issue #252 — the residual #203 could not reach. `npm --prefix assets ci`
  # runs third-party install scripts and `npm --prefix assets test` runs their
  # module top-level code. Co-resident with the push credential — same runner,
  # same UID — neither persist-credentials: false nor threading the token
  # through env: helps: Actions does not reap detached children at step
  # boundaries, so a dep can background a process that outlives its own step
  # and read the token out of the push process's argv (/proc/<pid>/cmdline) or
  # environment (/proc/<pid>/environ). Only a job with no write scope removes
  # the token from existence anywhere near that code.
  assets_job=$(job_block "assets-tests" "$RELEASE")
  [ -n "$assets_job" ] || fail "the assets/ suite must live in its own 'assets-tests' job (issue #252)"
  assert_contains "$assets_job" "npm --prefix assets ci" "the assets-tests job must install assets/ deps"
  assert_contains "$assets_job" "npm --prefix assets test" "the assets-tests job must run the assets/ suite"
  # The override is the whole point: without its own permissions: block the job
  # inherits the workflow's contents: write + actions: write and the split buys
  # nothing. Assert the grant AND the absence of any write scope.
  assert_contains "$assets_job" "permissions:" "the assets-tests job must declare its own permissions: block, or it inherits contents: write + actions: write"
  assert_contains "$assets_job" "contents: read" "the assets-tests job must be scoped to contents: read"
  case "$(exec_only "$assets_job")" in
    *": write"*) fail "the assets-tests job must grant no write scope — it executes untrusted third-party code (issue #252)" ;;
  esac
  # It must gate the release, not merely run beside it: without `needs:` the
  # split moves the suite OFF the release path instead of ahead of it, and a
  # red assets suite would no longer stop the tag.
  release_job=$(job_block "release" "$RELEASE")
  [ -n "$release_job" ] || fail "release.yml must define a 'release' job"
  assert_contains "$(exec_only "$release_job")" "needs: assets-tests" \
    "the release job must gate on assets-tests via needs:, or the assets suite stops gating the release"
  # And the untrusted install must not have stayed behind in the credentialed
  # job. Comments stripped — the rationale prose names the very command it
  # forbids, so an unstripped match would pass on the comment alone.
  case "$(exec_only "$release_job")" in
    *"npm --prefix assets"*) fail "the release job must not run the assets/ suite — it is the job that holds the push credential (issue #252)" ;;
  esac
}

test_release_fails_on_noop_bump() {
  # An empty stage means the bump silently did nothing — the release must
  # abort, not commit an empty change and tag it. Key the block on the
  # condition: `git diff --cached --quiet` succeeds when NOTHING is staged —
  # an inverted `!` would abort every real release and tag the no-ops.
  guard=$(guard_block 'if git diff --cached --quiet' "$RELEASE")
  [ -n "$guard" ] || fail "the no-op guard must abort on: if git diff --cached --quiet"
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
  # AC #8: the diff must be a clickable compare URL, not inline code — and it
  # must only be BUILT when a previous tag exists (first release has nothing
  # to compare against; an ungated build emits a malformed Diff line). Keying
  # the block on the gate pins both: drop the gate and the block is empty.
  # Needles are literal workflow text — ${PREV_TAG}/${NEW_VERSION} expand on the runner.
  # shellcheck disable=SC2016
  compare=$(guard_block 'if [ -n "$PREV_TAG" ]' "$RELEASE")
  # shellcheck disable=SC2016
  [ -n "$compare" ] || fail 'the compare URL must be gated on: if [ -n "$PREV_TAG" ]'
  # shellcheck disable=SC2016
  assert_contains "$compare" '/compare/${PREV_TAG}...v${NEW_VERSION}' "diff must be a compare URL GitHub renders as a link, built only when a previous tag exists"
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
  # The latest-release lookup must be the ELSE fallback of the tag resolution
  # (dispatch with no tag). Rewired into the release-event branch, a real
  # backfill would resolve an empty TAG from the empty $RELEASE_TAG and
  # corrupt the pin — so scope the assertion to the else branch itself.
  # The needle is the literal workflow text — $EVENT_NAME expands on the runner.
  # shellcheck disable=SC2016
  resolve=$(guard_block 'if [ "$EVENT_NAME" = "release" ]' "$PIN")
  # shellcheck disable=SC2016
  [ -n "$resolve" ] || fail 'tag resolution must branch on: if [ "$EVENT_NAME" = "release" ]'
  fallback=$(printf '%s\n' "$resolve" | awk '/^ *else$/{f=1} f')
  assert_contains "$fallback" "gh release view" "omitted tag must fall back to the latest release in the else branch"
  # A SUPPLIED dispatch tag must actually be consumed. Asserting only that the
  # `tag:` input exists and that the else-branch falls back leaves the middle
  # branch unpinned: delete the `elif` and manual backfill silently resolves
  # the latest release instead of the requested one, with the suite still
  # green. Scope the assertion to the elif branch itself so the assignment
  # cannot be satisfied from the release branch above it.
  # Needles are literal workflow text — $INPUT_TAG expands on the runner, and
  # awk -v escape-processes backslashes, so patterns stay backslash-free.
  # shellcheck disable=SC2016
  backfill=$(printf '%s\n' "$resolve" | awk -v pat='elif [ -n "$INPUT_TAG" ]; then' 'index($0, pat){f=1} f && /^ *else$/{exit} f')
  # shellcheck disable=SC2016
  [ -n "$backfill" ] || fail 'manual backfill must branch on: elif [ -n "$INPUT_TAG" ]; then'
  # shellcheck disable=SC2016
  assert_contains "$backfill" 'TAG="$INPUT_TAG"' "a supplied dispatch tag must be consumed, not ignored in favour of the latest release"
}

test_pin_push_retries_on_cross_repo_race() {
  # Issue #203: `concurrency: update-marketplace-sha` serializes runs within
  # THIS repo only, while every sibling workbench plugin pins its own entry in
  # the SAME marketplace repo. A sibling's commit landing between our clone and
  # our push makes ours non-fast-forward, and a bare `git push` would fail the
  # pin outright. Scope to the push step so header prose cannot satisfy this.
  update=$(awk 'index($0, "name: Update marketplace.json"){f=1} f' "$PIN")
  assert_contains "$update" "git pull --rebase" "a rejected push must re-sync onto the marketplace tip before retrying"
  assert_contains "$update" "MAX_PUSH_ATTEMPTS" "the retry must be bounded, never an unbounded loop"
  # The retry must be a LOOP around the push, not one hopeful second attempt:
  # pin the push INSIDE the while body. Unrolling it back to a single push
  # leaves the loop empty of `git push` and goes red.
  loop=$(printf '%s\n' "$update" | awk '/^ *while true; do$/{f=1} f && /^ *done$/{exit} f')
  [ -n "$loop" ] || fail "the marketplace push must sit inside a bounded retry loop (while true; do ... done)"
  # The push authenticates by explicit URL, not through `origin` (issue #252) —
  # see test_pin_clone_persists_no_credential.
  # The needle is literal workflow text — $PUSH_URL expands on the runner.
  # shellcheck disable=SC2016
  assert_contains "$loop" 'if git push "$PUSH_URL"' "the push itself must be the loop's success condition"
  assert_contains "$loop" "exit 0" "a successful push must exit 0 from inside the loop"
  # Exhausting the budget is a hard failure — a pin that silently gives up
  # leaves the marketplace floating on a stale SHA while the release looks green.
  # shellcheck disable=SC2016
  assert_contains "$loop" 'if [ "$attempt" -ge "$MAX_PUSH_ATTEMPTS" ]; then' "the attempt budget must be checked, not just declared"
  budget=$(printf '%s\n' "$loop" | awk -v pat='-ge "$MAX_PUSH_ATTEMPTS" ]; then' 'index($0, pat){f=1} f && /^ *fi$/{exit} f')
  assert_contains "$budget" "::error::" "an exhausted retry budget must be a hard ::error::"
  assert_contains "$budget" "exit 1" "an exhausted retry budget must exit 1, never fall through as a silent no-op"
  # A conflicting rebase must abort rather than force the pin over a sibling's write.
  conflict=$(printf '%s\n' "$loop" | awk '/if ! git pull --rebase; then/{f=1} f && /^ *fi$/{exit} f')
  [ -n "$conflict" ] || fail "a failed rebase must be handled on: if ! git pull --rebase; then"
  assert_contains "$conflict" "git rebase --abort" "a conflicted rebase must be aborted, leaving no half-rebased state"
  assert_contains "$conflict" "exit 1" "a conflicted rebase must fail loudly, never force the pin"
  case "$update" in
    *"push --force"*|*"push -f "*) fail "the marketplace pin must never force-push over a sibling repo's write" ;;
  esac
}

test_pin_clone_persists_no_credential() {
  # Issue #252. A credential embedded in the clone URL is written straight into
  # marketplace/.git/config as the `origin` remote — leaving
  # DEVELOPER_SETTINGS_TOKEN (a long-lived, non-expiring PAT with Contents:
  # write on the SHARED marketplace repo, materially higher-value than a
  # job-scoped GITHUB_TOKEN) readable on disk for the rest of the step. Clone
  # unauthenticated; supply it only at push time, as release.yml now does.
  #
  # Every assertion runs against executable YAML with comments stripped: the
  # rationale comment above the clone quotes the exact pattern being forbidden,
  # so an unstripped check would fail on its own explanation.
  update_exec=$(exec_only "$(awk 'index($0, "name: Update marketplace.json"){f=1} f' "$PIN")")
  clone=$(cont_block "git clone" "$update_exec")
  [ -n "$clone" ] || fail "the pin must clone the marketplace repo"
  assert_contains "$clone" "https://github.com/mike-bronner/claude-workbench.git" \
    "the marketplace clone URL must be the plain, unauthenticated HTTPS URL"
  case "$clone" in
    *x-access-token*) fail "the marketplace clone must embed no credential — it persists into marketplace/.git/config for the whole step (issue #252)" ;;
  esac
  # The credential must still reach the push, or this just breaks the pin.
  # The needle is literal workflow text — ${GH_TOKEN} expands on the runner.
  # shellcheck disable=SC2016
  assert_contains "$update_exec" 'PUSH_URL="https://x-access-token:${GH_TOKEN}@github.com/mike-bronner/claude-workbench.git"' \
    "the PAT must be supplied at push time, in the push URL"
  # Exactly one occurrence: this is what pins "at push time ONLY". Restore the
  # authenticated clone and the count goes to 2 — red — even though every
  # positive assertion above would still be satisfiable.
  count=$(printf '%s\n' "$update_exec" | grep -cF 'x-access-token' || true)
  assert_eq "1" "$count" "the PAT must materialize exactly once, in the push URL (found $count)"
  # Pushing by URL is only credential-free if `origin` itself never acquires
  # the token: a remote rewrite would persist it exactly as the clone did.
  case "$update_exec" in
    *"remote set-url"*|*"remote add"*) fail "the marketplace remote must not be rewritten with a credential — that re-persists the PAT into .git/config (issue #252)" ;;
  esac
}

test_pin_refuses_to_push_a_detached_head() {
  # Pushing by explicit URL (issue #252) means naming the destination ref
  # ourselves — so it has to be named correctly. A detached HEAD resolves to
  # the literal "HEAD" and would create refs/heads/HEAD on the repo shared with
  # every other workbench plugin. Fail closed. Key the block on the condition,
  # polarity included: inverted, it aborts every healthy run and pushes the
  # junk ref on the broken one.
  # Needles are literal workflow text — $PUSH_BRANCH expands on the runner.
  # shellcheck disable=SC2016
  guard=$(guard_block 'if [ -z "$PUSH_BRANCH" ] || [ "$PUSH_BRANCH" = "HEAD" ]' "$PIN")
  # shellcheck disable=SC2016
  [ -n "$guard" ] || fail 'the push ref must be guarded on: if [ -z "$PUSH_BRANCH" ] || [ "$PUSH_BRANCH" = "HEAD" ]'
  assert_contains "$guard" "::error::" "a detached HEAD must be a hard ::error::"
  assert_contains "$guard" "exit 1" "a detached HEAD must exit 1, never fall through into the push"
  # The guard is only meaningful ahead of the push it protects.
  # shellcheck disable=SC2016
  guard_line=$(first_line 'if [ -z "$PUSH_BRANCH" ]' "$PIN")
  # shellcheck disable=SC2016
  push_line=$(first_line 'if git push "$PUSH_URL"' "$PIN")
  [ "$guard_line" -lt "$push_line" ] || fail "the detached-HEAD guard (line $guard_line) must precede the push (line $push_line)"
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
  # The deref must live INSIDE the annotated-tag branch — release.yml creates
  # annotated tags (git tag -a), so this branch runs on EVERY release. An
  # inverted polarity would pin the tag-object SHA, not the commit SHA, to
  # the public marketplace. Keying the block on the condition pins both.
  # Needles are literal workflow text — $OBJECT_TYPE/$OBJECT_SHA expand on the runner.
  # shellcheck disable=SC2016
  deref=$(guard_block 'if [ "$OBJECT_TYPE" = "tag" ]' "$PIN")
  # shellcheck disable=SC2016
  [ -n "$deref" ] || fail 'the deref must be gated on: if [ "$OBJECT_TYPE" = "tag" ]'
  # shellcheck disable=SC2016
  assert_contains "$deref" 'git/tags/$OBJECT_SHA' "must dereference annotated tags to the commit SHA inside the tag branch"
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

test_pin_fails_loudly_on_malformed_marketplace() {
  # jq -e exits 1 on "name not found" but 5 on a runtime error (.plugins
  # missing/null/not an array), and `if !` cannot tell them apart — so shape
  # is validated separately, BEFORE membership: a broken upstream manifest
  # must be a hard ::error::, never a benign "nothing to pin".
  shape=$(guard_block "if ! jq -e '.plugins | type == \"array\"'" "$PIN")
  [ -n "$shape" ] || fail "marketplace shape must be validated on: if ! jq -e '.plugins | type == \"array\"'"
  assert_contains "$shape" "::error::" "a malformed marketplace.json must be a hard ::error::"
  assert_contains "$shape" "exit 1" "a malformed marketplace.json must exit 1, never no-op"
  shape_line=$(first_line 'type == "array"' "$PIN")
  # The needle is the literal workflow text — $name is a jq variable, never shell.
  # shellcheck disable=SC2016
  member_line=$(first_line 'index($name)' "$PIN")
  [ "$shape_line" -lt "$member_line" ] || fail "shape validation (line $shape_line) must precede the membership check (line $member_line)"
}

test_pin_noop_paths_exit_zero() {
  # Key each no-op block on its CONDITION (polarity included), not its echo
  # text — a message-keyed window starts AFTER the `if` line, so it stays
  # green when the polarity flips (no-op firing on found / real pins skipped).
  # The needle is the literal workflow text — $PLUGIN_NAME expands on the runner.
  # shellcheck disable=SC2016
  noop=$(guard_block 'if ! jq -e --arg name "$PLUGIN_NAME"' "$PIN")
  # shellcheck disable=SC2016
  [ -n "$noop" ] || fail 'the unmatched-name no-op must be gated on: if ! jq -e --arg name "$PLUGIN_NAME"'
  assert_contains "$noop" "nothing to pin" "unmatched plugin name must say there is nothing to pin"
  assert_contains "$noop" "exit 0" "unmatched plugin name must exit 0 (silent no-op)"
  noop=$(guard_block 'if git diff --cached --quiet' "$PIN")
  [ -n "$noop" ] || fail 'the already-pinned no-op must be gated on: if git diff --cached --quiet'
  assert_contains "$noop" "already pinned" "an unchanged stage must report the SHA as already pinned"
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
