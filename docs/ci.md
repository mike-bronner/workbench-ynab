# CI and release automation

This repo runs four GitHub Actions workflows. Two gate every push/PR; two
automate releases (issue #74, design M5-5).

| Workflow | Trigger | What it does |
|---|---|---|
| [`ci.yml`](../.github/workflows/ci.yml) | `push` (main), `pull_request` | The lint+test gate — shellcheck + JSON lint, the full bash + Node suite, the bash-3.2 lane, the `assets/` integration suite, and the offline docs-link check. Details below. |
| [`secret-scan.yml`](../.github/workflows/secret-scan.yml) | `push`, `pull_request` | Fails the build on committed credential shapes and on vendored-bundle SHA drift. See [SECURITY.md](../SECURITY.md). |
| [`release.yml`](../.github/workflows/release.yml) | `workflow_dispatch` | One-button release: guards, bundle-integrity proof, version bump, tests, commit + annotated tag + push, GitHub release, then chains the marketplace pin. |
| [`update-marketplace-sha.yml`](../.github/workflows/update-marketplace-sha.yml) | `release: published`, `workflow_dispatch` | Pins the released commit SHA in the claude-workbench marketplace (**cross-repo write** — see below). |

## The PR gate — `ci.yml`

`.github/workflows/ci.yml` (issue #16) is the lint+test gate: it runs on every
`pull_request` and on every `push` to `main`. It replaced the earlier
`test.yml`, whose two jobs moved here unchanged in substance, so one workflow
carries the whole signal. Secret hygiene stays in its own workflow
(`secret-scan.yml` — see `SECURITY.md`), because a credential leak has a
different blast radius than a failing test.

Workflow hygiene, common to all jobs:

- `permissions: contents: read` — the workflow can read the checkout, nothing
  else.
- A `concurrency` group keyed on workflow name + ref with
  `cancel-in-progress: true` — a new push to the same PR supersedes the stale
  run instead of stacking runners.
- First-party `actions/*` actions are pinned to exact majors
  (`actions/checkout@v4`, `actions/setup-node@v5`) — no `@latest`, no floating
  tags. Third-party actions are pinned harder: to a full commit SHA with a
  trailing version comment (`lycheeverse/lychee-action@<sha> # v2.9.0`) — see
  the design decisions below.
- The `test` job runs a two-lane Node matrix: the pinned floor (`24`, canonical value in `vendor/ynab-mcp/NODE_VERSION` — by policy the latest Node LTS major at the last bundle bump, issue #3 / PR #205) and current LTS (`lts/*`). The floor lane boots the vendored bundle on the oldest supported major, so a re-vendor that raises the requirement fails CI before it ships; `tests/unit/node-floor.test.sh` fails if the matrix entry drifts from the canonical floor file. The lanes diverge exactly when a new LTS ships — the cue to bump the floor. Every other job stays single-version.

### The jobs

| Job | Runner | What it checks | A failure means |
|---|---|---|---|
| `lint` | ubuntu | `shellcheck` at **default severity** over every repo-authored `.sh` (`bin/`, `hooks/`, `scripts/`, `tests/` — helpers included), then `jq empty` over every git-tracked `.json` (an empty file list fails closed — the gate never reports success having validated nothing) | A script has a shellcheck finding (any severity fails), a JSON file doesn't parse, or `git ls-files` found no JSON at all |
| `test` | ubuntu (Node floor + `lts/*` matrix) | First the swap-ready tool-name guard (`bin/check-tool-name-sources.sh`, issues #87/#131), then the M2 read-only guard (`scripts/check-readonly.sh`, issue #39 — no callable YNAB write tool and no bare `mcp__ynab__` namespace on any review surface) as explicit fail-fast steps, then the full bash + Node suite via `scripts/test.sh`, including the offline-boot proof (#14) against `node vendor/ynab-mcp/index.cjs` | A concrete YNAB tool name appeared outside the documented allowlist, a read-only review surface can call a write tool (or uses a bare namespace), or a test failed — the runner prints which file; the offline-boot proof failing usually means a bad re-vendor |
| `bash-3-2` | macOS | Every suite carrying the `# bash-3.2-lane:` marker, under the runner's **bash 3.2**: the persona footer-escaping suites (`tests/persona-loader.test.sh`, `tests/unit/html-escape.test.sh`), the shared watchdog (`tests/unit/watchdog.test.sh`), the report writer (`tests/unit/report-writer.test.sh`), the report pruner and path expander (`tests/unit/ynab-prune.test.sh`), the secret-scan guard (`tests/secret-scan.test.sh`), and the `LC_ALL=C` scanning-grep pin (`tests/unit/grep-locale-pin.test.sh`) | The escaping regressed on macOS's default bash while staying green on bash ≥5 (issue #126 AC-3); the watchdog's process-group kill is job-control behaviour, which differs across bash majors (issue #188), and since issue #251 the escaping/report files drive their own call site down that timeout path; a 3.2-only construct or a BSD `find`/`stat`/`grep` branch broke (issues #65, #231) — or a content-scanning grep lost its `LC_ALL=C` pin: an invalid UTF-8 byte defeats every such scan on BSD grep, while GNU grep on the ubuntu lanes only misses the subset it classifies as binary, so four of the six pinned sites are detectable here and nowhere else (issue #270) — or the runner image no longer ships bash 3.2 on PATH (the lane fails loudly rather than test the wrong interpreter) |
| `assets-tests` | ubuntu | `npm --prefix assets ci && npm --prefix assets test` — the `assets/test/*.test.js` integration suites (apply executor, write-safety guardrail, handlers) against real installed deps | An assets integration test failed, or `package-lock.json` no longer reproduces an install |
| `docs-links` | ubuntu | `lychee --offline --include-fragments` over `assets/**/*.md`, `docs/**/*.md`, `skills/**/*.md`, `commands/**/*.md`, and the root `README.md` — recursive, so nested docs (`assets/tax/README.md`, `assets/persona/*.md`, `docs/decisions/*.md`, `skills/review/*.md`, …) are covered alongside the top-level files, and the README's links to the docs/ set are checked too | A relative link or `#fragment` cross-reference anywhere in the docs tree, the agent-facing `skills/`/`commands/` set, or the README points at nothing |

### Design decisions

**The macOS/Linux split — Keychain is fully stubbed, never exercised in CI.**
The launcher reads the YNAB token from the macOS Keychain via `security(1)`,
which no Linux runner has. Of the two possible approaches (a dedicated
`macos-latest` job that talks to a seeded Keychain, or stubbing the token), CI
uses **stubbing only**: every launcher/boot test provides `YNAB_ACCESS_TOKEN`
(or a stubbed `security` on `PATH`) itself, so the whole suite runs on
`ubuntu-latest` with no Keychain anywhere. The one macOS job (`bash-3-2`)
exists for the bash *version*, not for the Keychain — it never touches
`security(1)` either.

**`bash-3-2` membership is a marker convention, enforced by a test.** The lane
runs an **explicit, closed file list**, not `scripts/test.sh` auto-discovery:
the full suite is not known to be 3.2-safe end to end, so blanket discovery
would drag unrelated false failures onto the macOS runner. But a hand-kept
enumeration omits every *new* 3.2/BSD-relevant test file by default, which is
how `bin/ynab-prune.sh`, `bin/path-expand.sh`, and the secret-scan guard stayed
Linux-only after they landed (issue #231). So membership is declared at the file
that needs it:

1. The test file carries a `# bash-3.2-lane: <reason>` marker line in its header
   comment, stating *why* it needs a real bash 3.2 / BSD runner.
2. The same file is listed in the `bash-3-2` job's `run:` step in
   `.github/workflows/ci.yml`, and in the table row and local-repro command
   above.
3. [`tests/unit/bash-3-2-lane.test.sh`](../tests/unit/bash-3-2-lane.test.sh)
   fails the build whenever those disagree in either direction — a marked file
   missing from the lane, or a lane file with no marker.

So writing the marker is what puts a file in the lane: forget step 2 and CI
tells you, in the PR that adds the file, instead of the file silently never
running on macOS. Removing a file from the lane means deleting both its marker
and its list entries — a deliberate act, visible in the diff.

**`secret-scan.yml` stays `ubuntu-latest`; the BSD half runs in `bash-3-2`.**
`bin/secret-scan.sh`'s rules are grep patterns whose comments claim they hold
"on GNU and BSD grep alike", so that claim needs BSD execution in CI (issue
#231). Adding a macOS leg to `secret-scan.yml` would spend a 10x-billed runner
re-scanning the same tree for the same rules, so instead
`tests/secret-scan.test.sh` carries the lane marker and drives every rule
through synthetic fixtures under BSD grep on the macOS runner the repo already
pays for. What stays ubuntu-only is that workflow's scan of the **real tree** —
a data check over repo content, not a portability check over grep, and its
result does not vary by platform.

**Lint scope excludes `vendor/`.** The gate lints code this repo authors.
`vendor/ynab-mcp/` holds the vendored third-party bundle; its integrity is
enforced by SHA-256 verification in `secret-scan.yml`
(`vendor/ynab-mcp/verify-bundle.sh`), not by style linting.

**Shellcheck runs at default severity — suppressions are per-finding.**
Genuine false positives (e.g. SC2016 on intentionally-literal `$`/backtick
strings, SC2034 on variables referenced inside eval'd assert conditions) are
suppressed at the finding site with `# shellcheck disable=<SC>` plus a
one-line justification comment. Never re-silence a finding by lowering the
severity flag or ignoring a rule globally.

**The link check is offline and recursive.** Remote URLs are excluded
(`--offline`), so the job is hermetic and can't flake on someone else's
server. What it does enforce is exactly what human review kept catching by
hand: relative links and internal `#fragment` references across the docs set
must resolve. The globs are recursive (`assets/**/*.md`, `docs/**/*.md`,
`skills/**/*.md`, `commands/**/*.md` — issues #191 and #260): `**` matches zero
or more path components, so top-level files stay covered while nested markdown
gates too. `skills/` and `commands/` are in scope because those files are
agent-facing: an agent following a skill is *instructed* to open the paths it
names, so a dangling link there is a live defect, not a reading annoyance.

**Third-party actions are pinned to a full commit SHA.** First-party
`actions/*` actions ride exact major tags, but a major tag is mutable — the
publisher can repoint it at new code. For actions GitHub itself doesn't
publish, that's a supply-chain surface, so the policy (set with the repo's
first third-party action, `lycheeverse/lychee-action`, issue #191) is: pin to
a full commit SHA with a trailing `# vX.Y.Z` comment naming the release the
SHA corresponds to. To bump, update both the SHA and the comment.

### Reproducing locally

Every job is one command, no repo-specific setup:

```bash
# lint — identical to CI (needs shellcheck + jq)
bash scripts/lint.sh

# test — the swap-ready guard, then the read-only guard, then the full suite
# (needs bash, node, jq; see docs/testing.md)
bash bin/check-tool-name-sources.sh
bash scripts/check-readonly.sh
bash scripts/test.sh

# bash-3-2 — on any Mac, /bin/bash IS bash 3.2. scripts/test.sh launches each
# test file via PATH `bash`, so putting /bin first is what actually pins 3.2 —
# invoking the runner as `/bin/bash scripts/test.sh` does not (the test files
# would still run under whatever `bash` your PATH resolves, e.g. Homebrew's 5.x).
PATH="/bin:$PATH" bash scripts/test.sh tests/persona-loader.test.sh tests/secret-scan.test.sh tests/unit/grep-locale-pin.test.sh tests/unit/html-escape.test.sh tests/unit/report-writer.test.sh tests/unit/watchdog.test.sh tests/unit/ynab-prune.test.sh

# assets-tests
npm --prefix assets ci && npm --prefix assets test

# docs-links (brew install lychee)
lychee --offline --include-fragments --no-progress 'assets/**/*.md' 'docs/**/*.md' 'README.md' 'skills/**/*.md' 'commands/**/*.md'
```

## Cutting a release

From the Actions tab, run **Release** with two inputs:

- `version` — the new SemVer, **no `v` prefix** (e.g. `1.0.0`). Non-`X.Y.Z`
  versions, already-tagged versions, and versions not strictly greater than
  the current `plugin.json` version are all rejected before anything is
  written; versions go forward only.
- `description` — the one-line commit + release headline. It titles the commit,
  the annotated tag, and the GitHub Release. It is **also** the release notes'
  fallback body, used only when the changelog has no entry for this version —
  see below.

The workflow then, in order:

1. verifies the vendored YNAB MCP bundle's SHA-256 against
   [`vendor/ynab-mcp/vendored.json`](../vendor/ynab-mcp/vendored.json) and
   proves it boots offline (`tests/lib/bundle-integrity.sh`) — the bundle is
   frozen; releases never rebuild or re-fetch it;
2. bumps `version` in `.claude-plugin/plugin.json` — the **sole** bump target
   (issue #75; see the README's Versioning section). The vendored bundle's
   version marker is provenance-only and is never touched;
3. runs the full test suite (`scripts/test.sh`, which includes the
   offline-boot proof). The `assets/` integration suite has already gated the
   release from its own `assets-tests` job — see below;
4. commits as `github-actions[bot]`, creates the annotated tag `v<version>`,
   pushes `main` **and** the tag in a single `git push --atomic` — both refs
   land or neither does, because the monotonicity guard makes a same-version
   re-run impossible and a half-pushed release would have no way back — and
   creates the GitHub release, whose **"What changed" section is the
   [`CHANGELOG.md`](../CHANGELOG.md) entry for this version** (see below);
5. triggers `update-marketplace-sha.yml` explicitly via `gh workflow run` —
   releases created with `GITHUB_TOKEN` emit sterile events that do **not**
   auto-trigger `on: release` workflows (GitHub's anti-recursion rule).

### Where the release notes come from

The release notes' **What changed** section is the `CHANGELOG.md` entry for the
version being released. [`scripts/changelog-extract.sh`](../scripts/changelog-extract.sh)
does the extraction: it takes the version and the changelog path as plain CLI
arguments and prints the entry on stdout, with no dependency on Actions env
vars or secrets — so `bash scripts/changelog-extract.sh 0.1.1 CHANGELOG.md`
reproduces exactly what a release would publish, and
[`tests/unit/changelog-extract.test.sh`](../tests/unit/changelog-extract.test.sh)
tests it outside any workflow.

It selects the section whose `## [X.Y.Z]` heading matches the version exactly
(one leading `v` is stripped first, so `0.1.1` and `v0.1.1` agree, and `0.1.1`
never matches `## [0.1.10]`), and returns everything down to the next `## [`
heading or end-of-file, whitespace-trimmed.

The release step branches on the script's exit code, and there are **exactly
three outcomes**:

| Exit | Meaning | What the release does |
|---|---|---|
| `0` | Entry found — including an entry that exists but is deliberately empty. | Publishes the extracted text (empty publishes empty notes). |
| `3` | No `CHANGELOG.md`, or no heading for this version. | Falls back to the `description` input — the behaviour every release had before the workflow read the changelog. |
| other | Extraction failed: bad arguments, a non-SemVer version, or a changelog path that is not a readable regular file. | **Fails the release** with an `::error::`. |

The last row is the point of the split. A release is forward-only and
human-dispatched, so quietly substituting the one-line `description` for notes
the workflow *could not read* would ship wrong notes and leave nothing to
notice it by. Only a genuinely missing entry is allowed to fall back.

**Keep `CHANGELOG.md` ahead of the release:** move the `[Unreleased]` items
into a `## [X.Y.Z] - YYYY-MM-DD` section and merge that to `main` *before*
dispatching the release at that version. The workflow reads the changelog from
the commit it is releasing; it never writes one.

### Why the release is two jobs

The `assets/` integration suite runs `npm --prefix assets ci` — third-party
packages and their install scripts — followed by their module top-level code.
It therefore lives in its **own `assets-tests` job**, scoped to
`permissions: contents: read`, which overrides the workflow-level
`contents: write` + `actions: write`. The `release` job gates on it via
`needs: assets-tests`, so the suite still blocks the tag; as a job dependency
that ordering is stronger than the step ordering it replaced, and "no
`node_modules` on the resolution path while the offline-boot proof runs"
becomes a separate-VM guarantee rather than a step-ordering one.

Two jobs mean two checkouts of a moving `main`, so `assets-tests` publishes the
commit it actually tested and `release` re-checks it against its own `HEAD`
before bumping anything. If `main` advanced in between — or the output is
missing — the release aborts with an `::error::` rather than tagging a tree the
assets suite never saw.

Sharing a runner is the exposure, not merely a credential on disk. Actions
does not reap detached children at step boundaries, so a compromised
transitive dependency can background a process that outlives its own step and
read a push token out of another step's `/proc/<pid>/cmdline` **or**
`/proc/<pid>/environ` — same VM, same UID. Neither `--ignore-scripts`,
scrubbing the credential, nor moving it from the command line into `env:`
closes that; only never minting a write-scoped token on that runner does.

The `release` job additionally checks out with **`persist-credentials: false`**,
so checkout's `contents: write` + `actions: write` token is never written into
`.git/config`; step 4's push supplies the token in its URL instead, at push
time. With the untrusted install now on a different runner this is defence in
depth rather than the sole barrier.

## The marketplace SHA pin (cross-repo write)

`update-marketplace-sha.yml` clones
[`mike-bronner/claude-workbench`](https://github.com/mike-bronner/claude-workbench),
sets `source.sha` for this plugin's entry in `.claude-plugin/marketplace.json`,
and pushes the commit. The clone is **unauthenticated**: an embedded
credential in the clone URL is written into `marketplace/.git/config` as the
`origin` remote, which would leave `DEVELOPER_SETTINGS_TOKEN` — a long-lived,
non-expiring PAT with `Contents: write` on the *shared* marketplace repo —
readable on disk for the rest of the step. It is supplied only in the push
URL, at push time, mirroring the posture `release.yml` uses for its own push.
(The marketplace is public, so the anonymous clone and the retry loop's
`git pull --rebase` both work; were it ever made private, the clone fails
loudly rather than degrading to a silent skip.) It reads the plugin name from
`.claude-plugin/plugin.json` (never hardcoded) and resolves the release tag to
a commit SHA, dereferencing annotated tags.

It is a **silent no-op (exit 0)** when the marketplace has no entry with this
plugin's name, or when `source.sha` is already the resolved SHA. It **fails
loudly** when the `DEVELOPER_SETTINGS_TOKEN` secret is missing or when the
marketplace manifest is malformed (`.plugins` missing or not an array) — it
never silently skips the push.

The marketplace is **shared with every other workbench plugin repo**, and the
`update-marketplace-sha` concurrency group only serializes runs *within this*
repo — so a sibling plugin releasing at the same time can land its own pin
commit between our clone and our push, making ours non-fast-forward. The push
therefore sits in a bounded retry loop (5 attempts, linear backoff): on
rejection it runs `git pull --rebase` and tries again. Because `jq` rewrites
only this plugin's own entry, a sibling's edit rebases cleanly. A **conflicting
rebase aborts and fails the run** — the pin is never force-pushed over another
repo's write — and so does an exhausted attempt budget.

## The `DEVELOPER_SETTINGS_TOKEN` secret

The marketplace pin pushes to a *different* repository, which the workflow's
default `GITHUB_TOKEN` cannot do — it needs a personal access token stored as
the `DEVELOPER_SETTINGS_TOKEN` repository secret.

- **What it is:** a fine-grained personal access token that lets this repo's
  Actions push the pin commit to `mike-bronner/claude-workbench`. It is used
  for nothing else.
- **Required scope:** repository access restricted to
  `mike-bronner/claude-workbench` only, with the **Contents: Read and write**
  permission. Grant nothing broader — no other repos, no other permissions.
- **How to create it:** GitHub → Settings → Developer settings →
  Personal access tokens → **Fine-grained tokens** → *Generate new token*.
  Set *Repository access* to "Only select repositories" →
  `mike-bronner/claude-workbench`; under *Permissions → Repository
  permissions*, set **Contents** to *Read and write*. Then add the token to
  this repo under Settings → Secrets and variables → Actions as
  `DEVELOPER_SETTINGS_TOKEN`.

Fine-grained PATs expire; when the token lapses, the pin step fails with a
push error — regenerate and update the secret. Rotation hygiene for secrets
in general is covered in [SECURITY.md](../SECURITY.md).
