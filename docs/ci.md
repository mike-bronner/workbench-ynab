# CI — what runs on every PR, and how to reproduce it locally

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
- One current LTS Node (`lts/*`) — deliberately no multi-version matrix for v1.

## The jobs

| Job | Runner | What it checks | A failure means |
|---|---|---|---|
| `lint` | ubuntu | `shellcheck` at **default severity** over every repo-authored `.sh` (`bin/`, `hooks/`, `scripts/`, `tests/` — helpers included), then `jq empty` over every git-tracked `.json` | A script has a shellcheck finding (any severity fails), or a JSON file doesn't parse |
| `test` | ubuntu | The full bash + Node suite via `scripts/test.sh`, including the offline-boot proof (#14) against `node vendor/ynab-mcp/index.cjs` | A test failed — the runner prints which file; the offline-boot proof failing usually means a bad re-vendor |
| `bash-3-2` | macOS | The persona footer-escaping suites (`tests/persona-loader.test.sh`, `tests/unit/html-escape.test.sh`) under the runner's **bash 3.2** | The escaping regressed on macOS's default bash while staying green on bash ≥5 (issue #126 AC-3) — or the runner image no longer ships bash 3.2 on PATH (the lane fails loudly rather than test the wrong interpreter) |
| `assets-tests` | ubuntu | `npm --prefix assets ci && npm --prefix assets test` — the `assets/test/*.test.js` integration suites (apply executor, write-safety guardrail, handlers) against real installed deps | An assets integration test failed, or `package-lock.json` no longer reproduces an install |
| `docs-links` | ubuntu | `lychee --offline --include-fragments` over `assets/*.md` and `docs/*.md` | A relative link or `#fragment` cross-reference in the docs points at nothing |

## Design decisions

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

## Reproducing locally

Every job is one command, no repo-specific setup:

```bash
# lint — identical to CI (needs shellcheck + jq)
bash scripts/lint.sh

# test — the full suite (needs bash, node, jq; see docs/testing.md)
bash scripts/test.sh

# bash-3-2 — on any Mac, /bin/bash IS bash 3.2
/bin/bash scripts/test.sh tests/persona-loader.test.sh tests/unit/html-escape.test.sh

# assets-tests
npm --prefix assets ci && npm --prefix assets test

# docs-links (brew install lychee)
lychee --offline --include-fragments --no-progress 'assets/*.md' 'docs/*.md'
```
