---
name: Feature request
about: Suggest a new capability or an improvement to an existing one
title: ''
labels: enhancement
assignees: ''
---

> ⚠️ **Never paste real financial data or a YNAB token here.** Redact budget
> names, account names, payees, and amounts before you submit. This is a public
> issue tracker.

## The problem

<!-- What you are trying to do today, and where the plugin gets in the way.
     Describe the problem, not the solution you have in mind. -->

## What you want

<!-- The capability you are asking for. -->

## Which surface would it touch

<!-- Delete the ones that do not apply. -->

- [ ] A new or changed `/workbench-ynab:*` command
- [ ] Review analysis / methodology (`docs/methodology.md`)
- [ ] Tax mapping (`docs/tax-mapping.md`)
- [ ] The HTML report output
- [ ] Write-back behaviour (`docs/write-back-safety.md`)
- [ ] Setup, config, or persona
- [ ] Something else:

## Does it write to YNAB?

- [ ] No — read-only.
- [ ] Yes — it would categorize, allocate, delete a duplicate, or reconcile.

If yes: the plugin **never moves real money**, and every write is gated by the
explicit read → propose → approve loop. Explain how your request fits inside
that boundary — see [`docs/write-back-safety.md`](../../docs/write-back-safety.md).

## Is it tax-related?

- [ ] No.
- [ ] Yes.

If yes: the tax engine is **US-only** and its output is an estimate, never tax
advice. Say which US federal rule or form line the request maps to.

## Alternatives you considered

<!-- Other ways to solve the problem, including doing it by hand in YNAB. -->

## Anything else

<!-- Screenshots (redacted), links, prior art in other tools. -->
