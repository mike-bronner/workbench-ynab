# workbench-ynab — Roadmap & Issue Backlog

## Context

For months, a "Hobbes" weekly YNAB financial review ran as an ad-hoc scheduled task — a proven, 171-line, deeply tax-aware methodology producing a polished HTML report. But it was improvised each run: the persona was inline, the HTML was rebuilt from scratch every time (token-wasteful, inconsistent, missing its own print CSS), and everything was hard-wired to one user's situation.

This plugin **productizes that prototype**: a formalized persona, a reusable tax-aware review, a frozen report template, and approval-gated write-back — with a vendored YNAB MCP so setup is a one-time token paste. Built sprint-by-sprint by the workbench dev team (Lestrade triage → Watson development → Holmes review) off the backlog below.

## Decisions

| Decision | Choice |
|---|---|
| Scope (v1) | Read-only review **+ approval-gated write-back** (categorize/allocate/dedup/reconcile). **Never moves real money** — ledger-only. |
| MCP strategy | **Vendor** `@dizzlkheinz/ynab-mcpb@0.26.10` (its self-contained ~1.46 MB `dist/bundle/index.cjs`), run via `node`, version frozen in git. No `npx`-on-demand. |
| Tax logic | **Generic & shareable** — data-driven tax profile + mapping engine; any user's situation is one config instance. |
| Distribution | Public repo; listed in the `claude-workbench` marketplace at release. |
| Pipeline | Issues are PBIs on the project board governed by The Index. |

## Sprints

Build order is sequenced so each sprint consumes the last — the Tax Engine precedes the Review's tax sections. Design ids in brackets map to the original backlog generation.

| Sprint | Milestone | Goal |
|---|---|---|
| **1** [M1] | Foundation & Zero-Config MCP | Vendored YNAB MCP boots with one token paste; scaffold, launcher, setup, config, CI, test harness. |
| **2** [M3] | Generic Tax Engine | Data-driven tax profile + mapping engine; owner details become one config instance. |
| **3** [M2] | Read-Only Review Engine | Formalized Hobbes, 12-section methodology as a skill, frozen HTML template (with print CSS), orchestrator, scheduled task. Consumes Sprint 2. |
| **4** [M4] | Active Write-Back | read → propose → **approve** → apply. Ledger-only, audited, dry-run default. |
| **5** [M5] | Release & Marketplace | Docs, security, marketplace entry, retire the old prototype, cut 1.0.0. |
| **6** [M6] | v-Next (deferred) | Proactive monitoring, multi-budget, first-class quarterly-tax, bundled-own-MCP spike. Tracked, not built in v1. |

## Structural corrections (baked into the filed issues)

From an adversarial completeness + dependency review of the generated backlog:

1. **Resolve tax-schema triplication** — one canonical tax sub-schema (Sprint 2); the config issue (Sprint 1) owns only the umbrella envelope + loader; the duplicate is dropped and its mapping rules fold into the classifier.
2. **Tax Engine (Sprint 2) before Review (Sprint 3)** — the review consumes the tax-engine facade rather than hand-rolling tax math that gets replaced.
3. **Break the write-back circular dependency** — the mock/sandbox harness lands right after the apply-executor core, before the write paths that depend on it.
4. **Decompose the 4 XL critical-path issues** (setup, review engine, apply executor, classifier) into 2–3 focused PBIs each.
5. **Read-only permission boundary** — setup pre-approves read tools only; write verbs are approved at Sprint 4 behind the guardrail. No harness-level write capability during the read-only phase.
6. **Merge duplicates** — one session-warmup hook, one orchestrator file (stub → fleshed), one offline-boot test, one source per doc topic, coordinated `.gitignore` edits.
7. **Foundational test-harness issue in Sprint 1** — CI and all downstream tests depend on it.
8. **Centralize milliunits → currency** in one shared money helper.
9. **Prominent "not tax advice" disclaimer** across report, README, and docs.
10. **Marketplace entry strictly before the release SHA-pin** or the pin is a silent no-op.

## Backlog inventory

> Full issue bodies and draft acceptance criteria are filed as GitHub issues. This is the compact map.

**Sprint 1 — Foundation [M1]:** scaffold repo skeleton · LICENSE (decision) · vendor the bundle + bin shim + version marker · re-vendor script · `bin/launcher.sh` (Keychain → `YNAB_ACCESS_TOKEN` → `exec node`, stderr-only) · config schema + loader · offline-boot proof (linchpin — spike first) · setup command *(split)* · CI · Index onboarding · orchestrator stub · warmup hook · **+gaps:** test-harness foundation, bundle provenance check, min-Node pin.

**Sprint 2 — Tax Engine [M3]:** canonical tax-profile schema · default US Schedule C/A/1/SE line data · profile loader (merge defaults + overrides) · mapping engine + heuristics *(split)* · migrate owner details to a config instance · unit tests · tax-mapping docs · facade for the review skill · **+gaps:** tax-year vs budget-year resolution, confidence-threshold/human-review routing, not-tax-advice disclaimer.

**Sprint 3 — Review Engine [M2]:** formalize persona (configurable) · methodology protocol skill *(split)* · tier wrappers (weekly/monthly/quarterly-tax/annual) · frozen HTML template + print CSS · dispatch format · review orchestrator (YAML planner) · router command · report-writer helper · warmup routing · one unified scheduled task · read-only golden-snapshot test · **+gaps:** empty/new-budget state, multi-currency, rate-limit/pagination/delta handling, HTML-escape YNAB strings, accessibility, persona-input sanitization, timezone ownership.

**Sprint 4 — Write-Back [M4]:** change-set schema · write-safety guardrail (money-movement hard block) · append-only audit log · apply executor (dry-run default) *(split)* · `/ynab-apply` approval command (three-options protocol) · categorize/allocate/duplicate-fix/reconcile write paths · change-set emission from review · write-tool pre-approval globs · mock harness + e2e *(resequenced early)* · **+gaps:** 401/revoked/partial-batch handling, single-flight guard, proposal lifecycle/expiry, idempotent resume, split/transfer handling.

**Sprint 5 — Release [M5]:** full README · docs set · SECURITY.md + secret hygiene · token rotation + scrub · release automation + marketplace SHA-pin · version 0.1.0 · marketplace entry (cross-repo) · legacy-migration command (retire old prototype + scheduled task) · verification checklist · clean-room install test · cut 1.0.0 + CHANGELOG · **+gaps:** uninstall/teardown, report/proposal privacy posture, CONTRIBUTING + issue/PR templates.

**Sprint 6 — v-Next [M6] (deferred):** between-run monitoring + alert detectors · first-class quarterly-tax tracker + reminders · multi-budget + cross-budget rollup · bundled-own-MCP spike + swap-ready abstraction.
