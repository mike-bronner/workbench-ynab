// lib/monitor/state.mjs — the workbench-ynab monitor state store (issue #79, M6-1).
//
// WHAT THIS IS
//   The single, idempotent way to read, advance, and persist the between-run
//   monitoring snapshot at
//   ~/.claude/plugins/data/workbench-ynab-claude-workbench/monitor-state.json.
//   The proactive-monitor pass (skills/monitor/SKILL.md) reads the prior
//   snapshot, fetches fresh YNAB data through the vendored MCP, then feeds the
//   fresh observation here to compute and persist the next snapshot. This module
//   owns ONLY the state primitives — it performs no YNAB calls and no network IO.
//
//   This is the SCAFFOLD: it updates state and surfaces a structured observation
//   for future detectors (M6-3). It dispatches NO alerts and contains NO detector
//   logic. The `firedAlerts` dedupe ledger is part of the schema from the start so
//   M6-3 can populate it; recordFiredAlert already skips a key that exists, so the
//   same condition is never re-announced across polls.
//
// WHO CALLS THIS
//   The monitor SKILL (via a thin node invocation), never the vendored YNAB MCP
//   launcher. Pure local state resolution: no network, no YNAB calls.
//
// STDOUT / STDERR DISCIPLINE
//   This module emits NOTHING to stdout. It returns structured results and writes
//   only to the state file. Keeping stdout clean means it is safe even if invoked
//   from a JSON-RPC / MCP path, where one stray stdout byte corrupts the handshake
//   (see workbench-core/hooks/mcp-memory.sh). Any diagnostic must go to stderr.
//
// MONEY UNITS
//   Every balance here is in YNAB MILLIUNITS (integers) — never dollars. Divide by
//   1000 only for display/log output (milliunitsToDollars). Persisting milliunits
//   keeps the stored snapshot exact (no float drift) and lets detectors compare
//   integers.

import { randomBytes } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync, existsSync, renameSync, rmSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';

import { assertContained, resolveRoots } from '../containment.mjs';

// Out-of-repo data dir, mirroring bin/config.sh and lib/tax/loadProfile.mjs.
// Overridable for the test harness via the YNAB_DATA_DIR / YNAB_MONITOR_STATE_FILE
// env seams, exactly as the config loader honours YNAB_CONFIG_FILE.
const DATA_DIR_REL = join('.claude', 'plugins', 'data', 'workbench-ynab-claude-workbench');
const STATE_FILENAME = 'monitor-state.json';

/**
 * A fresh, empty monitor snapshot. A first run creates exactly these top-level
 * fields; every later run advances them in place without adding or duplicating a
 * key. This is the canonical required-field set of monitor-state.json.
 */
export function defaultState() {
  return {
    lastPollTimestamp: null, // ISO-8601 string once a pass has run
    accounts: {}, // accountId → { cleared, uncleared } in MILLIUNITS (integers)
    serverKnowledge: null, // YNAB delta cursor (integer) or null before the first delta
    firedAlerts: {}, // dedupe ledger: stable condition key → payload (M6-3 populates)
  };
}

/**
 * Resolve the state-file path: explicit `options.statePath` → env
 * YNAB_MONITOR_STATE_FILE → `<dataDir>/monitor-state.json`, where dataDir is
 * `options.dataDir` → env YNAB_DATA_DIR → the canonical plugin-data dir.
 */
export function resolveStatePath(options = {}) {
  const env = options.env ?? process.env;
  if (options.statePath) return options.statePath;
  if (env.YNAB_MONITOR_STATE_FILE) return env.YNAB_MONITOR_STATE_FILE;
  const dataDir = options.dataDir ?? env.YNAB_DATA_DIR ?? join(homedir(), DATA_DIR_REL);
  return join(dataDir, STATE_FILENAME);
}

// Containment allowlist for the state file (#169 → #206): the resolved data dir
// — options.dataDir → env YNAB_DATA_DIR → the canonical plugin-data dir. Naming
// a root is an embedding-level trust decision (the test seam), so an explicit
// dataDir joins the allowlist WITHOUT widening the default no-options surface;
// an explicit statePath never vouches for itself. An unresolvable root is
// dropped by resolveRoots (fail closed — every access then refused).
function stateRoots(options = {}) {
  const env = options.env ?? process.env;
  return resolveRoots([options.dataDir ?? env.YNAB_DATA_DIR ?? join(homedir(), DATA_DIR_REL)]);
}

// Merge a parsed (possibly partial or older) snapshot over the default shape so the
// returned state always carries exactly the required top-level fields — no missing
// key, no stray key. This is what keeps a second run from duplicating fields and
// lets the schema grow forward without orphaning an old file.
function normalize(raw) {
  const base = defaultState();
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return base;
  const obj = (v) => (v !== null && typeof v === 'object' && !Array.isArray(v));
  return {
    lastPollTimestamp: typeof raw.lastPollTimestamp === 'string' ? raw.lastPollTimestamp : base.lastPollTimestamp,
    accounts: obj(raw.accounts) ? raw.accounts : base.accounts,
    serverKnowledge: Number.isInteger(raw.serverKnowledge) ? raw.serverKnowledge : base.serverKnowledge,
    firedAlerts: obj(raw.firedAlerts) ? raw.firedAlerts : base.firedAlerts,
  };
}

/**
 * Read the persisted snapshot. An ABSENT file is a normal first-run result:
 * returns the default state with `existed:false`. A present-but-unparseable file
 * heals forward — treated as first-run rather than crashing an unattended pass;
 * the next write rewrites a clean file. The returned state always carries every
 * required field (normalized over the default).
 *
 * Heal-forward covers unreadable CONTENT only. A state path escaping the
 * data-dir root is an illegitimate request, not a corrupt file: it throws a
 * structured `containment` error before any read (#206) — fail closed, never
 * silently swallowed into a fresh default state.
 *
 * @returns {{ state: object, existed: boolean, path: string }}
 * @throws {Error} `code: 'containment'` when the resolved state path
 *   canonicalizes outside the data-dir root — the file is never read.
 */
export function readState(options = {}) {
  const path = resolveStatePath(options);
  // Checked before existsSync (#206): refusing outright (rather than only when
  // the target exists) keeps the failure deterministic and avoids acting as an
  // existence oracle for paths outside the root.
  assertContained('the monitor state', path, stateRoots(options));
  if (!existsSync(path)) return { state: defaultState(), existed: false, path };
  try {
    return { state: normalize(JSON.parse(readFileSync(path, 'utf8'))), existed: true, path };
  } catch (err) {
    // Heal forward rather than crash an unattended pass — but never silently:
    // this catch also covers EACCES, a dir-in-place-of-file, or a TOCTOU ENOENT
    // after the existsSync above, and discarding the persisted serverKnowledge
    // cursor + firedAlerts ledger is worth a diagnostic. Stderr only (see the
    // stdout/stderr discipline note above); the next write rewrites a clean file.
    process.stderr.write(`[monitor] discarding unreadable state at ${path}: ${err.message}\n`);
    return { state: defaultState(), existed: false, path };
  }
}

// True when two milliunit balance maps are identical (same account ids, same
// cleared + uncleared on each). Order-independent.
function balancesEqual(a, b) {
  const ak = Object.keys(a);
  if (ak.length !== Object.keys(b).length) return false;
  return ak.every((id) => b[id] && a[id].cleared === b[id].cleared && a[id].uncleared === b[id].uncleared);
}

/**
 * Compute the next snapshot from the current state and a fresh observation. Pure:
 * does not mutate its arguments and performs no IO.
 *
 * @param {object} state        the current (normalized) snapshot.
 * @param {object} observation  fresh poll result:
 *   { timestamp: ISO-8601 string,
 *     accounts: { [accountId]: { cleared: int-milliunits, uncleared: int-milliunits } },
 *     serverKnowledge?: integer|null,    // new YNAB cursor, when the delta returned one
 *     recentTransactionCount?: integer } // count in the delta / since-last-poll window
 * @returns {{ state: object, changed: boolean, observation: object }}
 *   `changed` is false for a NO-OP pass (balances unchanged AND no new
 *   transactions). `observation` is the structured object detectors (M6-3) will
 *   consume: { accounts, recentTransactionCount }.
 */
export function computeNextState(state, observation) {
  const accounts = observation.accounts ?? {};
  const recentTransactionCount = observation.recentTransactionCount ?? 0;
  const changed = !balancesEqual(state.accounts, accounts) || recentTransactionCount > 0;
  // Persist the new cursor when the delta returned one; otherwise keep the prior
  // cursor (a since-timestamp fallback fetch returns no cursor).
  const serverKnowledge = Number.isInteger(observation.serverKnowledge) ? observation.serverKnowledge : state.serverKnowledge;
  const next = {
    lastPollTimestamp: observation.timestamp,
    accounts,
    serverKnowledge,
    firedAlerts: state.firedAlerts, // scaffold never fires; M6-3 populates via recordFiredAlert
  };
  return { state: next, changed, observation: { accounts, recentTransactionCount } };
}

/**
 * Record a fired-alert dedupe key — the M6-3 seam. The scaffold itself fires no
 * alerts, but the skip-existing semantics are in place from the start: a key that
 * already exists is NOT overwritten (`recorded:false`), so the same condition is
 * never re-announced across polls. Pure — returns a new state, never mutates.
 *
 * @returns {{ state: object, recorded: boolean }}
 */
export function recordFiredAlert(state, key, payload = true) {
  if (Object.prototype.hasOwnProperty.call(state.firedAlerts, key)) return { state, recorded: false };
  return { state: { ...state, firedAlerts: { ...state.firedAlerts, [key]: payload } }, recorded: true };
}

/**
 * Persist a snapshot to monitor-state.json, creating the data dir if needed.
 * Writes to a temp sibling then renames, so a crash mid-write can never leave a
 * truncated state file (mirrors the audit writer's atomic hardening in
 * lib/tax/estimatedTax.mjs saveTracker). Returns the path written. Emits nothing
 * to stdout.
 *
 * This file stores real account balances (milliunits), the same sensitivity
 * class as the tax tracker, so it is written owner-only: the leaf data dir is
 * created 0700 and the file 0600, never world-readable on a shared box. On a
 * failed rename the orphaned temp file is removed so a half-written copy of that
 * data is never left lying around.
 */
export function writeState(state, options = {}) {
  const path = resolveStatePath(options);
  // The write seam is the sharper edge of the #169 class (#206): an unchecked
  // renameSync to a caller-supplied path is an arbitrary-path WRITE primitive.
  // Refused before mkdir/write/rename — nothing is ever created on an escaping
  // path.
  assertContained('the monitor state', path, stateRoots(options), 'write');
  // 0o700 applies only to the LEAF dir created here; a pre-existing parent keeps
  // its own mode. Data stays safe (file 0600, leaf 0700); force-chmod-ing parents
  // we don't own would overreach, so we don't.
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  // The temp sibling is a write seam of its own (#206 review): at a PREDICTABLE
  // name, a pre-planted symlink would be FOLLOWED by writeFileSync, redirecting
  // the bytes outside every root even though `path` itself is contained. Two
  // independent defenses: the name is unpredictable (nothing can be pre-planted
  // at it), and 'wx' (O_CREAT|O_EXCL) refuses ANY existing entry — a symlink,
  // dangling or not, throws EEXIST instead of being followed. Mirrors
  // lib/tax/estimatedTax.mjs saveTracker.
  const tmp = `${path}.${randomBytes(8).toString('hex')}.tmp`;
  writeFileSync(tmp, `${JSON.stringify(state, null, 2)}\n`, { encoding: 'utf8', mode: 0o600, flag: 'wx' });
  try {
    renameSync(tmp, path);
  } catch (err) {
    rmSync(tmp, { force: true });
    throw err;
  }
  return path;
}

/**
 * Convert YNAB milliunits (integer) to dollars (number). Display / log output
 * ONLY — never persist the result; the stored snapshot stays in milliunits.
 */
export function milliunitsToDollars(milliunits) {
  return milliunits / 1000;
}
