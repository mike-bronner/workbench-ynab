# Contributing to workbench-ynab

Thanks for your interest. This document is short on purpose: it points at the
conventions this repo already documents rather than restating them.

Before you start, read [Read this first](#read-this-first) — this plugin touches
a live financial credential and produces tax-adjacent output, so two postures
apply to every contribution.

## Read this first

**This project is not tax advice.** Every report, estimate, and tax figure the
plugin produces is an organizational estimate only. The canonical wording lives
in [`skills/shared/disclaimer.md`](../skills/shared/disclaimer.md) and every
doc in [`docs/`](../docs/) carries it byte-for-byte. If your change touches tax
logic, tax docs, or report output, keep that tag intact and do not soften it.

**This project handles a live financial token and writes plaintext financial
data to disk.** Read [`SECURITY.md`](../SECURITY.md) in full before you touch
`bin/`, `hooks/`, `vendor/`, or any code that writes a file. The rules that bind
every contribution:

- The YNAB Personal Access Token lives **only** in the macOS Keychain. Never
  write it to a config file, never log it — not even to stderr.
- Never commit a secret. CI runs [`bin/secret-scan.sh`](../bin/secret-scan.sh)
  on every push and pull request and fails the build on a token shape, a
  cleartext token assignment, or a private-key header.
- Every generated artifact is owner-only (`0600` files, `0700` directories) **at
  creation time**, never by a later `chmod`.
- The plugin never moves real money. Write-back is ledger-only — see
  [`docs/write-back-safety.md`](../docs/write-back-safety.md).

## Filing an issue

Use the templates: [bug report](ISSUE_TEMPLATE/bug_report.md) or
[feature request](ISSUE_TEMPLATE/feature_request.md). Fill in every field — the
plugin version, your Claude Code version, and the exact reproduction steps are
what make a bug actionable.

**Never put real financial data in an issue.** Redact budget names, account
names, payees, and amounts. Never paste a YNAB token. If you believe you have
found a security vulnerability, do **not** open an issue — use GitHub private
vulnerability reporting instead, as described in
[`SECURITY.md`](../SECURITY.md#reporting-a-vulnerability).

## How your issue moves through the agent pipeline

This repo is built by an agent dev team coordinated through a GitHub project
board. Your issue enters the same pipeline the maintainer's own work does:

1. **Inspector Lestrade** triages it. He rewrites the issue into a Product
   Backlog Item with explicit, testable acceptance criteria, and sizes it. Your
   issue text is the input to that refinement — expect the acceptance criteria
   to be sharper and more specific than what you filed. If the request is too
   large for one pull request, he splits it.
2. **Dr. Watson** implements it on a branch and opens a pull request. One issue
   produces exactly one pull request.
3. **Sherlock Holmes** reviews the pull request against the acceptance criteria.
   He either approves it or requests changes, and he re-reviews after each fix.
   Review rounds are normal; a bounce is not a rejection of the idea.
4. A human merges. No agent merges anything.

**If you submit a pull request yourself**, the path is the same from step 3 on:
Holmes reviews it against the linked issue's acceptance criteria, and a human
merges. This has two practical consequences for you:

- **Link an issue.** A pull request with no linked issue has no acceptance
  criteria to review against. Open the issue first, let it be triaged, then
  build against the criteria it carries.
- **Expect a review round.** Holmes reviews strictly — most commonly for tests
  that do not actually discriminate (see [Tests](#tests) below), for
  documentation that drifted from the code, and for error paths that fail open.

## Development standards

### Commit format

Every commit message uses **Conventional Commits + Gitmoji**:

```
<emoji> <type>(<optional scope>): <description>
```

For example: `✨ feat(review): add duplicate detection threshold` or
`🐛 fix(launcher): route diagnostics to stderr`.

Keep commits **atomic** — one logical change per commit. Do not mix a refactor
with a behaviour change, and do not bundle unrelated fixes.

### Tests

**Every change gets a test.** `docs/testing.md` is the canonical convention;
read it before adding a test file.

```bash
scripts/test.sh                          # the whole suite (bash + node)
scripts/test.sh --bash                   # only the bash suite
scripts/test.sh --node                   # only the node suite
scripts/test.sh tests/unit/x.test.sh     # a single file
```

`scripts/test.sh` is the single entrypoint and the command CI invokes. It
discovers `tests/**/*.test.{sh,mjs,js}` on its own, so a new test file gates CI
automatically. There are **no npm dependencies** — the Node suite uses the
built-in `node:test` runner, and adding a test framework would break the
offline-boot proof. Do not add one.

Before you request review, **mutation-test your own tests**: delete or invert
the code each new test guards and confirm the test goes red for the reason it
claims. A test that stays green when the behaviour is removed proves nothing,
and it is the single most common reason a pull request is bounced here.

Run the linter too — it is the same entrypoint CI uses:

```bash
scripts/lint.sh    # shellcheck at default severity + jq over every tracked JSON
```

### Pull requests

Use the [pull request template](pull_request_template.md) and complete its
checklist honestly. Keep the pull request scoped to one issue.

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).
By participating, you agree to uphold it.

## License

By contributing, you agree that your contributions are licensed under the MIT
License, the same terms as the rest of the project — see
[`LICENSE`](../LICENSE).
