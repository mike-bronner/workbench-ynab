# workbench-ynab

Tax-aware YNAB budget management for Claude Code — a [claude-workbench](https://github.com/mike-bronner) plugin.

It turns a proven, hand-run weekly financial review into a first-class plugin: a formalized financial-assistant persona, a reusable tax-aware review methodology, a frozen HTML report template, and **approval-gated** write-back to YNAB. The YNAB MCP is **vendored** into the plugin, so setup is a one-time token paste — nothing to install or configure by hand.

> **Status: pre-release / under construction.** This repo is being built sprint-by-sprint by the workbench dev team. See [`docs/ROADMAP.md`](docs/ROADMAP.md) for the full plan and issue backlog.

## What it will do

- **Review** — pull your budget, accounts, and transactions and produce a polished, tax-aware HTML report (Schedule C / A / SE awareness, medical-threshold tracking, quarterly estimated taxes).
- **Propose → approve → apply** — surface categorizations, Ready-to-Assign allocations, duplicate fixes, and reconciliation as a proposed change-set you approve before anything is written.
- **Never move money** — write-back is strictly ledger-only (categorize/allocate/dedup/reconcile). The plugin never initiates transfers or payments.

## Privacy & safety

- Your YNAB Personal Access Token is stored in the **macOS Keychain** — never in this repo, never in a config file, never logged.
- **Not tax advice.** This tool organizes financial data and surfaces tax-relevant signals to help you and your tax professional. It is not a substitute for professional tax advice.

## Architecture

Mirrors the sibling workbench plugins (`workbench-core`, `workbench-bujo`, `workbench-dev-team`): a `plugin.json`-declared MCP launched via `bin/launcher.sh`, ritual skills, a read-only orchestrator agent, session hooks, and a one-time `setup` command. The bundled YNAB MCP is [`@dizzlkheinz/ynab-mcpb`](https://www.npmjs.com/package/@dizzlkheinz/ynab-mcpb), vendored and version-frozen.

## License

See [issue tracker](https://github.com/mike-bronner/workbench-ynab/issues) — license selection is tracked as an early backlog item.
