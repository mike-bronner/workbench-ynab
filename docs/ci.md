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
- Actions are pinned to exact majors (`actions/checkout@v4`,
  `actions/setup-node@v5`, `lycheeverse/lychee-action@v2`) — no `@latest`, no
  floating tags.
- The `test` job runs a two-lane Node matrix: the pinned floor (`24`, canonical value in `vendor/ynab-mcp/NODE_VERSION` — by policy the latest Node LTS major at the last bundle bump, issue #3 / PR #205) and current LTS (`lts/*`). The floor lane boots the vendored bundle on the oldest supported major, so a re-vendor that raises the requirement fails CI before it ships; `tests/unit/node-floor.test.sh` fails if the matrix entry drifts from the canonical floor file. The lanes diverge exactly when a new LTS ships — the cue to bump the floor. Every other job stays single-version.

### The jobs

| Job | Runner | What it checks | A failure means |
|---|---|---|---|
| `lint` | ubuntu | `shellcheck` at **default severity** over every repo-authored `.sh` (`bin/`, `hooks/`, `scripts/`, `tests/` — helpers included), then `jq empty` over every git-tracked `.json` | A script has a shellcheck finding (any severity fails), or a JSON file doesn't parse |
| `test` | ubuntu (Node floor + `lts/*` matrix) | First the swap-ready tool-name guard (`bin/check-tool-name-sources.sh`, issues #87/#131) as an explicit fail-fast step, then the full bash + Node suite via `scripts/test.sh`, including the offline-boot proof (#14) against `node vendor/ynab-mcp/index.cjs` | A concrete YNAB tool name appeared outside the documented allowlist, or a test failed — the runner prints which file; the offline-boot proof failing usually means a bad re-vendor |
| `bash-3-2` | macOS | The persona footer-escaping suites (`tests/persona-loader.test.sh`, `tests/unit/html-escape.test.sh`) under the runner's **bash 3.2** | The escaping regressed on macOS's default bash while staying green on bash ≥5 (issue #126 AC-3) — or the runner image no longer ships bash 3.2 on PATH (the lane fails loudly rather than test the wrong interpreter) |
| `assets-tests` | ubuntu | `npm --prefix assets ci && npm --prefix assets test` — the `assets/test/*.test.js` integration suites (apply executor, write-safety guardrail, handlers) against real installed deps | An assets integration test failed, or `package-lock.json` no longer reproduces an install |
| `docs-links` | ubuntu | `lychee --offline --include-fragments` over `assets/*.md` and `docs/*.md` | A relative link or `#fragment` cross-reference in the docs points at nothing |

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

**The link check is offline.** Remote URLs are excluded (`--offline`), so the
job is hermetic and can't flake on someone else's server. What it does enforce
is exactly what human review kept catching by hand: relative links and
internal `#fragment` references across the docs set must resolve.

### Reproducing locally

Every job is one command, no repo-specific setup:

```bash
# lint — identical to CI (needs shellcheck + jq)
bash scripts/lint.sh

# test — the swap-ready guard, then the full suite (needs bash, node, jq;
# see docs/testing.md)
bash bin/check-tool-name-sources.sh
bash scripts/test.sh

# bash-3-2 — on any Mac, /bin/bash IS bash 3.2
/bin/bash scripts/test.sh tests/persona-loader.test.sh tests/unit/html-escape.test.sh

# assets-tests
npm --prefix assets ci && npm --prefix assets test

# docs-links (brew install lychee)
lychee --offline --include-fragments --no-progress 'assets/*.md' 'docs/*.md'
```

## Cutting a release

From the Actions tab, run **Release** with two inputs:

- `version` — the new SemVer, **no `v` prefix** (e.g. `1.0.0`). Non-`X.Y.Z`
  versions, already-tagged versions, and versions not strictly greater than
  the current `plugin.json` version are all rejected before anything is
  written; versions go forward only.
- `description` — the one-line commit + release headline.

The workflow then, in order:

1. verifies the vendored YNAB MCP bundle's SHA-256 against
   [`vendor/ynab-mcp/vendored.json`](../vendor/ynab-mcp/vendored.json) and
   proves it boots offline (`tests/lib/bundle-integrity.sh`) — the bundle is
   frozen; releases never rebuild or re-fetch it;
2. bumps `version` in `.claude-plugin/plugin.json` — the **sole** bump target
   (issue #75; see the README's Versioning section). The vendored bundle's
   version marker is provenance-only and is never touched;
3. runs the full test suite (`scripts/test.sh`, which includes the
   offline-boot proof) and the `assets/` integration suite;
4. commits as `github-actions[bot]`, creates the annotated tag `v<version>`,
   pushes `main` and the tag, and creates the GitHub release;
5. triggers `update-marketplace-sha.yml` explicitly via `gh workflow run` —
   releases created with `GITHUB_TOKEN` emit sterile events that do **not**
   auto-trigger `on: release` workflows (GitHub's anti-recursion rule).

## The marketplace SHA pin (cross-repo write)

`update-marketplace-sha.yml` clones
[`mike-bronner/claude-workbench`](https://github.com/mike-bronner/claude-workbench),
sets `source.sha` for this plugin's entry in `.claude-plugin/marketplace.json`,
and pushes the commit. It reads the plugin name from
`.claude-plugin/plugin.json` (never hardcoded) and resolves the release tag to
a commit SHA, dereferencing annotated tags.

It is a **silent no-op (exit 0)** when the marketplace has no entry with this
plugin's name, or when `source.sha` is already the resolved SHA. It **fails
loudly** when the `DEVELOPER_SETTINGS_TOKEN` secret is missing or when the
marketplace manifest is malformed (`.plugins` missing or not an array) — it
never silently skips the push.

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
