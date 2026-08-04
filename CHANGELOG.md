# Changelog

All notable changes to workbench-ynab are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each released version's section is the source of the GitHub Release's
"What changed" notes — `.github/workflows/release.yml` extracts it by heading
via `scripts/changelog-extract.sh`, so keep every heading in the exact
`## [X.Y.Z] - YYYY-MM-DD` form. Add new entries under `[Unreleased]`, and move
them into a dated version section when that version is released.

## [Unreleased]

## [0.1.1] - 2026-08-03

This first public release productizes the April 2026 prototype: the one-off
scripts and hand-run notebooks became an installable Claude Code plugin with a
frozen dependency set, an audited write path, and a documented uninstall.

### Added

- **Tax-aware weekly review.** A guided weekly pass over the YNAB budget that
  categorizes transactions against a per-user tax profile, flags duplicates,
  and routes every call it makes by an explicit confidence band, so low-
  confidence classifications reach a human instead of a proposal.
- **Human-approved, ledger-only write-back.** Proposed YNAB changes are staged
  as a reviewable changeset and applied only after explicit human approval;
  writes touch ledger fields alone, never budget or account structure.
- **Vendored, frozen YNAB MCP bundle.** The YNAB MCP server ships committed at
  `vendor/ynab-mcp/index.cjs`, pinned by the SHA-256 in
  `vendor/ynab-mcp/vendored.json` and proven to boot with no `node_modules`
  present — the plugin installs and runs with nothing to fetch.
- **Keychain-only token storage.** The YNAB personal access token lives in the
  macOS Keychain and is read at call time; it is never written to a config
  file, a report, an audit record, or the environment.
- **Legacy-migration command.** `/workbench-ynab:ynab-migrate` retires the
  April 2026 prototype: it detects the old Desktop YNAB connector, its token,
  and the deprecated prototype task directories, and removes each one only on
  confirmation — idempotent, so a partial run is safe to repeat.
