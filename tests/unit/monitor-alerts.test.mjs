// tests/unit/monitor-alerts.test.mjs — unit tests for the alert rules config +
// notification dispatch (lib/monitor/alerts.mjs, issue #80 / M6-2).
//
// Runs under the built-in node:test runner with NO node_modules present (only
// node: built-ins and repo-local files are imported), per docs/testing.md. The
// module resolves config and log paths from documented seams, so these tests
// point it at temp files — never the user's real data dir. The notification
// path is stubbed (platform + spawnImpl seams) so the suite passes on
// non-darwin CI.
//
// Covers the AC test matrix: severity-descending ordering, the rendered
// emoji-prefix format, and the best-effort notification path — plus zero-config
// defaults, per-field fallback on invalid config (including boundary values),
// the dollars→milliunits boundary conversion, the dedupe_key format, the top-N
// cap, malformed-finding tolerance (the NEVER-throws contract), the always-on
// alert log and its enforced owner-only modes, the config-file fallback seam,
// the channel switch, and the stdout discipline.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

import {
  ACTION,
  ATTENTION,
  INFO,
  SEVERITY_EMOJI,
  MAX_FINDINGS,
  CHANNEL_MACOS,
  CHANNEL_LOG_ONLY,
  CHANNELS,
  DEFAULT_ALERTS_CONFIG,
  dollarsToMilliunits,
  dedupeKey,
  sanitizeAlertsConfig,
  loadAlertsConfig,
  sortFindings,
  renderAlerts,
  sendMacNotification,
  resolveAlertLogPath,
  appendAlertLog,
  dispatchAlerts,
} from '../../lib/monitor/alerts.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const MODULE_PATH = join(ROOT, 'lib', 'monitor', 'alerts.mjs');

const TMP = mkdtempSync(join(tmpdir(), 'ynab-alerts-'));
let seq = 0;
const freshPath = (name) => join(TMP, `${seq++}-${name}`);

const finding = (severity, n = 1) => ({
  severity,
  title: `${severity} finding ${n}.`,
  detail: `detail for ${severity} ${n}`,
  suggested_action: `Do the ${severity} thing ${n}.`,
  dedupe_key: dedupeKey('test_condition', `subject-${n}`, '2026-07'),
});

// --- Config: zero-config defaults + sanitization ------------------------------

test('zero-config: sanitizeAlertsConfig with no block returns the documented defaults', () => {
  for (const raw of [undefined, null, 'nope', []]) {
    const cfg = sanitizeAlertsConfig(raw);
    assert.equal(cfg.enabled, true);
    assert.equal(cfg.largeTransactionMilliunits, 500000);
    assert.equal(cfg.unusualMultiplier, 3);
    assert.equal(cfg.budgetOverrunPct, 100);
    assert.equal(cfg.billDueLookaheadDays, 3);
    assert.equal(cfg.overdrawn, true);
    assert.equal(cfg.channel, CHANNEL_MACOS);
  }
});

test('sanitizeAlertsConfig: valid overrides are honoured, invalid fields fall back per-field', () => {
  const cfg = sanitizeAlertsConfig({
    enabled: false,
    large_transaction_amount: -20, // invalid → default 500
    unusual_multiplier: 5, // valid
    budget_overrun_pct: 'lots', // invalid → default 100
    bill_due_lookahead_days: 1.5, // not an integer → default 3
    overdrawn: false,
    channel: 'carrier-pigeon', // unknown → default channel
  });
  assert.equal(cfg.enabled, false);
  assert.equal(cfg.largeTransactionMilliunits, 500000);
  assert.equal(cfg.unusualMultiplier, 5);
  assert.equal(cfg.budgetOverrunPct, 100);
  assert.equal(cfg.billDueLookaheadDays, 3);
  assert.equal(cfg.overdrawn, false);
  assert.equal(cfg.channel, CHANNEL_MACOS);
});

test('sanitizeAlertsConfig boundaries: 0 lookahead days is valid, negative rates fall back', () => {
  const cfg = sanitizeAlertsConfig({
    bill_due_lookahead_days: 0, // the valid >= 0 edge — "due today only"
    unusual_multiplier: -3, // negative → default 3
    budget_overrun_pct: -100, // negative → default 100
  });
  assert.equal(cfg.billDueLookaheadDays, 0);
  assert.equal(cfg.unusualMultiplier, 3);
  assert.equal(cfg.budgetOverrunPct, 100);
});

test('dollar thresholds are converted to milliunits at the config boundary (× 1000)', () => {
  assert.equal(dollarsToMilliunits(500), 500000);
  assert.equal(dollarsToMilliunits(0.5), 500);
  assert.equal(sanitizeAlertsConfig({ large_transaction_amount: 125 }).largeTransactionMilliunits, 125000);
  // The default config block itself is dollar-denominated; the loaded shape never is.
  assert.equal(DEFAULT_ALERTS_CONFIG.large_transaction_amount, 500);
});

test('loadAlertsConfig: missing file, absent block, and partial block all degrade safely', () => {
  // dataDir: TMP names the containment root (#244) — every freshPath lives under
  // TMP, so these contained reads pass the guard and exercise the degrade paths.
  // Missing file → defaults (zero-config requirement), never a throw.
  const missing = loadAlertsConfig({ configFile: freshPath('no-such-config.json'), dataDir: TMP });
  assert.equal(missing.largeTransactionMilliunits, 500000);

  // Present file with no alerts block → defaults.
  const noBlock = freshPath('config-noblock.json');
  writeFileSync(noBlock, JSON.stringify({ schema_version: 1 }));
  assert.equal(loadAlertsConfig({ configFile: noBlock, dataDir: TMP }).channel, CHANNEL_MACOS);

  // Partial block → merge over defaults.
  const partial = freshPath('config-partial.json');
  writeFileSync(partial, JSON.stringify({ alerts: { large_transaction_amount: 250, channel: 'log-only' } }));
  const cfg = loadAlertsConfig({ configFile: partial, dataDir: TMP });
  assert.equal(cfg.largeTransactionMilliunits, 250000);
  assert.equal(cfg.channel, CHANNEL_LOG_ONLY);
  assert.equal(cfg.unusualMultiplier, 3);

  // Malformed JSON → defaults, never a throw.
  const bad = freshPath('config-bad.json');
  writeFileSync(bad, '{ this is not json');
  assert.equal(loadAlertsConfig({ configFile: bad, dataDir: TMP }).enabled, true);
});

// --- dedupe_key format ---------------------------------------------------------

test('dedupeKey renders the canonical {type}:{account_or_category}:{period} shape', () => {
  assert.equal(dedupeKey('large_transaction', 'acct-1', '2026-06'), 'large_transaction:acct-1:2026-06');
  assert.equal(dedupeKey('budget_overrun', 'Groceries', '2026-07'), 'budget_overrun:Groceries:2026-07');
});

// --- Ordering + rendering -------------------------------------------------------

test('sortFindings orders most-severe first and is stable within a severity', () => {
  const list = [finding(INFO, 1), finding(ACTION, 2), finding(ATTENTION, 3), finding(ACTION, 4)];
  const sorted = sortFindings(list);
  assert.deepEqual(sorted.map((f) => f.severity), [ACTION, ACTION, ATTENTION, INFO]);
  // Stable: action 2 (given first) stays ahead of action 4.
  assert.deepEqual(sorted.slice(0, 2).map((f) => f.title), ['action finding 2.', 'action finding 4.']);
  // Pure: the input order is untouched.
  assert.equal(list[0].severity, INFO);
});

test('renderAlerts renders {emoji} **title** action, one line per finding, severity-descending', () => {
  const rendered = renderAlerts([finding(INFO, 1), finding(ACTION, 2), finding(ATTENTION, 3)]);
  const lines = rendered.split('\n');
  assert.equal(lines.length, 3);
  assert.equal(lines[0], `${SEVERITY_EMOJI[ACTION]} **action finding 2.** Do the action thing 2.`);
  assert.equal(lines[1], `${SEVERITY_EMOJI[ATTENTION]} **attention finding 3.** Do the attention thing 3.`);
  assert.equal(lines[2], `${SEVERITY_EMOJI[INFO]} **info finding 1.** Do the info thing 1.`);
  // Emoji taxonomy pinned to the frozen dispatch contract (docs/dispatch-format.md).
  assert.equal(SEVERITY_EMOJI[ACTION], '🔴');
  assert.equal(SEVERITY_EMOJI[ATTENTION], '🟡');
  assert.equal(SEVERITY_EMOJI[INFO], '🟢');
  for (const line of lines) {
    assert.match(line, /^(🔴|🟡|🟢) \*\*.+\*\* .+$/);
  }
});

test('renderAlerts caps at MAX_FINDINGS, keeping the most severe', () => {
  const many = [
    finding(INFO, 1), finding(INFO, 2), finding(ATTENTION, 3),
    finding(ACTION, 4), finding(ATTENTION, 5), finding(ACTION, 6), finding(INFO, 7),
  ];
  const lines = renderAlerts(many).split('\n');
  assert.equal(lines.length, MAX_FINDINGS);
  // The two actions and two attentions all survive; only one info makes the cut.
  assert.deepEqual(lines.map((l) => l.slice(0, 2).trim()), ['🔴', '🔴', '🟡', '🟡', '🟢']);
});

test('renderAlerts skips malformed elements (no throw, no cap slot) and renders unknown severities as 🟢', () => {
  const unknown = { severity: 'catastrophic', title: 'odd one.', detail: 'd', suggested_action: 'Look.', dedupe_key: 'k:s:p' };
  const lines = renderAlerts([null, finding(ACTION, 1), undefined, 42, unknown]).split('\n');
  assert.deepEqual(lines, [
    `${SEVERITY_EMOJI[ACTION]} **action finding 1.** Do the action thing 1.`,
    '🟢 **odd one.** Look.', // unknown severity → the documented 🟢 fallback
  ]);
  // Malformed elements never consume a cap slot: MAX_FINDINGS junk entries
  // ahead of a valid finding still leave room for it.
  const junkFirst = Array.from({ length: MAX_FINDINGS }, () => null).concat([finding(INFO, 9)]);
  assert.equal(renderAlerts(junkFirst), `${SEVERITY_EMOJI[INFO]} **info finding 9.** Do the info thing 9.`);
});

// --- Best-effort notification -----------------------------------------------------

test('sendMacNotification is a no-op off darwin: returns false, never spawns', () => {
  let called = false;
  const ok = sendMacNotification('hello', { platform: 'linux', spawnImpl: () => { called = true; return { status: 0 }; } });
  assert.equal(ok, false);
  assert.equal(called, false);
});

test('sendMacNotification passes text as argv (injection-safe) and reports success', () => {
  let seen;
  const ok = sendMacNotification('body "quoted" text', {
    platform: 'darwin',
    spawnImpl: (cmd, args) => { seen = { cmd, args }; return { status: 0 }; },
  });
  assert.equal(ok, true);
  assert.equal(seen.cmd, 'osascript');
  // The body travels as an argv item, never interpolated into AppleScript source.
  assert.ok(seen.args.includes('body "quoted" text'));
  assert.ok(!seen.args.some((a) => a.includes('display notification "body')));
});

test('sendMacNotification is best-effort: a throwing or failing notifier returns false, never throws', () => {
  const threw = sendMacNotification('x', {
    platform: 'darwin',
    spawnImpl: () => { throw new Error('osascript missing'); },
  });
  assert.equal(threw, false);
  const failed = sendMacNotification('x', {
    platform: 'darwin',
    spawnImpl: () => ({ status: 1 }),
  });
  assert.equal(failed, false);
});

// --- Dispatch: log always, channel switch, no-ops -----------------------------------

test('dispatchAlerts appends to the alert log regardless of channel (the audit trail)', () => {
  for (const channel of CHANNELS) {
    const logPath = freshPath(`alert-log-${channel}.jsonl`);
    const config = sanitizeAlertsConfig({ channel });
    const result = dispatchAlerts([finding(ACTION, 1)], {
      config, logPath, dataDir: TMP, platform: 'darwin', spawnImpl: () => ({ status: 0 }), now: '2026-07-16T08:00:00Z',
    });
    assert.equal(result.dispatched, true);
    assert.equal(result.logPath, logPath);
    const entry = JSON.parse(readFileSync(logPath, 'utf8').trim());
    assert.equal(entry.timestamp, '2026-07-16T08:00:00Z');
    assert.equal(entry.channel, channel);
    assert.equal(entry.findings.length, 1);
    // The log carries the FULL finding — detail and dedupe_key included.
    assert.equal(entry.findings[0].detail, 'detail for action 1');
    assert.equal(entry.findings[0].dedupe_key, 'test_condition:subject-1:2026-07');
    assert.match(entry.rendered, /^🔴 \*\*action finding 1\.\*\*/);
  }
});

test('dispatchAlerts channel switch: macos-notification notifies, log-only does not', () => {
  let spawned = 0;
  const spawnImpl = () => { spawned += 1; return { status: 0 }; };

  const mac = dispatchAlerts([finding(ATTENTION, 1)], {
    config: sanitizeAlertsConfig({ channel: CHANNEL_MACOS }),
    logPath: freshPath('switch-mac.jsonl'), dataDir: TMP, platform: 'darwin', spawnImpl,
  });
  assert.equal(mac.notified, true);
  assert.equal(spawned, 1);

  const logOnly = dispatchAlerts([finding(ATTENTION, 2)], {
    config: sanitizeAlertsConfig({ channel: CHANNEL_LOG_ONLY }),
    logPath: freshPath('switch-log.jsonl'), dataDir: TMP, platform: 'darwin', spawnImpl,
  });
  assert.equal(logOnly.notified, false);
  assert.equal(spawned, 1, 'log-only must not spawn a notifier');
});

test('dispatchAlerts strips markdown bold from the notification text', () => {
  let body;
  dispatchAlerts([finding(ACTION, 1)], {
    config: sanitizeAlertsConfig({}),
    logPath: freshPath('strip.jsonl'),
    dataDir: TMP,
    platform: 'darwin',
    spawnImpl: (cmd, args) => { body = args.at(-2); return { status: 0 }; },
  });
  assert.ok(!body.includes('**'), 'notification body carries no markdown bold markers');
  assert.ok(body.includes('action finding 1.'));
});

test('dispatchAlerts is a complete no-op when disabled or when there are no findings', () => {
  const logPath = freshPath('noop.jsonl');
  const disabled = dispatchAlerts([finding(ACTION, 1)], {
    config: sanitizeAlertsConfig({ enabled: false }), logPath,
  });
  assert.deepEqual(disabled, { dispatched: false, rendered: '', logPath: null, notified: false });
  const empty = dispatchAlerts([], { config: sanitizeAlertsConfig({}), logPath });
  assert.equal(empty.dispatched, false);
  assert.equal(existsSync(logPath), false, 'no-op dispatch writes no log');
});

test('dispatchAlerts caps the log entry at MAX_FINDINGS, most-severe first', () => {
  const logPath = freshPath('cap.jsonl');
  const many = [1, 2, 3].map((n) => finding(INFO, n))
    .concat([4, 5, 6].map((n) => finding(ACTION, n)));
  dispatchAlerts(many, { config: sanitizeAlertsConfig({ channel: CHANNEL_LOG_ONLY }), logPath, dataDir: TMP });
  const entry = JSON.parse(readFileSync(logPath, 'utf8').trim());
  assert.equal(entry.findings.length, MAX_FINDINGS);
  assert.deepEqual(entry.findings.slice(0, 3).map((f) => f.severity), [ACTION, ACTION, ACTION]);
});

test('dispatchAlerts never throws when the log append fails (unattended pass survives)', () => {
  // A logPath that is itself a DIRECTORY: it canonicalizes INSIDE TMP so it
  // passes the #244 containment guard, but appendFileSync then fails EISDIR — the
  // write throws inside dispatchAlerts's try/catch, which must swallow it and
  // keep the pass alive. (Testing the IO-failure catch specifically, distinct
  // from a containment refusal — an escaping path is covered in
  // containment.test.mjs.)
  const logDir = freshPath('log-is-a-dir');
  mkdirSync(logDir);
  const result = dispatchAlerts([finding(ACTION, 1)], {
    config: sanitizeAlertsConfig({ channel: CHANNEL_LOG_ONLY }),
    logPath: logDir, dataDir: TMP,
  });
  assert.equal(result.dispatched, true);
  assert.equal(result.logPath, null);
});

test('dispatchAlerts never throws on malformed findings — junk is dropped, valid ones still dispatch', () => {
  // The NEVER-throws contract: a single bad element from a detector must not
  // kill an unattended monitor pass (renderAlerts used to dereference it
  // outside dispatchAlerts's try/catch).
  const logPath = freshPath('malformed.jsonl');
  const result = dispatchAlerts([finding(ACTION, 1), null, undefined, 42, 'junk'], {
    config: sanitizeAlertsConfig({ channel: CHANNEL_LOG_ONLY }), logPath, dataDir: TMP,
  });
  assert.equal(result.dispatched, true);
  assert.equal(result.rendered.split('\n').length, 1, 'only the valid finding renders');
  const entry = JSON.parse(readFileSync(logPath, 'utf8').trim());
  assert.deepEqual(entry.findings.map((f) => f.severity), [ACTION], 'junk never reaches the audit log');

  // A list with NO valid finding left is the same complete no-op as an empty list.
  const noopLog = freshPath('all-malformed.jsonl');
  const noop = dispatchAlerts([null, 'junk'], { config: sanitizeAlertsConfig({}), logPath: noopLog });
  assert.equal(noop.dispatched, false);
  assert.equal(existsSync(noopLog), false);
});

test('dispatchAlerts never throws on poisoned finding FIELDS — exotic objects degrade, never crash', () => {
  // A finding can pass the is-object gate and still be hostile: a throwing
  // getter or a Symbol-valued field used to blow up in renderAlerts's template
  // literal — outside dispatchAlerts's try/catch — and a throwing `severity`
  // getter would blow up even earlier, in sortFindings. Boundary normalization
  // must degrade the poisoned field, keep the finding, and keep the audit log.
  const logPath = freshPath('poisoned.jsonl');
  const base = { detail: 'd', suggested_action: 'Act.', dedupe_key: 'k:s:p' };
  const poisoned = [
    finding(ACTION, 1), // the healthy control
    { ...base, severity: ATTENTION, get title() { throw new Error('boom'); } },
    { ...base, severity: ATTENTION, title: Symbol('x') },
    { ...base, title: 'sev getter throws.', get severity() { throw new Error('boom'); } },
    { ...base, title: 'unstringable severity.', severity: { toString() { throw new Error('boom'); } } },
  ];
  const result = dispatchAlerts(poisoned, {
    config: sanitizeAlertsConfig({ channel: CHANNEL_LOG_ONLY }), logPath, dataDir: TMP,
  });
  assert.equal(result.dispatched, true);
  const lines = result.rendered.split('\n');
  assert.equal(lines.length, 5, 'poisoned fields degrade — the findings still deliver');
  // The healthy finding is untouched and sorts first.
  assert.equal(lines[0], `${SEVERITY_EMOJI[ACTION]} **action finding 1.** Do the action thing 1.`);
  // A throwing title getter degrades to an empty string; severity survives.
  assert.equal(lines[1], '🟡 **** Act.');
  // A Symbol title degrades to its string form instead of throwing in the template literal.
  assert.equal(lines[2], '🟡 **Symbol(x)** Act.');
  // A throwing or unstringable severity normalizes to the documented 🟢 INFO fallback.
  assert.equal(lines[3], '🟢 **sev getter throws.** Act.');
  assert.equal(lines[4], '🟢 **unstringable severity.** Act.');
  // The audit-log write survives too: the entry records plain, safe strings.
  const entry = JSON.parse(readFileSync(logPath, 'utf8').trim());
  assert.equal(entry.findings.length, 5);
  assert.equal(entry.findings[1].title, '');
  assert.equal(entry.findings[2].title, 'Symbol(x)');
  assert.deepEqual(entry.findings.map((f) => f.severity), [ACTION, ATTENTION, ATTENTION, INFO, INFO]);

  // renderAlerts is total on its own, too — direct callers get the same guarantee.
  assert.equal(
    renderAlerts([{ severity: INFO, get title() { throw new Error('boom'); }, suggested_action: 'A.' }]),
    `${SEVERITY_EMOJI[INFO]} **** A.`,
  );
});

test('appendAlertLog enforces owner-only modes on every append, not just at creation', () => {
  // A pre-existing dir/file left at looser modes (an earlier run, tampering)
  // must be tightened by the append — creation-time `mode` options alone never
  // re-assert anything. Mirrors bin/audit-log.sh and the writeState mode test.
  const dir = join(TMP, `loose-${seq++}`);
  const logPath = join(dir, 'alert-log.jsonl');
  mkdirSync(dir, { recursive: true });
  writeFileSync(logPath, '{"stale":true}\n');
  chmodSync(dir, 0o755);
  chmodSync(logPath, 0o644);
  appendAlertLog({ probe: true }, { logPath, dataDir: TMP });
  assert.equal(statSync(logPath).mode & 0o777, 0o600);
  assert.equal(statSync(dir).mode & 0o777, 0o700);
});

test('dispatchAlerts loads config through the configFile seam when none is pre-supplied', () => {
  // The production path: the monitor pass calls dispatchAlerts with no
  // pre-loaded config, so the options.config ?? loadAlertsConfig fallback is
  // what actually runs — drive it end-to-end and let the file govern dispatch.
  const configFile = freshPath('dispatch-config.json');
  writeFileSync(configFile, JSON.stringify({ alerts: { channel: 'log-only' } }));
  const logPath = freshPath('config-seam.jsonl');
  let spawned = 0;
  const result = dispatchAlerts([finding(ACTION, 1)], {
    configFile, logPath, dataDir: TMP, env: {}, platform: 'darwin',
    spawnImpl: () => { spawned += 1; return { status: 0 }; },
  });
  assert.equal(result.dispatched, true);
  assert.equal(result.notified, false, 'the file-loaded log-only channel governs delivery');
  assert.equal(spawned, 0);
  assert.equal(JSON.parse(readFileSync(logPath, 'utf8').trim()).channel, CHANNEL_LOG_ONLY);

  // enabled: false from the file short-circuits the same way a passed config does.
  const offFile = freshPath('dispatch-config-off.json');
  writeFileSync(offFile, JSON.stringify({ alerts: { enabled: false } }));
  const offLog = freshPath('config-seam-off.jsonl');
  const off = dispatchAlerts([finding(ACTION, 1)], { configFile: offFile, logPath: offLog, dataDir: TMP, env: {} });
  assert.equal(off.dispatched, false);
  assert.equal(existsSync(offLog), false);
});

// --- Path seam ------------------------------------------------------------------

test('resolveAlertLogPath honours logPath → YNAB_ALERT_LOG_FILE → YNAB_DATA_DIR', () => {
  assert.equal(resolveAlertLogPath({ logPath: '/x/y.jsonl', env: {} }), '/x/y.jsonl');
  assert.equal(resolveAlertLogPath({ env: { YNAB_ALERT_LOG_FILE: '/env/log.jsonl' } }), '/env/log.jsonl');
  assert.equal(resolveAlertLogPath({ env: { YNAB_DATA_DIR: '/data' } }), join('/data', 'alert-log.jsonl'));
});

// --- Stdout discipline ------------------------------------------------------------

test('a full dispatch emits NOTHING to stdout (MCP/JSON-RPC safety)', () => {
  const logPath = freshPath('stdout-check.jsonl');
  const script = `
    import { dispatchAlerts, sanitizeAlertsConfig } from ${JSON.stringify(MODULE_PATH)};
    dispatchAlerts(
      [{ severity: 'action', title: 't.', detail: 'd', suggested_action: 'a.', dedupe_key: 'k:s:p' }],
      { config: sanitizeAlertsConfig({ channel: 'log-only' }), logPath: ${JSON.stringify(logPath)}, dataDir: ${JSON.stringify(TMP)} },
    );
  `;
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', script], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, '', 'alert dispatch must write nothing to stdout');
});

// --- Launcher isolation -------------------------------------------------------------

test('the launcher never reads the alerts block: bin/launcher.sh code touches neither alerts nor config.json', () => {
  const code = readFileSync(join(ROOT, 'bin', 'launcher.sh'), 'utf8')
    .split('\n')
    .filter((line) => !line.trim().startsWith('#')) // comments may EXPLAIN the isolation
    .join('\n');
  assert.ok(!code.includes('alerts'), 'launcher code must not reference the alerts config block');
  assert.ok(!code.includes('config.json'), 'launcher code must not read config.json');
  assert.ok(!code.includes('config.sh'), 'launcher must never source bin/config.sh');
});
