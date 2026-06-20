# workbench-ynab

Tax-aware YNAB budget management for Claude Code — a [claude-workbench](https://github.com/mike-bronner) plugin.

It turns a proven, hand-run weekly financial review into a first-class plugin: a formalized financial-assistant persona, a reusable tax-aware review methodology, a frozen HTML report template, and **approval-gated** write-back to YNAB. The YNAB MCP is **vendored** into the plugin, so setup is a one-time token paste — nothing to install or configure by hand.

> **Status: pre-release / under construction.** This repo is being built sprint-by-sprint by the workbench dev team. See [`docs/ROADMAP.md`](docs/ROADMAP.md) for the full plan and issue backlog.

## What it will do

- **Review** — pull your budget, accounts, and transactions and produce a polished, tax-aware HTML report (Schedule C / A / SE awareness, medical-threshold tracking, quarterly estimated taxes).
- **Propose → approve → apply** — surface categorizations, Ready-to-Assign allocations, duplicate fixes, and reconciliation as a proposed change-set you approve before anything is written.
- **Never move money** — write-back is strictly ledger-only (categorize/allocate/dedup/reconcile). The plugin never initiates transfers or payments.

## Prerequisites

- **macOS** — setup stores your YNAB token in the macOS Keychain, and the launcher and vendored MCP run on macOS.
- **System `node`** — the vendored YNAB MCP is a Node bundle launched by `bin/launcher.sh`; a system Node runtime must be on `PATH` (no `npx`-on-demand).
- **`jq`** — used by the launcher and setup tooling to read and validate JSON.
- **`security(1)`** — the macOS Keychain CLI; stores and retrieves the YNAB Personal Access Token.
- **`workbench-core@claude-workbench`** — shared memory vault, session lifecycle, and plugin infrastructure.

## Setup

First-time configuration is a one-time token paste. Run the `/workbench-ynab:setup` command (delivered in a later sprint) — it walks you through pasting your YNAB Personal Access Token into the macOS Keychain and verifies the vendored MCP launches. Nothing to install or configure by hand.

## Persona & configuration

The assistant has a default voice and, by default, speaks as **your own Claude agent** (its `workbench-core` `agent_name`) — falling back to **Hobbes** when you have no `workbench-core` agent configured. You can also give it a dedicated name via `persona.name`. Optional settings live in `config.json` in the plugin data directory — **outside this repo, so they survive plugin updates** — never in the repo and never holding your token. See [`docs/persona.md`](docs/persona.md) for the persona asset, the `persona` config object (`name`, `voice_overrides`), the name-resolution precedence, and the loader contract.

## Privacy & safety

- Your YNAB Personal Access Token is stored in the **macOS Keychain** — never in this repo, never in a config file, never logged.
- **Not tax advice.** This tool organizes financial data and surfaces tax-relevant signals to help you and your tax professional. It is not a substitute for professional tax advice.

## Architecture

Mirrors the sibling workbench plugins (`workbench-core`, `workbench-bujo`, `workbench-dev-team`): a `plugin.json`-declared MCP launched via `bin/launcher.sh`, ritual skills, a read-only orchestrator agent, session hooks, and a one-time `setup` command. The bundled YNAB MCP is [`@dizzlkheinz/ynab-mcpb`](https://www.npmjs.com/package/@dizzlkheinz/ynab-mcpb), vendored and version-frozen.

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
