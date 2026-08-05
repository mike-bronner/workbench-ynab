// tests/unit/civil-date.test.mjs — unit tests for the ONE shared strict
// civil-date parser (lib/tax/civilDate.mjs, issue #263).
//
// Runs under the built-in node:test runner with NO node_modules present (only
// node: built-ins and repo-local files), per docs/testing.md. The parser is PURE
// — no filesystem, no clock — so every test feeds it literals.
//
// Covers the issue AC: the shape check, and the Date.UTC round-trip that rejects
// impossible-but-well-shaped calendar dates ('2025-02-30', '2025-13-45',
// '0000-00-00') which the old shape-only regexes accepted and answered
// plausibly-but-wrongly on. Every rejection category gets its own assertion so a
// dropped guard fails a test rather than silently widening what the parser
// accepts — each of these was mutation-tested by deleting the guard it covers and
// confirming the suite goes red.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseCivilDate } from '../../lib/tax/civilDate.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

test('parseCivilDate returns the parts and the UTC epoch day for a real date', () => {
  assert.deepEqual(parseCivilDate('2025-04-15'), {
    year: 2025,
    month: 4,
    day: 15,
    epochDay: Math.round(Date.UTC(2025, 3, 15) / 86400000),
  });
  // The epoch anchor itself, and a leap day that really exists.
  assert.equal(parseCivilDate('1970-01-01').epochDay, 0);
  assert.deepEqual(parseCivilDate('2024-02-29'), { year: 2024, month: 2, day: 29, epochDay: 19782 });
});

test('parseCivilDate epoch days are an exact calendar-day count across month and year ends', () => {
  const days = (a, b) => parseCivilDate(b).epochDay - parseCivilDate(a).epochDay;
  assert.equal(days('2026-09-08', '2026-09-15'), 7);
  assert.equal(days('2026-03-01', '2026-03-31'), 30); // spans a US DST change
  assert.equal(days('2025-12-31', '2026-01-01'), 1);
  assert.equal(days('2024-02-28', '2024-03-01'), 2); // leap year: Feb 29 exists
  assert.equal(days('2025-02-28', '2025-03-01'), 1); // non-leap: it does not
});

test('parseCivilDate rejects non-strings', () => {
  for (const bad of [undefined, null, 20250415, new Date(), ['2025-04-15'], { year: 2025 }]) {
    assert.equal(parseCivilDate(bad), null);
  }
});

test('parseCivilDate rejects anything that is not exactly YYYY-MM-DD', () => {
  for (const bad of [
    '',
    'nope',
    'not-a-date',
    '2025-4-15', // unpadded
    '25-04-15', // two-digit year
    '2025/04/15', // wrong separator
    '2025-04-155', // trailing digit — the old prefix regex read this as Apr 15
    '2025-04-15T00:00:00Z', // datetime — no seam in this repo produces one
    ' 2025-04-15',
    '2025-04-15 ',
  ]) {
    assert.equal(parseCivilDate(bad), null, `expected null for ${JSON.stringify(bad)}`);
  }
});

// Out-of-range values need no explicit 1-12 / 1-31 test in the parser: Date.UTC
// normalizes each onto a DIFFERENT real date (month 13 → next year, month 00 →
// previous year, day 00 → the prior month's last day, day 32 → next month), so
// the round-trip below rejects them all. These assertions pin the BEHAVIOUR, so
// the guarantee survives any future change of implementation.
test('parseCivilDate rejects out-of-range months and days', () => {
  for (const bad of ['2025-00-15', '2025-13-15', '2025-99-15', '2025-04-00', '2025-04-32', '0000-00-00']) {
    assert.equal(parseCivilDate(bad), null, `expected null for ${bad}`);
  }
});

test('parseCivilDate rejects impossible-but-well-shaped calendar dates (the round-trip)', () => {
  // Every one of these has a well-formed shape AND an in-range month and day —
  // only the Date.UTC round-trip catches them. Without it, Date rolls them over
  // into the following month and the parser answers with a real-looking but
  // WRONG date, which is exactly how a bad due date shifted a reminder window.
  assert.equal(parseCivilDate('2025-02-30'), null); // would roll to Mar 2
  assert.equal(parseCivilDate('2025-02-29'), null); // 2025 is not a leap year
  assert.equal(parseCivilDate('2100-02-29'), null); // century non-leap year
  assert.equal(parseCivilDate('2025-04-31'), null); // April has 30 days
  assert.equal(parseCivilDate('2025-06-31'), null);
  assert.equal(parseCivilDate('2025-09-31'), null);
  assert.equal(parseCivilDate('2025-11-31'), null);
});

test('parseCivilDate rejects years 0000-0099, which JS Date remaps into 1900-1999', () => {
  // Date.UTC(50, 0, 1) is 1950-01-01, not 0050-01-01. The round-trip catches the
  // remap and fails closed rather than silently reading a date 1900 years off.
  assert.equal(parseCivilDate('0000-01-01'), null);
  assert.equal(parseCivilDate('0050-01-01'), null);
  assert.equal(parseCivilDate('0099-12-31'), null);
  // 0100 onward is represented faithfully and is accepted.
  assert.equal(parseCivilDate('0100-01-01').year, 100);
});

// --- The invariant guard -----------------------------------------------------
//
// #263 is not really about three call sites — it is about the CLASS. The strict
// parser was module-private, so every new date seam re-derived the shape-only
// regex and silently dropped the calendar check (PR #261 did exactly that while
// fixing a related bug). Promoting the parser only helps if nothing drifts back,
// so this test IS the AC's "repo-wide check", executable and permanent.
//
// WHAT IT ASSERTS, precisely: a module that matches a civil date by regex must
// also HAVE the calendar check — either by importing the shared parser, or by
// doing the Date.UTC round-trip itself. A regex with neither is a shape-only
// re-derivation, which is the whole defect: it accepts '2025-02-30' and answers
// plausibly but wrongly.
//
// Why not ban the regex outright: a bare shape match is legitimate when the
// calendar check follows it. taxYear.mjs uses one to tell a civil date from an
// INSTANT before handing the civil branch to epochDay, and its instant regex
// necessarily contains the date shape. assets/ is CommonJS with a documented
// no-dependencies contract, so it cannot import the ESM parser and carries the
// round-trip inline instead (duplicate-candidates.js). Banning the pattern would
// have forced a carve-out list, and a file exempted by NAME can hide a real
// re-derivation; "must own the calendar check" cannot be satisfied by accident.
//
// Known limit: the detector reads whole files, so a module that legitimately
// routes one seam through the parser could still hand-roll a second one and pass.
// The per-seam rejection tests above and in estimated-tax.test.mjs are what pin
// those; this guard catches the new module that reaches for a regex first.

test('no module hand-rolls a shape-only YYYY-MM-DD check — every date regex owns the calendar check', () => {
  // Widened past lib/ on Holmes's #263 note: the class is not lib-specific, and
  // the first site found outside it (assets/duplicate-candidates.js) proved it.
  const sources = ['lib', 'assets', 'scripts']
    .flatMap((dir) => {
      let entries = [];
      try {
        entries = readdirSync(join(ROOT, dir), { recursive: true, encoding: 'utf8' });
      } catch {
        return []; // the tree may not exist; the fixture-size check below is the net
      }
      return entries
        .filter((rel) => rel.endsWith('.mjs') || rel.endsWith('.js'))
        .map((rel) => ({ rel: join(dir, rel), path: join(ROOT, dir, rel) }));
    })
    // The shared parser is the ONE place the pattern is unconditionally allowed.
    .filter(({ rel }) => rel !== join('lib', 'tax', 'civilDate.mjs'));

  // Guard against the fixture silently emptying out (a moved tree, a changed
  // extension) and reporting green having inspected nothing.
  assert.ok(sources.length >= 20, `expected to scan the whole source tree, scanned ${sources.length}`);

  // A 4-digit year group followed by a '-' and a 2-digit group: the signature of
  // a civil-date regex, in any of the spellings a re-derivation tends to use.
  const civilDateRegex = /\\d\{4\}\)?-\(?\\d\{2\}/;
  // The calendar check, in its two permitted forms: import the shared parser, or
  // round-trip through Date.UTC here (the round-trip's tell is reading the parts
  // back off the resulting Date).
  const importsSharedParser = /from ['"][^'"]*civilDate\.mjs['"]/;
  const roundTripsItself = /getUTCFullYear\(\)/;

  const offenders = sources
    .filter(({ path }) => {
      const src = readFileSync(path, 'utf8');
      return civilDateRegex.test(src) && !importsSharedParser.test(src) && !roundTripsItself.test(src);
    })
    .map(({ rel }) => rel);

  assert.deepEqual(
    offenders,
    [],
    `${offenders.join(', ')} matches a YYYY-MM-DD date by regex with no calendar check. Import parseCivilDate from lib/tax/civilDate.mjs — a shape-only check accepts impossible dates like '2025-02-30' and answers plausibly but wrongly (#263).`,
  );
});
