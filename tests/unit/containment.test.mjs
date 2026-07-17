// tests/unit/containment.test.mjs — the shared path-containment guard
// (lib/containment.mjs, issue #206, extending issue #169) and its wiring into
// every remaining options/env → filesystem seam: the estimated-tax tracker
// (loadTracker/saveTracker), the confidence config (loadThresholds), and the
// monitor state store (readState/writeState). lib/tax/loadProfile.mjs's own
// wiring keeps its #169 coverage in load-profile.test.mjs.
//
// Runs under the built-in node:test runner with NO node_modules present (only
// node: built-ins and repo-local files), per docs/testing.md.
//
// Pattern (mirroring the #169 tests): every escaping target is a REAL, valid,
// would-succeed-if-accessed file in a second temp dir outside the allowlisted
// root — so a guard that silently skipped containment would surface as a
// *successful* read (or a parse/shape error), never as the structured
// `containment` refusal asserted here. Traversal paths are built by string
// concat, NOT path.join — join() would normalize the `..` away before it could
// reach canonicalize.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, existsSync, readFileSync, writeFileSync, rmSync, symlinkSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';

import {
  canonicalize,
  isWithin,
  buildHomeForms,
  redact,
  resolveRoots,
  checkContainment,
  assertContained,
} from '../../lib/containment.mjs';
import { emptyTracker, loadTracker, saveTracker } from '../../lib/tax/estimatedTax.mjs';
import { loadThresholds, DEFAULT_THRESHOLDS } from '../../lib/tax/confidence.mjs';
import { readState, writeState, defaultState } from '../../lib/monitor/state.mjs';

const ROOT_DIR = mkdtempSync(join(tmpdir(), 'ynab-containment-root-'));
const OUTSIDE = mkdtempSync(join(tmpdir(), 'ynab-containment-outside-'));
mkdirSync(join(OUTSIDE, 'dir'));

// Real, valid files outside the root — each would succeed if actually accessed.
writeFileSync(join(OUTSIDE, 'tracker.json'), JSON.stringify({ schemaVersion: 1, years: {} }));
writeFileSync(join(OUTSIDE, 'config.json'), JSON.stringify({ classification: { highThreshold: 0.9, mediumThreshold: 0.4 } }));
writeFileSync(join(OUTSIDE, 'state.json'), JSON.stringify(defaultState()));

// A traversal path from ROOT_DIR to OUTSIDE/<file>, with the `..` surviving.
const traverse = (file) => `${ROOT_DIR}/../${basename(OUTSIDE)}/${file}`;

// A symlink inside the root pointing at an outside file.
function plantLink(name, target) {
  const link = join(ROOT_DIR, name);
  symlinkSync(join(OUTSIDE, target), link);
  return link;
}

// The structured refusal contract shared by the three throwing seams.
const containmentThrow = (verb = 'read') => (err) =>
  err instanceof Error && err.code === 'containment'
  && new RegExp(`refusing to ${verb} .* outside the allowed roots`).test(err.message);

// --- the helper's own surface ------------------------------------------------

test('canonicalize resolves kernel-order (symlink first, then `..`) — the #169 bypass shape', () => {
  const dirLink = join(ROOT_DIR, 'dir-link');
  symlinkSync(join(OUTSIDE, 'dir'), dirLink);
  // Lexical-first resolution would collapse `dir-link/..` to ROOT_DIR; the
  // kernel resolves the symlink first, landing in OUTSIDE.
  assert.equal(canonicalize(`${dirLink}/../tracker.json`), join(canonicalize(OUTSIDE), 'tracker.json'));
});

test('canonicalize walks up through ENOENT and fails closed on anything else', () => {
  // Absent leaf under a real dir: resolvable via the ancestor walk.
  assert.equal(canonicalize(join(ROOT_DIR, 'not-yet', 'file.json')), join(canonicalize(ROOT_DIR), 'not-yet', 'file.json'));
  // A symlink loop (ELOOP) is unresolvable → null, never a fabricated path.
  const a = join(ROOT_DIR, 'loop-a');
  const b = join(ROOT_DIR, 'loop-b');
  symlinkSync(b, a);
  symlinkSync(a, b);
  assert.equal(canonicalize(a), null);
});

test('isWithin is separator-aware: a sibling sharing the root name as a prefix never passes', () => {
  assert.equal(isWithin('/a/b', '/a/b'), true);
  assert.equal(isWithin('/a/b', '/a/b/c.json'), true);
  assert.equal(isWithin('/a/b', '/a/bc/c.json'), false);
});

test('buildHomeForms degrades to no forms when homedir() throws — import never crashes', () => {
  // os.homedir() can throw (no $HOME + no passwd entry); the guard must degrade
  // to an empty list (redact then no-ops) instead of crashing module evaluation.
  assert.deepEqual(buildHomeForms(() => { throw new Error('uv_os_homedir returned ENOENT'); }), []);
  // And the normal path still yields the raw + canonical spellings, longest first.
  const forms = buildHomeForms();
  assert.ok(forms.length >= 1);
  assert.ok(forms.every((f) => typeof f === 'string' && f.length > 1));
  assert.deepEqual(forms, [...forms].sort((x, y) => y.length - x.length));
});

test('redact masks the home prefix and passes non-strings through', () => {
  assert.equal(redact(join(homedir(), 'secret.json')), join('~', 'secret.json'));
  assert.equal(redact(null), null);
});

test('resolveRoots drops an unresolvable root and keeps the rest — empty list refuses everything', () => {
  const loop = join(ROOT_DIR, 'root-loop-a');
  const loopB = join(ROOT_DIR, 'root-loop-b');
  symlinkSync(loopB, loop);
  symlinkSync(loop, loopB);
  assert.deepEqual(resolveRoots([loop, ROOT_DIR]), [canonicalize(ROOT_DIR)]);
  // No resolvable root → every path (even an in-root one) is refused: fail closed.
  assert.notEqual(checkContainment('x', join(ROOT_DIR, 'f.json'), resolveRoots([loop])), null);
});

test('checkContainment: contained → null; escaping → structured, redacted detail with the verb', () => {
  const roots = resolveRoots([ROOT_DIR]);
  assert.equal(checkContainment('the file', join(ROOT_DIR, 'ok.json'), roots), null);
  const detail = checkContainment('the file', traverse('tracker.json'), roots, 'write');
  assert.equal(detail.kind, 'containment');
  assert.match(detail.message, /refusing to write the file at .*: it resolves outside the allowed roots/);
  assert.ok(Array.isArray(detail.roots));
});

test('assertContained throws the structured containment error and returns silently when contained', () => {
  const roots = resolveRoots([ROOT_DIR]);
  assert.equal(assertContained('the file', join(ROOT_DIR, 'ok.json'), roots), undefined);
  assert.throws(() => assertContained('the file', traverse('tracker.json'), roots), containmentThrow());
});

// --- seam: the estimated-tax tracker (lib/tax/estimatedTax.mjs) --------------

test('(#206) loadTracker refuses a `..`-traversal trackerPath escaping the dataDir root, unread', () => {
  // OUTSIDE/tracker.json is valid tracker JSON — if the guard were skipped the
  // call would RETURN it, so the throw proves the file was never read.
  assert.throws(() => loadTracker({ dataDir: ROOT_DIR, trackerPath: traverse('tracker.json') }), containmentThrow());
});

test('(#206) loadTracker refuses a symlink inside the root pointing outside it (realpath, not lexical)', () => {
  const link = plantLink('sneaky-tracker.json', 'tracker.json');
  assert.throws(() => loadTracker({ dataDir: ROOT_DIR, trackerPath: link }), containmentThrow());
});

test('(#206) saveTracker refuses an escaping write — nothing created, not even the temp sibling', () => {
  const escaping = traverse('planted-tracker.json');
  assert.throws(() => saveTracker(emptyTracker(), { dataDir: ROOT_DIR, trackerPath: escaping }), containmentThrow('write'));
  assert.equal(existsSync(join(OUTSIDE, 'planted-tracker.json')), false, 'escaping tracker was written');
  assert.equal(existsSync(join(OUTSIDE, 'planted-tracker.json.tmp')), false, 'escaping temp sibling was written');
});

test('(#206) saveTracker refuses a symlink escape on the write path', () => {
  const link = plantLink('sneaky-tracker-write.json', 'tracker.json');
  const before = readFileSync(join(OUTSIDE, 'tracker.json'), 'utf8');
  assert.throws(() => saveTracker(emptyTracker(), { dataDir: ROOT_DIR, trackerPath: link }), containmentThrow('write'));
  assert.equal(readFileSync(join(OUTSIDE, 'tracker.json'), 'utf8'), before, 'outside tracker was overwritten');
});

test('(#206) an explicit dataDir names the tracker root — a contained round-trip still works (test seam)', () => {
  const path = saveTracker(emptyTracker(), { dataDir: ROOT_DIR });
  assert.ok(isWithin(canonicalize(ROOT_DIR), canonicalize(path)));
  assert.deepEqual(loadTracker({ dataDir: ROOT_DIR }).years, {});
});

// --- seam: the confidence config (lib/tax/confidence.mjs) --------------------

test('(#206) loadThresholds refuses a `..`-traversal configFile escaping the dataDir root, unread', () => {
  // OUTSIDE/config.json carries valid 0.9/0.4 thresholds — a skipped guard
  // would RETURN them (not the defaults), so the throw proves no read happened.
  assert.throws(() => loadThresholds({ dataDir: ROOT_DIR, configFile: traverse('config.json') }), containmentThrow());
});

test('(#206) loadThresholds refuses a symlink escape via the YNAB_CONFIG_FILE env seam', () => {
  const link = plantLink('sneaky-config.json', 'config.json');
  assert.throws(() => loadThresholds({}, { YNAB_CONFIG_FILE: link, YNAB_DATA_DIR: ROOT_DIR }), containmentThrow());
});

test('(#206) an explicit dataDir names the config root — a contained config still loads (test seam)', () => {
  writeFileSync(join(ROOT_DIR, 'config.json'), JSON.stringify({ classification: { highThreshold: 0.9, mediumThreshold: 0.4 } }));
  assert.deepEqual(
    loadThresholds({ dataDir: ROOT_DIR, configFile: join(ROOT_DIR, 'config.json') }),
    { highThreshold: 0.9, mediumThreshold: 0.4 },
  );
  // An ABSENT-but-contained config still degrades to the defaults (no throw):
  // containment refuses escaping PATHS, it never changes the content contract.
  assert.deepEqual(loadThresholds({ dataDir: ROOT_DIR, configFile: join(ROOT_DIR, 'absent.json') }), DEFAULT_THRESHOLDS);
});

// --- seam: the monitor state store (lib/monitor/state.mjs) -------------------

test('(#206) readState refuses a `..`-traversal statePath escaping the dataDir root, unread', () => {
  // OUTSIDE/state.json is a valid snapshot — a skipped guard would return
  // existed:true, so the throw proves the file was never read.
  assert.throws(() => readState({ dataDir: ROOT_DIR, statePath: traverse('state.json') }), containmentThrow());
});

test('(#206) readState refuses a symlink inside the root pointing outside it', () => {
  const link = plantLink('sneaky-state.json', 'state.json');
  assert.throws(() => readState({ dataDir: ROOT_DIR, statePath: link }), containmentThrow());
});

test('(#206) writeState refuses an escaping write — nothing created, not even the temp sibling', () => {
  const escaping = traverse('planted-state.json');
  assert.throws(() => writeState(defaultState(), { dataDir: ROOT_DIR, statePath: escaping }), containmentThrow('write'));
  assert.equal(existsSync(join(OUTSIDE, 'planted-state.json')), false, 'escaping state was written');
  assert.equal(existsSync(join(OUTSIDE, 'planted-state.json.tmp')), false, 'escaping temp sibling was written');
});

test('(#206) an explicit dataDir names the state root — a contained round-trip still works (test seam)', () => {
  const written = writeState(defaultState(), { dataDir: ROOT_DIR });
  assert.ok(isWithin(canonicalize(ROOT_DIR), canonicalize(written)));
  assert.equal(readState({ dataDir: ROOT_DIR }).existed, true);
});

// --- cleanup ------------------------------------------------------------------

test.after(() => {
  rmSync(ROOT_DIR, { recursive: true, force: true });
  rmSync(OUTSIDE, { recursive: true, force: true });
});
