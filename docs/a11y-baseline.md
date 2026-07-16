# Report accessibility baseline (issue #29)

The a11y contract for the rendered YNAB review report — the frozen template
([`../assets/report/template.html`](../assets/report/template.html)) plus the
fragments the review skill injects per
[`../assets/report/SLOTS.md`](../assets/report/SLOTS.md). One checkbox per rule
so the snapshot/verify step (M2-12) can assert each criterion against a rendered
report without re-reading issue #29. The template references this file via its
`<!-- a11y-baseline: docs/a11y-baseline.md -->` comment.

## Checklist

- [ ] **AA contrast — text.** Every text token meets WCAG 2.1 AA against every
      background it sits on: ≥4.5:1 for body-size text, ≥3:1 for large text
      (≥18pt, or ≥14pt bold) and meaningful UI components. Audited values below;
      regression-gated by `tests/unit/report-contrast.test.mjs`.
- [ ] **Severity is never color alone.** Every 🟢/🟡/🔴 badge carries a
      co-located visible text label — `Good`, `Attention`, or `Action required` —
      with the emoji wrapped in `aria-hidden="true"`, so status survives
      grayscale print, colorblind viewing, and screen readers.
- [ ] **Sequential heading hierarchy.** One `<h1>` (the report title in the
      header); each major section opens with an `<h2>` in document order;
      subsections use `<h3>`; no skipped levels.
- [ ] **Labelled tables.** Every data table has `scope` on its header cells
      (`<th scope="col">`, or `scope="row"` for row headers); a table without a
      visible `<caption>` carries an `aria-label` describing its purpose.
- [ ] **Gauges are meters.** Every `.progress` gauge carries `role="meter"` with
      `aria-valuenow`, `aria-valuemin`, and `aria-valuemax`, an accessible name
      (`aria-label` or a labelling element), and a visible numeric label beside
      it so the value is readable, not just the bar shape.
- [ ] **Keyboard-operable disclosures.** Every `<details>` is focusable and
      toggleable from the keyboard (Tab to focus the `<summary>`, Enter/Space to
      toggle) with a visible `:focus-visible` outline; the print rule that forces
      collapsed content open only overrides child *display*, never the toggle.

## Audited palette (WCAG 2.1 AA)

Contrast ratios of every text token against every background it can sit on
(computed per WCAG 2.1 relative luminance; the executable audit is
`tests/unit/report-contrast.test.mjs`):

| Token | On `--navy` `#1a1a2e` | On `--navy-soft` `#232342` | On `--row-alt` `#1f1f3a` |
|---|---|---|---|
| `--ink` `#e8e8f0` | 14.00 | 12.39 | 13.10 |
| `--ink-muted` `#a4a4bf` | 7.02 | 6.21 | 6.57 |
| `--teal` `#16a085` | 5.20 | 4.60 | 4.87 |
| `--coral` `#ef6e5e` | 5.74 | 5.08 | 5.37 |
| `--amber` `#f39c12` | 7.78 | 6.89 | 7.28 |

The stock coral `#e74c3c` failed body-text AA (4.46 / 3.95 / 4.18) and was
lightened in-place to `#ef6e5e` (same hue family). Badge borders use
`currentColor`, so they inherit the passing text ratios; progress-bar fills sit
on the `--navy` track, where every fill color clears the 3:1 non-text minimum.

## Scope notes

- The template is self-contained (no scripts), so there is no dynamic focus
  management to audit — keyboard operability rests on native `<details>`,
  which the CSS never suppresses.
- Print output keeps card/badge backgrounds via `print-color-adjust: exact`,
  so the dark-surface ratios above hold on paper; grayscale print is covered
  by the text-label rule, not by color.
