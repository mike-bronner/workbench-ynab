// tests/unit/load-profile.test.mjs — unit tests for the tax-profile loader
// (lib/tax/loadProfile.mjs, issue #22 / M3-3).
//
// Runs under the built-in node:test runner with NO node_modules present (only
// node: built-ins and repo-local files are imported), per docs/testing.md. The
// loader resolves its bundled defaults + schema from assets/tax/ relative to its
// own location, so these tests only supply the USER profile path (a temp file)
// via the loader's documented path seam — plus `dataDir: TMP`, which declares
// the temp dir as an explicit containment root (issue #169): the loader refuses
// to read any path that does not canonicalize into the resolved dataDir or the
// bundled assets/tax/ directory, and an explicitly-passed dataDir is exactly
// how a test root joins that allowlist without weakening the production default.
//
// Covers the AC #9 matrix: (a) defaults-only when the user profile is absent,
// (b) user values override defaults, (c) overrides win over user, (d) a
// schema-invalid profile returns a structured error (no silent fallback),
// (e) provenance correctness across all three tiers, (f) array-merge-by-id and
// object deep-merge semantics — plus the accessors and the stdout discipline.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, rmSync, chmodSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

import {
  loadProfile,
  resolveProfile,
  deepMerge,
  validateAgainstSchema,
  buildOverridesSchema,
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
  const r = loadProfile({ dataDir: TMP, profilePath: ABSENT });
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
  const r = loadProfile({ dataDir: TMP, profilePath: ABSENT });
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
  const r = loadProfile({ dataDir: TMP, profilePath: p });
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
  const r = loadProfile({ dataDir: TMP, profilePath: p });
  assert.equal(r.ok, true);
  assert.equal(r.getThreshold('saltCap'), 5000);
  assert.equal(r.provenance['thresholds.saltCap'], SOURCES.OVERRIDES);
  // The applied `overrides` is not surfaced as a profile field.
  assert.equal(r.profile.overrides, undefined);
});

// --- (d) schema-invalid profile → structured error, never silent fallback ---

test('(d) bad enum value → schema failure naming the offending path', () => {
  const p = writeProfile({ ...validBase(), filingStatus: 'bogus' });
  const r = loadProfile({ dataDir: TMP, profilePath: p });
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
  const r = loadProfile({ dataDir: TMP, profilePath: p });
  assert.equal(r.ok, false);
  assert.equal(r.error.kind, 'schema');
  const e = r.error.errors.find((x) => x.path === '/taxYear');
  assert.ok(e, 'expected a required-property error on /taxYear');
  assert.equal(e.keyword, 'required');
});

test('(d) invalid JSON → structured parse error, not a throw', () => {
  const p = join(TMP, 'broken.json');
  writeFileSync(p, '{ this is not json ');
  const r = loadProfile({ dataDir: TMP, profilePath: p });
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
  const r = loadProfile({ dataDir: TMP, profilePath: p });
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
  const r = loadProfile({ dataDir: TMP, profilePath: p });
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

test('accessors (issue #82): income-tax brackets, estimated-payment matchers, period passthrough', () => {
  // Defaults-only: the bundled US ruleset supplies brackets, due-date period
  // boundaries, and the generic estimated-payment payee keywords.
  const r = loadProfile({ dataDir: TMP, profilePath: ABSENT });
  const brackets = r.getIncomeTaxBrackets(2025, 'mfj');
  assert.ok(Array.isArray(brackets) && brackets.length > 0);
  assert.equal(brackets[0].rate, 0.10);
  assert.equal(brackets.at(-1).upTo, undefined); // top bracket is unbounded
  assert.equal(r.getIncomeTaxBrackets(1900, 'mfj'), undefined); // unknown year

  // No-arg fallback to the profile's own year + filing status — needs a USER
  // profile (the bundled defaults carry no taxYear / filingStatus, those are
  // per-user required fields), so write one.
  const up = loadProfile({ dataDir: TMP, profilePath: writeProfile({ ...validBase(), filingStatus: 'mfj', taxYear: 2025 }) });
  assert.deepEqual(up.getIncomeTaxBrackets(), up.getIncomeTaxBrackets(2025, 'mfj'));

  const matchers = r.getEstimatedTaxPaymentMatchers();
  assert.ok(matchers.payeeKeywords.includes('irs'));
  // Always the four arrays, even when the user configured none.
  assert.deepEqual(Object.keys(matchers).sort(), ['accounts', 'categoryGroups', 'categoryNames', 'payeeKeywords']);

  // getQuarterlyDueDates passes the uneven income-attribution boundaries through.
  const q2 = r.getQuarterlyDueDates(2025).find((d) => d.quarter === 2);
  assert.equal(q2.periodStartMonth, 4);
  assert.equal(q2.periodEndMonth, 5);
});

// --- validator vouches for the canonical example ---------------------------

test('validateAgainstSchema accepts the bundled example instance', () => {
  const example = JSON.parse(readFileSync(join(ROOT, 'assets', 'tax', 'tax-profile.example.json'), 'utf8'));
  const { valid, errors } = validateAgainstSchema(example, SCHEMA);
  assert.equal(valid, true, `example should validate; got: ${JSON.stringify(errors)}`);
});

// --- M3-5: the example carries an onboarding $readme that the loader strips ---
// The example doubles as the populate-from template, so it must explain (in the
// file itself) where the live instance belongs and that it is never committed —
// AC #8. The note is a $-prefixed annotation: declared in the schema so the
// example still satisfies additionalProperties:false, then stripped pre-merge so
// it never reaches the resolved profile or any tax math.
test('(M3-5) the example carries a non-empty $readme onboarding note', () => {
  const example = JSON.parse(readFileSync(join(ROOT, 'assets', 'tax', 'tax-profile.example.json'), 'utf8'));
  assert.ok(Array.isArray(example.$readme) && example.$readme.length > 0, 'example must carry a $readme note');
  const note = example.$readme.join('\n');
  assert.match(note, /\.claude\/plugins\/data\/workbench-ynab-claude-workbench/, 'note must say where the live instance belongs');
  // Pin the never-committed claim distinctly. The location assertion above already
  // owns "where it belongs", so this must match the commit-status clause itself —
  // not a placement word like "outside" that survives even if the "never committed
  // (this repo is PUBLIC)" sentence were deleted (AC #8(b)).
  assert.match(note, /never committed|not committed|never in git/i, 'note must say it is never committed');
  assert.match(note, /cp /, 'note must show how to copy/populate it');
});

test('(M3-5) the example $readme is stripped from the resolved profile', () => {
  const example = readFileSync(join(ROOT, 'assets', 'tax', 'tax-profile.example.json'), 'utf8');
  const p = join(TMP, 'example-instance.json');
  writeFileSync(p, example);
  const r = loadProfile({ dataDir: TMP, profilePath: p });
  assert.equal(r.ok, true, `example must load cleanly; got: ${JSON.stringify(r.error)}`);
  assert.equal(Object.prototype.hasOwnProperty.call(r.profile, '$readme'), false, '$readme leaked into the resolved profile');
  assert.ok(Object.keys(r.provenance).every((k) => !k.includes('$')), 'no $-annotation provenance leaf');
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
      m.loadProfile({ dataDir: ${JSON.stringify(TMP)}, profilePath: ${JSON.stringify(ABSENT)} });       // success path
      m.loadProfile({ dataDir: ${JSON.stringify(TMP)}, profilePath: ${JSON.stringify(invalid)} });      // schema-failure path
      process.stderr.write('ok');                                      // proof it ran
    });
  `;
  const res = spawnSync(process.execPath, ['-e', script], { encoding: 'utf8' });
  assert.equal(res.status, 0, res.stderr);
  assert.equal(res.stdout, '', `expected empty stdout, got: ${JSON.stringify(res.stdout)}`);
  assert.equal(res.stderr, 'ok');
});

// --- BLOCKER 1: prototype pollution via a __proto__ key in overrides --------
// A JSON `__proto__` survives JSON.parse as an OWN property; a naive deep-merge
// reads it via bracket access (the inherited accessor) and walks the chain,
// mutating the global Object.prototype of the whole process. The merge must skip
// the dangerous keys. (Object-literal `{ __proto__: ... }` SETS the prototype, so
// these instances are built from raw JSON text to keep __proto__ an own key.)

test('(blocker) a __proto__ key in overrides does not pollute Object.prototype', () => {
  const p = join(TMP, 'proto-pollution.json');
  writeFileSync(
    p,
    '{"schemaVersion":"1","filingStatus":"single","taxYear":2025,' +
      '"overrides":{"__proto__":{"pwned":true}}}',
  );
  const r = loadProfile({ dataDir: TMP, profilePath: p });
  assert.equal(r.ok, true); // top-level overrides keys are open; __proto__ is simply skipped
  // The smoking gun: nothing leaked onto every object in the process.
  assert.equal(({}).pwned, undefined, 'Object.prototype must not be polluted');
  assert.equal(Object.prototype.pwned, undefined);
});

test('(blocker) exported resolveProfile / deepMerge are not pollution vectors', () => {
  // The issue intends the engine to consume these with raw JSON.parse output.
  resolveProfile(JSON.parse('{"a":1}'), JSON.parse('{"overrides":{"__proto__":{"pwnedA":true}}}'));
  assert.equal(({}).pwnedA, undefined);

  // __proto__ is the live prototype-pollution vector; `constructor.prototype` is
  // the textbook second vector. The guard drops BOTH dangerous keys outright.
  const merged = deepMerge(
    JSON.parse('{"a":1}'),
    JSON.parse('{"__proto__":{"pwnedB":true},"constructor":{"prototype":{"pwnedC":true}}}'),
  );
  assert.equal(({}).pwnedB, undefined, 'Object.prototype must not be polluted via __proto__');
  assert.equal(({}).pwnedC, undefined, 'Object.prototype must not be polluted via constructor.prototype');
  // Non-tautological proof the guard actually fired: the skipped keys leave NO
  // own property behind. Without the guard the `constructor` key would be copied
  // in as an own property here (its bracket-read is the Object function, so the
  // merge wholesale-assigns it), making this assertion fail.
  assert.equal(Object.prototype.hasOwnProperty.call(merged, '__proto__'), false);
  assert.equal(Object.prototype.hasOwnProperty.call(merged, 'constructor'), false);
  assert.deepEqual(merged, { a: 1 });
});

// --- BLOCKER 2: overrides must not silently corrupt the resolved profile -----

test('(blocker) a type-incompatible override fails loud, never corrupts the profile', () => {
  const p = writeProfile({
    ...validBase(),
    overrides: { thresholds: { seTaxRate: 'not-a-number' } },
  });
  const r = loadProfile({ dataDir: TMP, profilePath: p });
  assert.equal(r.ok, false, 'a string where a rate belongs must not silently pass through');
  assert.equal(r.error.kind, 'schema');
  assert.equal(r.profile, null, 'must NOT produce a corrupted profile');
  const e = r.error.errors.find((x) => x.path === '/overrides/thresholds/seTaxRate');
  assert.ok(e, 'expected a typed error naming the override path');
  assert.equal(e.keyword, 'type');
});

test('(blocker) an id-less entity override fails loud instead of dropping entities', () => {
  const p = writeProfile({
    ...validBase(),
    businessEntities: [
      { id: 'biz-a', displayName: 'Business A', schedule: 'C', scheduleLineMap: { advertising: 'G1' } },
    ],
    // No `id` → a wholesale replace would silently drop biz-a. Must be rejected.
    overrides: { businessEntities: [{ displayName: 'Business B', schedule: 'C', scheduleLineMap: {} }] },
  });
  const r = loadProfile({ dataDir: TMP, profilePath: p });
  assert.equal(r.ok, false);
  assert.equal(r.error.kind, 'schema');
  assert.equal(r.profile, null);
  const e = r.error.errors.find((x) => x.path === '/overrides/businessEntities/0/id' && x.keyword === 'required');
  assert.ok(e, 'expected a required-id error on the override entity');
});

test('(blocker) a well-formed id-only entity override still deep-merges (regression guard)', () => {
  const p = writeProfile({
    ...validBase(),
    businessEntities: [
      { id: 'biz-a', displayName: 'Business A', schedule: 'C', scheduleLineMap: { advertising: 'G1' } },
    ],
    overrides: { businessEntities: [{ id: 'biz-a', scheduleLineMap: { office: 'G2' } }] },
  });
  const r = loadProfile({ dataDir: TMP, profilePath: p });
  assert.equal(r.ok, true);
  assert.deepEqual(r.getScheduleLineMap('biz-a'), { advertising: 'G1', office: 'G2' });
});

test('buildOverridesSchema opens the root and requires only id on entities', () => {
  const ov = buildOverridesSchema(SCHEMA);
  assert.equal(ov.additionalProperties, true);
  assert.equal(ov.properties.overrides, undefined); // overrides cannot nest itself
  assert.deepEqual(ov.properties.businessEntities.items.required, ['id']);
  assert.equal(ov.properties.businessEntities.minItems, 1); // empty-array override is rejected
  // A ruleset-only key (not a named profile property) is allowed through.
  assert.equal(validateAgainstSchema({ lines: [{ id: 'L1' }] }, ov).valid, true);
});

test('(blocker) an empty businessEntities override fails loud instead of wiping entities', () => {
  const p = writeProfile({
    ...validBase(),
    businessEntities: [
      { id: 'biz-a', displayName: 'Business A', schedule: 'C', scheduleLineMap: { advertising: 'G1' } },
    ],
    // `[]` has no element to carry an id, so the by-id merge is skipped and a
    // wholesale replace would silently drop biz-a. minItems:1 must reject it.
    overrides: { businessEntities: [] },
  });
  const r = loadProfile({ dataDir: TMP, profilePath: p });
  assert.equal(r.ok, false, 'an empty entity-array override must not silently wipe entities');
  assert.equal(r.error.kind, 'schema');
  assert.equal(r.profile, null);
  const e = r.error.errors.find((x) => x.path === '/overrides/businessEntities' && x.keyword === 'minItems');
  assert.ok(e, 'expected a minItems failure at /overrides/businessEntities');
});

// --- BLOCKER 2 (round 2): $-prefixed override keys must never leak ------------
// `overrides` (and any unknown override key) is schema-open, so a $-annotation
// key passes validation. It must still be stripped pre-merge across all three
// tiers — otherwise the resolved profile would carry a key its own schema forbids
// (additionalProperties:false). Raw JSON keeps the $ keys as real own properties.

test('(blocker) $-prefixed keys in overrides never leak into the frozen profile', () => {
  const p = join(TMP, 'dollar-keys.json');
  writeFileSync(
    p,
    '{"schemaVersion":"1","filingStatus":"single","taxYear":2025,' +
      '"overrides":{"$pwn":"leak","customBucket":{"$note":"x","$readme":["y"],"real":1}}}',
  );
  const r = loadProfile({ dataDir: TMP, profilePath: p });
  assert.equal(r.ok, true);
  // A top-level $ key (caught in the merge key loop) does not land.
  assert.equal(Object.prototype.hasOwnProperty.call(r.profile, '$pwn'), false, 'top-level $ key leaked');
  // A $ key nested under a schema-open, wholesale-replaced override key (caught by
  // the stripComments clone) does not land either.
  assert.deepEqual(r.profile.customBucket, { real: 1 }, 'nested $ key leaked into a replaced subtree');
  // ...and no provenance leaf is keyed on a $ annotation.
  assert.ok(Object.keys(r.provenance).every((k) => !k.includes('$')), 'no $-keyed provenance leaf');
});

// --- BLOCKER 3 (round 2): a pathologically deep override must fail loud -------

test('(blocker) a too-deep override returns a structured failure, never crashes', () => {
  // overrides is schema-open, so deep nesting is not caught by validation; the
  // recursive merge/strip guards must convert it to a structured `depth` failure
  // instead of overflowing the stack and escaping as an uncaught RangeError.
  let nested = 'true';
  for (let i = 0; i < 5000; i++) nested = `{"x":${nested}}`;
  const p = join(TMP, 'deep-override.json');
  writeFileSync(
    p,
    `{"schemaVersion":"1","filingStatus":"single","taxYear":2025,"overrides":{"deep":${nested}}}`,
  );
  const r = loadProfile({ dataDir: TMP, profilePath: p });
  assert.equal(r.ok, false, 'a too-deep override must fail loud, not crash the loader');
  assert.equal(r.error.kind, 'depth');
  assert.equal(r.profile, null);
});

// --- follow-up: propertyNames failure reports the container path -------------

test('(follow-up) propertyNames failure is reported at the container path', () => {
  // Bad filing-status key under standardDeductionByYear.
  const bad = validateAgainstSchema(
    { ...validBase(), standardDeductionByYear: { bogus: { 2025: 1 } } },
    SCHEMA,
  );
  assert.equal(bad.valid, false);
  const e = bad.errors.find((x) => x.keyword === 'propertyNames');
  assert.ok(e, 'expected a propertyNames error');
  assert.equal(e.path, '/standardDeductionByYear', 'path names the container, not a value position');
  assert.equal(e.params.propertyName, 'bogus');

  // Bad four-digit-year key reports at the inner container.
  const badYear = validateAgainstSchema(
    { ...validBase(), standardDeductionByYear: { single: { '20x5': 1 } } },
    SCHEMA,
  );
  const ey = badYear.errors.find((x) => x.keyword === 'propertyNames');
  assert.ok(ey);
  assert.equal(ey.path, '/standardDeductionByYear/single');
});

// --- follow-up: getStandardDeduction omitted-arg fallback -------------------

test('(follow-up) getStandardDeduction with no args falls back to the profile year + status', () => {
  // validBase → filingStatus single, taxYear 2025; default single/2025 = 15000.
  const p = writeProfile({ ...validBase() });
  const r = loadProfile({ dataDir: TMP, profilePath: p });
  assert.equal(r.ok, true);
  assert.equal(r.getStandardDeduction(), 15000, 'no-arg call uses profile.taxYear + profile.filingStatus');
});

// --- follow-up: schemaVersion oneOf arms + reject branches ------------------

test('(follow-up) schemaVersion accepts the integer oneOf arm', () => {
  const r = validateAgainstSchema({ schemaVersion: 1, filingStatus: 'single', taxYear: 2025 }, SCHEMA);
  assert.equal(r.valid, true, JSON.stringify(r.errors));
});

test('(follow-up) schemaVersion matching neither oneOf arm is rejected', () => {
  // 0 is an integer but < minimum 1 (integer arm fails) and is not a string (string arm fails).
  const r = validateAgainstSchema({ schemaVersion: 0, filingStatus: 'single', taxYear: 2025 }, SCHEMA);
  assert.equal(r.valid, false);
  const e = r.errors.find((x) => x.path === '/schemaVersion' && x.keyword === 'oneOf');
  assert.ok(e, 'expected a oneOf failure');
  assert.equal(e.params.passes, 0);
});

// --- follow-up: io / packaging-invariant / deep-freeze branches -------------

const canChmod = process.platform !== 'win32' && (typeof process.getuid !== 'function' || process.getuid() !== 0);

test('(follow-up) an unreadable profile returns a structured io failure', { skip: !canChmod }, () => {
  const p = join(TMP, 'unreadable.json');
  writeFileSync(p, JSON.stringify(validBase()));
  chmodSync(p, 0o000);
  try {
    const r = loadProfile({ dataDir: TMP, profilePath: p });
    assert.equal(r.ok, false);
    assert.equal(r.error.kind, 'io');
    assert.equal(r.profile, null);
  } finally {
    chmodSync(p, 0o600); // restore so the TMP cleanup can remove it
  }
});

test('(follow-up) a missing bundled ruleset throws (packaging invariant, not a user error)', () => {
  assert.throws(
    () => loadProfile({ dataDir: TMP, profilePath: ABSENT, defaultsPath: join(TMP, 'no-such-ruleset.json') }),
    /cannot read bundled default ruleset/,
  );
});

test('(follow-up) a missing bundled schema throws once a user profile is present', () => {
  const p = writeProfile({ ...validBase() });
  assert.throws(
    () => loadProfile({ dataDir: TMP, profilePath: p, schemaPath: join(TMP, 'no-such-schema.json') }),
    /cannot read tax-profile schema/,
  );
});

test('(follow-up) the freeze is deep — nested-beyond-two-levels values are frozen', () => {
  const r = loadProfile({ dataDir: TMP, profilePath: ABSENT });
  // standardDeductionByYear → single → '2025' is three levels deep.
  assert.ok(Object.isFrozen(r.profile.standardDeductionByYear.single));
  assert.throws(() => {
    r.profile.standardDeductionByYear.single['2025'] = 1;
  }, TypeError);
});

// --- (#169) path containment: reads outside the allowlisted roots refused ---
// The loader's allowlist is the resolved dataDir (here: the explicit TMP root)
// plus the bundled assets/tax/ dir. Everything below targets a SECOND temp dir
// outside both roots, holding a schema-VALID profile — proving each refusal
// comes from containment, never from validation.

const OUTSIDE = mkdtempSync(join(tmpdir(), 'ynab-tax-outside-'));
writeFileSync(join(OUTSIDE, 'secret.json'), JSON.stringify(validBase()));

test('(#169) a `..`-traversal profilePath escaping the dataDir root is refused unread', () => {
  const escaping = join(TMP, '..', basename(OUTSIDE), 'secret.json');
  const r = loadProfile({ dataDir: TMP, profilePath: escaping });
  assert.equal(r.ok, false);
  assert.equal(r.error.kind, 'containment');
  assert.equal(r.error.errors[0].keyword, 'containment');
  assert.match(r.error.message, /outside the allowed roots/);
  assert.equal(r.profile, null);
  assert.equal(r.provenance, null);
});

test('(#169) a symlink inside the root pointing outside it is refused (realpath, not lexical)', () => {
  const link = join(TMP, 'sneaky-link.json');
  symlinkSync(join(OUTSIDE, 'secret.json'), link);
  const r = loadProfile({ dataDir: TMP, profilePath: link });
  assert.equal(r.ok, false);
  assert.equal(r.error.kind, 'containment');
  assert.equal(r.profile, null);
});

test('(#169) an absolute profilePath outside every root is refused even though the file exists and is valid', () => {
  const r = loadProfile({ dataDir: TMP, profilePath: join(OUTSIDE, 'secret.json') });
  assert.equal(r.ok, false);
  assert.equal(r.error.kind, 'containment');
});

test('(#169) an escaping profilePath is refused even when ABSENT (no existence oracle)', () => {
  const r = loadProfile({ dataDir: TMP, profilePath: join(OUTSIDE, 'does-not-exist.json') });
  assert.equal(r.ok, false);
  assert.equal(r.error.kind, 'containment');
});

test('(#169) an escaping defaultsPath is a structured containment failure, not a packaging throw', () => {
  const r = loadProfile({ dataDir: TMP, profilePath: ABSENT, defaultsPath: join(OUTSIDE, 'evil-defaults.json') });
  assert.equal(r.ok, false);
  assert.equal(r.error.kind, 'containment');
});

test('(#169) an escaping schemaPath is a structured containment failure', () => {
  const p = writeProfile(validBase());
  const r = loadProfile({ dataDir: TMP, profilePath: p, schemaPath: join(OUTSIDE, 'evil-schema.json') });
  assert.equal(r.ok, false);
  assert.equal(r.error.kind, 'containment');
});

// --- cleanup ----------------------------------------------------------------

test.after(() => {
  rmSync(TMP, { recursive: true, force: true });
  rmSync(OUTSIDE, { recursive: true, force: true });
});
