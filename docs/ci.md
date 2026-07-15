# CI and release automation

This repo runs four GitHub Actions workflows. Two gate every push/PR; two
automate releases (issue #74, design M5-5).

| Workflow | Trigger | What it does |
|---|---|---|
| [`test.yml`](../.github/workflows/test.yml) | `push`, `pull_request` | Runs the full test suite via `scripts/test.sh` (dependency-free job) plus the `assets/` integration suite (separate job with `npm ci`). |
| [`secret-scan.yml`](../.github/workflows/secret-scan.yml) | `push`, `pull_request` | Fails the build on committed credential shapes and on vendored-bundle SHA drift. See [SECURITY.md](../SECURITY.md). |
| [`release.yml`](../.github/workflows/release.yml) | `workflow_dispatch` | One-button release: guards, bundle-integrity proof, version bump, tests, commit + annotated tag + push, GitHub release, then chains the marketplace pin. |
| [`update-marketplace-sha.yml`](../.github/workflows/update-marketplace-sha.yml) | `release: published`, `workflow_dispatch` | Pins the released commit SHA in the claude-workbench marketplace (**cross-repo write** — see below). |

## Cutting a release

From the Actions tab, run **Release** with two inputs:

- `version` — the new SemVer, **no `v` prefix** (e.g. `1.0.0`). Non-`X.Y.Z`
  versions and already-tagged versions are rejected before anything is
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
loudly** when the `DEVELOPER_SETTINGS_TOKEN` secret is missing — it never
silently skips the push.

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
