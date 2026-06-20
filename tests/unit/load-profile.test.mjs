// tests/unit/load-profile.test.mjs — unit tests for the tax-profile loader
// (lib/tax/loadProfile.mjs, issue #22 / M3-3).
//
// Runs under the built-in node:test runner with NO node_modules present (only
// node: built-ins and repo-local files are imported), per docs/testing.md. The
// loader resolves its bundled defaults + schema from assets/tax/ relative to its
// own location, so these tests only supply the USER profile path (a temp file)
// via the loader's documented path seam.
//
// Covers the AC #9 matrix: (a) defaults-only when the user profile is absent,
// (b) user values override defaults, (c) overrides win over user, (d) a
// schema-invalid profile returns a structured error (no silent fallback),
// (e) provenance correctness across all three tiers, (f) array-merge-by-id and
// object deep-merge semantics — plus the accessors and the stdout discipline.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

import {
  loadProfile,
  resolveProfile,
  deepMerge,
  validateAgainstSchema,
  SOURCES,
} from '../../lib/tax/loadProfile.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const MODULE_PATH = join(ROOT, 'lib', 'tax', 'loadProfile.mjs');
const SCHEMA = JSON.parse(readFileSync(join(ROOT, 'assets', 'tax', 'tax-profile.schema.json'), 'utf8'));

const TMP = mkdtempSync(join(tmpdir(), 'ynab-tax-'));
let seq = 0;
function writeProfile(obj) {
  const p = join(TMP, `tax-profile-${seq++}.json`);
  writeFileSync(p, JSON.stringify(obj, null, 2));
  return p;
}
const ABSENT = join(TMP, 'does-not-exist.json');

const validBase = () => ({ schemaVersion: '1', filingStatus: 'single', taxYear: 2025 });

// --- (a) defaults-only when the user profile is absent ----------------------

test('(a) absent user profile → defaults-only, no error, all provenance = defaults', () => {
  const r = loadProfile({ profilePath: ABSENT });
  assert.equal(r.ok, true);
  assert.equal(r.defaultsOnly, true);
  assert.equal(r.sources.profile, null);
  // Values come from the bundled US ruleset (#21).
  assert.equal(r.getStandardDeduction(2025, 'mfj'), 30000);
  assert.equal(r.getStandardDeduction(2024, 'single'), 14600);
  assert.equal(r.getThreshold('saltCap'), 10000);
  assert.equal(r.getThreshold('seTaxRate'), 0.153);
  // Every provenance leaf is stamped `defaults` and there is at least one.
  const tiers = Object.values(r.provenance);
  assert.ok(tiers.length > 0, 'expected provenance entries');
  assert.ok(tiers.every((t) => t === SOURCES.DEFAULTS), 'every leaf should be defaults');
});

test('(a) the resolved profile and provenance map are frozen', () => {
  const r = loadProfile({ profilePath: ABSENT });
  assert.ok(Object.isFrozen(r.profile));
  assert.ok(Object.isFrozen(r.provenance));
  assert.throws(() => {
    r.profile.thresholds.saltCap = 1;
  }, TypeError);
});

// --- (b) user values override defaults --------------------------------------

test('(b) user values override defaults; untouched defaults remain', () => {
  const p = writeProfile({
    ...validBase(),
    thresholds: { seTaxRate: 0.2 },
    standardDeductionByYear: { single: { 2025: 16000 } },
  });
  const r = loadProfile({ profilePath: p });
  assert.equal(r.ok, true);
  assert.equal(r.defaultsOnly, false);

  assert.equal(r.getThreshold('seTaxRate'), 0.2); // user wins
  assert.equal(r.provenance['thresholds.seTaxRate'], SOURCES.USER);

  assert.equal(r.getThreshold('medicalAgiPercent'), 0.075); // default survives
  assert.equal(r.provenance['thresholds.medicalAgiPercent'], SOURCES.DEFAULTS);

  assert.equal(r.getStandardDeduction(2025, 'single'), 16000); // user wins
  assert.equal(r.provenance['standardDeductionByYear.single.2025'], SOURCES.USER);

  assert.equal(r.getStandardDeduction(2024, 'single'), 14600); // default survives
  assert.equal(r.provenance['standardDeductionByYear.single.2024'], SOURCES.DEFAULTS);
});

// --- (c) overrides layer wins over user values ------------------------------

test('(c) explicit overrides win over user values', () => {
  const p = writeProfile({
    ...validBase(),
    thresholds: { saltCap: 12000 },
    overrides: { thresholds: { saltCap: 5000 } },
  });
  const r = loadProfile({ profilePath: p });
  assert.equal(r.ok, true);
  assert.equal(r.getThreshold('saltCap'), 5000);
  assert.equal(r.provenance['thresholds.saltCap'], SOURCES.OVERRIDES);
  // The applied `overrides` is not surfaced as a profile field.
  assert.equal(r.profile.overrides, undefined);
});

// --- (d) schema-invalid profile → structured error, never silent fallback ---

test('(d) bad enum value → schema failure naming the offending path', () => {
  const p = writeProfile({ ...validBase(), filingStatus: 'bogus' });
  const r = loadProfile({ profilePath: p });
  assert.equal(r.ok, false);
  assert.equal(r.error.kind, 'schema');
  assert.equal(r.profile, null, 'must NOT fall back to a defaults profile');
  assert.equal(r.provenance, null);
  const e = r.error.errors.find((x) => x.path === '/filingStatus');
  assert.ok(e, 'expected an error on /filingStatus');
  assert.equal(e.keyword, 'enum');
});

test('(d) missing required property → schema failure naming the path', () => {
  const { taxYear, ...noYear } = { ...validBase() }; // drop taxYear
  void taxYear;
  const p = writeProfile(noYear);
  const r = loadProfile({ profilePath: p });
  assert.equal(r.ok, false);
  assert.equal(r.error.kind, 'schema');
  const e = r.error.errors.find((x) => x.path === '/taxYear');
  assert.ok(e, 'expected a required-property error on /taxYear');
  assert.equal(e.keyword, 'required');
});

test('(d) invalid JSON → structured parse error, not a throw', () => {
  const p = join(TMP, 'broken.json');
  writeFileSync(p, '{ this is not json ');
  const r = loadProfile({ profilePath: p });
  assert.equal(r.ok, false);
  assert.equal(r.error.kind, 'parse');
  assert.equal(r.profile, null);
});

// --- (e) provenance correctness across all three tiers ----------------------

test('(e) provenance distinguishes defaults / user / overrides per leaf', () => {
  const p = writeProfile({
    ...validBase(),
    thresholds: { seTaxRate: 0.16 }, // user
    standardDeductionByYear: { single: { 2025: 16000 } }, // user
    businessEntities: [
      { id: 'biz-a', displayName: 'Business A', schedule: 'C', scheduleLineMap: { advertising: 'G1' } },
    ],
    overrides: {
      thresholds: { saltCap: 5000 }, // overrides
      businessEntities: [{ id: 'biz-a', scheduleLineMap: { office: 'G2' } }], // deep-merge by id
    },
  });
  const r = loadProfile({ profilePath: p });
  assert.equal(r.ok, true);

  assert.equal(r.provenance['thresholds.seTaxRate'], SOURCES.USER);
  assert.equal(r.provenance['thresholds.medicalAgiPercent'], SOURCES.DEFAULTS);
  assert.equal(r.provenance['thresholds.saltCap'], SOURCES.OVERRIDES);
  assert.equal(r.provenance['standardDeductionByYear.single.2025'], SOURCES.USER);
  assert.equal(r.provenance['standardDeductionByYear.single.2024'], SOURCES.DEFAULTS);
  assert.equal(r.provenance['businessEntities[biz-a].scheduleLineMap.advertising'], SOURCES.USER);
  assert.equal(r.provenance['businessEntities[biz-a].scheduleLineMap.office'], SOURCES.OVERRIDES);

  // The merged entity carries both the user and the override values.
  assert.deepEqual(r.getScheduleLineMap('biz-a'), { advertising: 'G1', office: 'G2' });
});

// --- (f) array-merge-by-id and object deep-merge semantics ------------------

test('(f) deepMerge merges entity arrays by id, recurses objects, replaces scalars/plain arrays', () => {
  // entity arrays merge by id (match → merge, miss → append, absent → keep)
  const entities = deepMerge(
    { list: [{ id: 'a', n: 1 }, { id: 'b', n: 2 }] },
    { list: [{ id: 'a', n: 9 }, { id: 'c', n: 3 }] },
  );
  assert.deepEqual(entities.list, [{ id: 'a', n: 9 }, { id: 'b', n: 2 }, { id: 'c', n: 3 }]);

  // nested objects deep-merge
  assert.deepEqual(deepMerge({ a: { x: 1, y: 2 } }, { a: { y: 3, z: 4 } }), { a: { x: 1, y: 3, z: 4 } });

  // plain (non-entity) arrays override wholesale
  assert.deepEqual(deepMerge({ tags: ['x', 'y'] }, { tags: ['z'] }), { tags: ['z'] });

  // scalars override
  assert.deepEqual(deepMerge({ v: 1 }, { v: 2 }), { v: 2 });
});

test('(f) resolveProfile deep-merges a partial thresholds object onto the defaults', () => {
  const defaults = { thresholds: { a: 1, b: 2 }, lines: [{ id: 'L1', label: 'one' }] };
  const user = { thresholds: { b: 9 } };
  const { profile, provenance } = resolveProfile(defaults, user);
  assert.deepEqual(profile.thresholds, { a: 1, b: 9 }); // a from defaults, b from user
  assert.equal(provenance['thresholds.a'], SOURCES.DEFAULTS);
  assert.equal(provenance['thresholds.b'], SOURCES.USER);
});

// --- accessors --------------------------------------------------------------

test('accessors: business entities, schedule line maps, thresholds, quarterly dates', () => {
  const p = writeProfile({
    ...validBase(),
    taxYear: 2025,
    businessEntities: [
      { id: 'biz-a', displayName: 'Business A', schedule: 'C', scheduleLineMap: { advertising: 'G1' } },
    ],
    quarterlyEstimatedDueDates: [
      { quarter: 1, month: 4, day: 15 },
      { quarter: 4, month: 1, day: 15 },
    ],
  });
  const r = loadProfile({ profilePath: p });
  assert.equal(r.ok, true);

  assert.equal(r.getBusinessEntities().length, 1);
  assert.deepEqual(r.getScheduleLineMap('biz-a'), { advertising: 'G1' });
  assert.equal(r.getScheduleLineMap('nope'), undefined);

  // Q1 stays in the tax year; Q4 rolls into January of the following year.
  const due = r.getQuarterlyDueDates(2025);
  assert.equal(due[0].date, '2025-04-15');
  assert.equal(due[1].date, '2026-01-15');

  // Omitted args fall back to the profile's own filing status / tax year.
  assert.equal(r.getThreshold('seTaxRate'), 0.153);
});

// --- validator vouches for the canonical example ---------------------------

test('validateAgainstSchema accepts the bundled example instance', () => {
  const example = JSON.parse(readFileSync(join(ROOT, 'assets', 'tax', 'tax-profile.example.json'), 'utf8'));
  const { valid, errors } = validateAgainstSchema(example, SCHEMA);
  assert.equal(valid, true, `example should validate; got: ${JSON.stringify(errors)}`);
});

test('validateAgainstSchema rejects an unknown top-level property (additionalProperties:false)', () => {
  const { valid, errors } = validateAgainstSchema({ ...validBase(), bogusField: 1 }, SCHEMA);
  assert.equal(valid, false);
  assert.ok(errors.some((e) => e.path === '/bogusField' && e.keyword === 'additionalProperties'));
});

// --- AC #8: the module emits nothing to stdout ------------------------------

test('the loader writes nothing to stdout (safe on an MCP/JSON-RPC path)', () => {
  const invalid = writeProfile({ ...validBase(), filingStatus: 'bogus' });
  const url = pathToFileURL(MODULE_PATH).href;
  const script = `
    import(${JSON.stringify(url)}).then((m) => {
      m.loadProfile({ profilePath: ${JSON.stringify(ABSENT)} });       // success path
      m.loadProfile({ profilePath: ${JSON.stringify(invalid)} });      // schema-failure path
      process.stderr.write('ok');                                      // proof it ran
    });
  `;
  const res = spawnSync(process.execPath, ['-e', script], { encoding: 'utf8' });
  assert.equal(res.status, 0, res.stderr);
  assert.equal(res.stdout, '', `expected empty stdout, got: ${JSON.stringify(res.stdout)}`);
  assert.equal(res.stderr, 'ok');
});

// --- cleanup ----------------------------------------------------------------

test.after(() => rmSync(TMP, { recursive: true, force: true }));
