// tests/unit/report-contrast.test.mjs — the executable WCAG 2.1 AA contrast
// audit for the frozen report template's dark palette (issue #29).
//
// Runs under the built-in node:test runner with NO node_modules present (only
// node: built-ins and repo-local files), per docs/testing.md.
//
// Parses the design tokens straight out of assets/report/template.html's :root
// block — never a hardcoded copy of the palette — and asserts every text token
// clears 4.5:1 (body-text AA) against every background it can sit on, and every
// progress-bar fill clears 3:1 (non-text AA) against the gauge track. If a
// future palette tweak drops a pair below threshold, this test names the pair.
// The human-readable audit table lives in docs/a11y-baseline.md.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const template = readFileSync(join(repoRoot, 'assets', 'report', 'template.html'), 'utf8');

// ---- token extraction ---------------------------------------------------------

/** Pull `--name: #hex;` design tokens out of the template's :root block. */
function tokens() {
  const root = template.match(/:root\s*\{([^}]*)\}/);
  assert.ok(root, 'template has a :root design-token block');
  const out = {};
  for (const m of root[1].matchAll(/--([a-z-]+):\s*(#[0-9a-fA-F]{6})/g)) {
    out[m[1]] = m[2];
  }
  return out;
}

// ---- WCAG 2.1 math (relative luminance + contrast ratio) ------------------------

function luminance(hex) {
  const [r, g, b] = [1, 3, 5]
    .map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map((v) => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function contrast(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

// ---- the audit ------------------------------------------------------------------

// Text tokens × the backgrounds each can sit on. Badges (0.85rem/600) and table
// text are body-size, so every pair is held to the 4.5:1 body-text threshold —
// the strictest use wins, even where a token also appears as large KPI text.
const TEXT_TOKENS = ['ink', 'ink-muted', 'teal', 'coral', 'amber'];
const BACKGROUNDS = ['navy', 'navy-soft', 'row-alt'];

test('every :root token the audit needs is present', () => {
  const t = tokens();
  for (const name of [...TEXT_TOKENS, ...BACKGROUNDS]) {
    assert.ok(t[name], `token --${name} exists in :root`);
  }
});

test('text tokens meet WCAG AA 4.5:1 on every background they sit on', () => {
  const t = tokens();
  for (const fg of TEXT_TOKENS) {
    for (const bg of BACKGROUNDS) {
      const ratio = contrast(t[fg], t[bg]);
      assert.ok(
        ratio >= 4.5,
        `--${fg} (${t[fg]}) on --${bg} (${t[bg]}) is ${ratio.toFixed(2)}:1 — below 4.5:1`
      );
    }
  }
});

test('progress-bar fills meet WCAG AA 3:1 against the gauge track', () => {
  const t = tokens();
  // .progress track is --navy; fills are teal (default), coral, amber.
  for (const fill of ['teal', 'coral', 'amber']) {
    const ratio = contrast(t[fill], t.navy);
    assert.ok(
      ratio >= 3,
      `--${fill} (${t[fill]}) fill on the --navy track is ${ratio.toFixed(2)}:1 — below 3:1`
    );
  }
});

test('the stock sub-AA coral #e74c3c never reappears', () => {
  assert.ok(
    !/e74c3c/i.test(template),
    'template still references the failed stock coral #e74c3c'
  );
});
