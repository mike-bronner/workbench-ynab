## Summary

<!-- What this pull request changes, in one or two sentences. -->

## Linked issue

<!-- Required. Holmes reviews against this issue's acceptance criteria. -->

Fixes #

## Changes

<!-- Bullet list of what changed. -->

-

## Acceptance criteria

<!-- Copy the acceptance criteria from the linked issue. Tick each one you have
     met; if one is not met, say why here rather than leaving it silently blank. -->

- [ ]

## Checklist

- [ ] **Tests added.** Every change is covered by a test, and each new test was
      mutation-checked — the guarded code was deleted or inverted and the test
      went red for the reason it claims.
- [ ] **`scripts/test.sh` passes** locally (the whole suite, not just the new file).
- [ ] **`scripts/lint.sh` passes** locally.
- [ ] **No secrets committed.** No YNAB token, no real financial data, no
      private key, no `.env` file. `bin/secret-scan.sh` passes.
- [ ] **Conventional Commits + Gitmoji** format used on every commit, and each
      commit is atomic.
- [ ] **Linked issue number present** above, using `Fixes #<n>`.
- [ ] **Docs updated** for every symbol, path, or behaviour this changes — no
      documentation left describing the old behaviour.

## Security and privacy impact

<!-- Delete this section only if the change touches no code and no docs. -->

- [ ] Does not change where the YNAB token is read, stored, or passed.
- [ ] Does not log the token, to stdout or stderr.
- [ ] Any file or directory this creates is owner-only (`0600` / `0700`) at
      creation time, not by a later `chmod`.
- [ ] Does not add a write-back operation that moves real money.
- [ ] Does not add an npm dependency (the offline-boot proof depends on this).

## Test plan

<!-- How a reviewer verifies this. Name the test files and any manual steps. -->

-
