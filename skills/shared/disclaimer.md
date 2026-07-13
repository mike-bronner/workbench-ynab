# The canonical not-tax-advice disclaimer — single source of truth

This file is the **one canonical definition** of the plugin's not-tax-advice
disclaimer. Every user-facing surface that shows or references tax figures copies
the text below **verbatim** — the report, the dispatch summary, the README, and
the setup/docs output. There is exactly one wording; nothing here varies by tax
Schedule, filing status, currency, persona, or any other configuration.

**Invariants** (enforced by `tests/report-disclaimer.test.sh`):

- The text is **content, not a computation** — it contains no conditionals and no
  interpolated values, and it is identical regardless of the user's tax profile.
- The **compact tag** (below) is the invariant string that must appear, byte-for-byte,
  on **all four** surfaces (report, dispatch, README, docs). It is how a reader on any
  surface gets the same warning.
- The **full disclaimer** is used wherever there is room (report banner, README, docs);
  the dispatch — a five-line TL;DR — carries the compact tag only.

## Compact tag (one line — the invariant string)

Emitted wherever tax figures, quarterly estimates, or Schedule amounts appear but a
full paragraph does not fit (the dispatch summary, the tax section of the report, the
print footer, the setup summary):

```
⚠️ Estimates only — not tax advice. Consult a qualified professional before filing or paying.
```

## Full disclaimer (used where there is room)

Embedded near the top of the report and in the README/docs. It **leads with the compact
tag**, so the invariant string is present wherever the full disclaimer is:

```
⚠️ Estimates only — not tax advice. Consult a qualified professional before filing or paying.

This tool produces estimates for organizational purposes only. It is not tax, legal, or financial advice, it makes simplifying assumptions, and its figures may be incomplete or wrong for your situation. Consult a qualified tax professional before you file or pay.
```

## Where each surface pulls it

| Surface | Form | Location |
|---|---|---|
| **Report** (`assets/report/template.html`) | Full disclaimer near the top (hardcoded banner, before any tax figures); compact tag at the top of the tax section and in the `@media print` footer. Hardcoded so fragment-stitching can never omit it. | The frozen template — not a slot. |
| **Dispatch** (`docs/dispatch-format.md`, emitted by `skills/review/ynab-review.md`) | Compact tag, one line, only when tax figures/quarterly estimates/Schedule amounts appear in the output. | A dispatch tax-note line. |
| **README** (`README.md`) | Full disclaimer, elevated into the feature description near the top of the file. | Under "What this is". |
| **Docs / setup** (`commands/setup.md`) | Compact tag, surfaced once in the setup summary — clearly visible, not buried. | Step 8 final summary. |
