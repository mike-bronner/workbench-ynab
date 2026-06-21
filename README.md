# workbench-ynab

Tax-aware YNAB budget review and **approval-gated** write-back for Claude Code. Part of the [`claude-workbench`](https://github.com/mike-bronner/claude-workbench) marketplace.

> **Status: pre-release / under construction.** This repo is being built sprint-by-sprint by the workbench dev team (Lestrade triage → Watson development → Holmes review). Some commands and the MCP launcher referenced below ship in later sprints — each is marked with the sprint it lands in. See [`docs/ROADMAP.md`](docs/ROADMAP.md) for the full plan and issue backlog.

## What this is

A productized weekly financial review for [YNAB](https://www.ynab.com/). It speaks as **your own Claude agent** by default — or as **Hobbes**, the shipped default persona, when no agent is configured (the name is configurable). Each run reads your budget, categorizes transactions, flags duplicates, surfaces tax-aware insights, and proposes ledger-only fixes *inside* YNAB for your approval.

It productizes a proven prototype: a hand-run, deeply tax-aware review that has run as an ad-hoc scheduled task **since April 2026**. This plugin turns that into a first-class, shareable tool — a formalized persona, a reusable tax-aware methodology, a frozen HTML report template, and approval-gated write-back.

Two things make this plugin unusual among workbench plugins, and both are front and center — not buried:

- **It writes back to YNAB.** Beyond reading, it can categorize, allocate, fix duplicates, and reconcile *inside your budget*. Every write waits for your explicit approval, and the plugin **never moves real money** — see [The read / propose / approve loop](#the-read--propose--approve-loop).
- **It handles a financial access token.** Your YNAB Personal Access Token is stored **only** in the macOS Keychain — never in the repo, never in a config file, never logged. See [Privacy / where the token lives](#privacy--where-the-token-lives).

> **Not tax advice.** This tool organizes financial data and surfaces tax-relevant signals to help you and your tax professional. It is **not** a substitute for professional tax advice.

## Architecture

Mirrors the sibling workbench plugins: a single entry point dispatches a **read-only orchestrator** that plans the review, the **main conversation** drives the interactive review + propose/approve protocol via skills, and a **vendored YNAB MCP** is the only thing that ever talks to the YNAB API.

```
                      ┌──────────────────────────────┐
                      │  /workbench-ynab:ynab-review  │  ← entry point
                      │   (or the scheduled task)     │     (Sprint 3)
                      └───────────────┬──────────────┘
                                      │ dispatches
                                      ▼
                      ┌──────────────────────────────┐
                      │  ynab-orchestrator           │  ← read-only sub-agent
                      │  • inspects budget state     │     returns a structured
                      │  • plans which analyses run  │     review PLAN — it never
                      │  • sizes the data pull       │     writes to YNAB
                      └───────────────┬──────────────┘
                                      │ plan
                                      ▼
   You ↔ assistant (main)  ◁───────── drives the interactive review protocol
            │                         (12-section methodology, change-set,
            │                          propose → approve → apply)
            │
            │  reads config           ┌────────────────────────────────────┐
            ├───────────────────────▶ │  budget · tax-profile · persona    │
            │  (skills ONLY)          │  config — lives OUTSIDE the repo    │
            │                         └────────────────────────────────────┘
            │
            │  dispatches YNAB verbs
            ▼
   ┌──────────────────────────────┐
   │  vendored YNAB MCP           │   the ONLY thing that talks to the
   │  bin/launcher.sh → node      │   YNAB API. Receives the token +
   │  @dizzlkheinz/ynab-mcpb      │   its package-native env — never
   │  (frozen bundle)             │   this plugin's config.
   └───────────────┬──────────────┘
                   │ HTTPS
                   ▼
              💰  YNAB API
```

**The config split is deliberate and load-bearing:**

| Layer | Reads | Never sees |
|---|---|---|
| 🧠 **Skills** (main conversation) | budget id, tax profile, persona config | the YNAB token |
| 🔌 **Vendored YNAB MCP** (tool server) | the YNAB token (`YNAB_ACCESS_TOKEN`) + its package-native env | budget / tax / persona config |

The skills do all the tax and persona reasoning from config; the MCP does all the API talking from the token. Neither crosses into the other's lane — the token never reaches a skill, and the config never reaches the MCP.

## Prerequisites

- **macOS (darwin)** — setup stores the YNAB token in the macOS Keychain via `security(1)`, and the launcher + vendored MCP run on macOS.
- **System `node`** — the vendored YNAB MCP is a self-contained Node bundle launched by `bin/launcher.sh`; a system Node runtime must be on `PATH`. **The bundle runs on `node` directly — there is no `node_modules` install step and no `npx`-on-demand.**
- **`jq`** — used by the launcher and setup tooling to read and validate JSON config.
- **`security(1)`** — the macOS Keychain CLI; stores and retrieves the YNAB Personal Access Token.
- **`workbench-core@claude-workbench`** — shared memory vault, session lifecycle, and plugin infrastructure (also the source of the agent name the persona falls back to).

## Installation

### From the marketplace

```
claude plugin marketplace add mike-bronner/claude-workbench
claude plugin install workbench-ynab@claude-workbench
```

### Local checkout (development)

Point Claude Code at your clone:

```
git clone https://github.com/mike-bronner/workbench-ynab
cd workbench-ynab
claude plugin install /absolute/path/to/workbench-ynab
```

After installing either way, **restart Claude Code** so the plugin's agents, skills, commands, and the vendored MCP server are picked up.

## Setup

First-run configuration is a one-time step. Run the setup command *(ships in Sprint 1)*:

```
/workbench-ynab:setup
```

It:

1. **Seeds the Keychain token** — prompts for your YNAB Personal Access Token and stores it in the macOS Keychain (never in the repo or a config file).
2. **Writes config** — creates `config.json` in the plugin data directory (outside the repo) with your budget, tax profile, and persona settings.
3. **Pre-approves the tool glob** — pre-approves the namespaced `mcp__plugin_workbench-ynab_ynab__*` read tools so reviews run without per-call prompts. Write verbs stay behind the approval gate.
4. **Offers legacy migration** — detects and offers to retire the old hand-run prototype and its scheduled task.

Get a YNAB Personal Access Token from [YNAB → Account Settings → Developer Settings](https://app.ynab.com/settings/developer).

## What it does

Each review reads your budget (read-only) and produces a tax-aware report organized into **twelve analysis sections**:

| # | Section | Surfaces |
|---|---|---|
| 1 | **Cashflow summary** | Inflow vs. outflow; net movement for the period. |
| 2 | **Category health** | Overspent / negative-balance categories; funding gaps. |
| 3 | **Ready-to-Assign** | Unallocated money waiting for a job. |
| 4 | **Needs attention** | Uncategorized, unapproved, and unusual transactions. |
| 5 | **Duplicate detection** | Likely double-entered transactions. |
| 6 | **Reconciliation status** | Cleared-vs-reconciled drift per account. |
| 7 | **Accounts & balances** | On/off-budget balances; net snapshot. |
| 8 | **Business expenses (Schedule C)** | Deductible business spend, mapped to Schedule C lines. |
| 9 | **Medical & dental (Schedule A)** | Spend tracked against the AGI medical threshold. |
| 10 | **Self-employment tax (Schedule SE)** | SE-tax exposure from business net income. |
| 11 | **Quarterly estimated taxes** | Estimated-tax due-date tracking and set-aside. |
| 12 | **Trends & recommendations** | Period-over-period movement and the prioritized action list. |

The tax-aware sections are driven entirely by a **data-driven, shareable tax profile** — never hard-coded owner detail. For the full methodology, see [`docs/methodology.md`](docs/methodology.md); for the tax-profile schema, see [`assets/tax/README.md`](assets/tax/README.md).

## The read / propose / approve loop

This is the core safety story. Write-back never happens silently.

1. **Read** — the plugin reads your YNAB budget, accounts, categories, and transactions.
2. **Propose** — it surfaces the fixes it found (categorizations, Ready-to-Assign allocations, duplicate fixes, reconciliations) as a single proposed **change-set**. Nothing has touched the ledger yet.
3. **Approve** — it **waits for your explicit approval before any write**. **One approval covers one batch** — approving one change-set never pre-approves the next.
4. **Apply** — only after approval, the batch is applied. Apply defaults to a dry-run that reports exactly what would change.

**Every write is ledger-only**, strictly limited to:

- **Categorize** — assign a transaction to a category.
- **Allocate** — move money from Ready-to-Assign into a category.
- **Fix duplicates** — delete a double-entered transaction.
- **Reconcile** — bring an account's cleared/reconciled balance into line.

**The plugin NEVER moves real money.** It initiates no transfers and no payments to the outside world — no money ever leaves or moves between your real accounts. This is enforced structurally: every change-set carries a `money_movement: false` invariant that cannot be set otherwise, and a runtime guardrail hard-blocks any apply that maps to a money-moving operation. See [`assets/changeset-contract.md`](assets/changeset-contract.md) for the full contract.

## Privacy / where the token lives

**Your YNAB Personal Access Token is stored ONLY in the macOS Keychain.** It is never committed to the repo, never written to a config file, never logged, and is injected into the vendored MCP at launch time as the `YNAB_ACCESS_TOKEN` environment variable — read fresh from the Keychain on every launch, never persisted elsewhere.

The token lives under the Keychain **service `ynab-mcp`**, **account `access-token`**.

Store it (setup does this for you):

```sh
security add-generic-password -s "ynab-mcp" -a "access-token" -w "$TOKEN" -U
```

Read it back (the launcher does this at MCP start):

```sh
security find-generic-password -s "ynab-mcp" -a "access-token" -w
```

**Configuration lives outside the repo.** Your budget id, tax profile, and persona settings live at:

```
~/.claude/plugins/data/workbench-ynab-claude-workbench/config.json
```

This path is deliberately outside the installed plugin tree, so **plugin updates never clobber it** — re-installing or upgrading `workbench-ynab` leaves your config and tax profile untouched. The config never holds the token (that's Keychain-only), and it is never committed.

## Commands

Every command is namespaced under `/workbench-ynab:`. The plugin is mid-build; the **Ships in** column marks the sprint each command lands in (see [`docs/ROADMAP.md`](docs/ROADMAP.md)).

| Command | Description | Ships in |
|---|---|---|
| `/workbench-ynab:setup` | First-run setup: seed the YNAB token into the Keychain, write config, pre-approve the read-tool glob, offer legacy migration. | Sprint 1 |
| `/workbench-ynab:ynab-review` | Run a tax-aware review for a tier (weekly / monthly / quarterly-tax / annual); produces the report and the proposed change-set. | Sprint 3 |
| `/workbench-ynab:ynab-apply` | Review a proposed change-set and, on explicit approval, apply the ledger-only writes (dry-run by default). | Sprint 4 |
| `/workbench-ynab:migrate` | Retire the legacy hand-run prototype and its scheduled task. | Sprint 5 |

## Versioning

**The plugin and its vendored YNAB MCP bundle are pinned together in git.** The bundle is [`@dizzlkheinz/ynab-mcpb`](https://www.npmjs.com/package/@dizzlkheinz/ynab-mcpb), **version-frozen at `0.26.10`** and vendored as a self-contained `vendor/ynab-mcp/index.cjs` — no `npx`-on-demand, no floating dependency. The pinned version, tarball hash, and provenance are recorded in [`vendor/ynab-mcp/vendored.json`](vendor/ynab-mcp/vendored.json); the bundle is only ever updated via the re-vendor script (`bin/revendor.sh`), never by hand. See [`docs/vendoring.md`](docs/vendoring.md) for how to update the bundle, verify the result, and the version-marker format.

Pinning both versions in git means a given `workbench-ynab` commit always runs against the exact MCP bundle it was tested with — boot is offline, frozen, and reproducible.

## Versioning

Two version numbers live in this repo. They track different things, are deliberately **independent**, and are **never co-bumped**.

- **The plugin's own version** lives in [`.claude-plugin/plugin.json`](.claude-plugin/plugin.json) (currently `0.1.0`). This is the **only** version release automation bumps — the release workflow's sole bump target is `.claude-plugin/plugin.json`, and no other manifest, JSON, or config file in the repo carries a release version. It starts at `0.1.0` and is cut to `1.0.0` at first release.
- **The vendored YNAB MCP version** is recorded in [`vendor/ynab-mcp/vendored.json`](vendor/ynab-mcp/vendored.json) (`@dizzlkheinz/ynab-mcpb@0.26.10`). It is **frozen, provenance-only** — a record of exactly which upstream bundle is checked into git, not a number this plugin releases against. Release automation **never** touches it; it changes only when the bundle is deliberately re-vendored.

The two schemes do not move together: bumping the plugin version leaves the vendored bundle version untouched, and re-vendoring the bundle leaves the plugin version untouched.

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
