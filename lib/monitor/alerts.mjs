// lib/monitor/alerts.mjs — alert rules config + notification dispatch (issue #80, M6-2).
//
// WHAT THIS IS
//   The alert half of proactive monitoring: the user-tunable RULES (thresholds
//   read from the `alerts` block of config.json) and the DISPATCH layer that
//   delivers findings. Detectors (M6-3) decide WHAT is alert-worthy; this module
//   owns only how thresholds are loaded and how a finding reaches the user.
//   Keeping rules and dispatch separate from detectors means thresholds stay
//   user-tunable data, never code.
//
// THE FINDING CONTRACT (what M6-3 detectors emit)
//   A finding is a plain object:
//
//     {
//       severity:         'action' | 'attention' | 'info',
//       title:            string,  // the bold one-line statement
//       detail:           string,  // context; carried into the alert log, not rendered
//       suggested_action: string,  // 1–2 sentence recommended action, rendered after the title
//       dedupe_key:       string,  // '{type}:{account_or_category}:{period}' — see dedupeKey()
//     }
//
//   `severity` maps onto the frozen dispatch taxonomy (docs/dispatch-format.md):
//   'action' → 🔴 action required, 'attention' → 🟡 attention needed,
//   'info' → 🟢 good / informational. `dedupe_key` feeds the M6-1 fired-alert
//   ledger (`firedAlerts` in monitor-state.json, lib/monitor/state.mjs
//   recordFiredAlert) so the same condition is never re-announced across polls.
//   The full contract is documented in docs/alerts-config.md.
//
// WHO CALLS THIS
//   The monitor SKILL (via a thin node invocation), never the vendored YNAB MCP
//   launcher. The `alerts` config block is read exclusively here — it is never
//   injected into the launcher environment (the launcher receives only the
//   Keychain token; see bin/launcher.sh and docs/config-loader.md).
//
// MONEY UNITS
//   Config thresholds are entered in WHOLE DOLLARS (human-friendly); YNAB
//   amounts are MILLIUNITS (integers). loadAlertsConfig converts at this
//   boundary (× 1000), so detectors only ever compare milliunits to milliunits.
//
// STDOUT / STDERR DISCIPLINE
//   This module emits NOTHING to stdout. Diagnostics go to stderr only — one
//   stray stdout byte on an MCP/JSON-RPC path corrupts the handshake (see the
//   same note in lib/monitor/state.mjs).

import { appendFileSync, mkdirSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';

// --- Severity taxonomy (public API) ------------------------------------------

export const ACTION = 'action';
export const ATTENTION = 'attention';
export const INFO = 'info';

/** Emoji per severity — MUST agree with the frozen dispatch/report taxonomy
 *  (docs/dispatch-format.md §2: 🔴 is-warning, 🟡 is-attention, 🟢 is-good). */
export const SEVERITY_EMOJI = Object.freeze({
  [ACTION]: '🔴',
  [ATTENTION]: '🟡',
  [INFO]: '🟢',
});

// Descending order of urgency; unknown severities sort last (rendered 🟢-less
// never happens — renderAlerts falls back to INFO for an unknown value).
const SEVERITY_RANK = Object.freeze({ [ACTION]: 0, [ATTENTION]: 1, [INFO]: 2 });

/** Dispatch output is capped at this many findings, most-severe first. Matches
 *  the fixed five of the review dispatch (docs/dispatch-format.md §1). */
export const MAX_FINDINGS = 5;

// --- Delivery channels (public API) -------------------------------------------

/** Default: a macOS desktop notification (darwin is the primary platform). */
export const CHANNEL_MACOS = 'macos-notification';
/** Audit log only — no desktop notification. */
export const CHANNEL_LOG_ONLY = 'log-only';

/** Every recognized `channel` config value. Adding a channel (e.g. a
 *  notification MCP) = a new value here + a new branch in dispatchAlerts —
 *  detector code never changes. */
export const CHANNELS = Object.freeze([CHANNEL_MACOS, CHANNEL_LOG_ONLY]);

// --- Alerts config: defaults + loader -----------------------------------------

// Canonical plugin-data dir, mirroring bin/config.sh and lib/monitor/state.mjs.
const DATA_DIR_REL = join('.claude', 'plugins', 'data', 'workbench-ynab-claude-workbench');
const CONFIG_FILENAME = 'config.json';
const ALERT_LOG_FILENAME = 'alert-log.jsonl';

/**
 * The zero-config defaults, in RAW config.json shape (dollar-denominated, as a
 * user would write them). Monitoring works with no `alerts` block present:
 * every field falls back to these values (docs/alerts-config.md).
 */
export const DEFAULT_ALERTS_CONFIG = Object.freeze({
  enabled: true,
  large_transaction_amount: 500, // whole dollars
  unusual_multiplier: 3,
  budget_overrun_pct: 100,
  bill_due_lookahead_days: 3,
  overdrawn: true,
  channel: CHANNEL_MACOS,
});

/** Convert whole dollars (config units) to YNAB milliunits (API units). */
export function dollarsToMilliunits(dollars) {
  return Math.round(dollars * 1000);
}

/**
 * Build a fired-alert dedupe key in the canonical '{type}:{account_or_category}:{period}'
 * format — e.g. 'large_transaction:acct-1:2026-06'. Detectors key their
 * recordFiredAlert() entries (lib/monitor/state.mjs) with exactly this shape so
 * the M6-1 ledger dedupes a condition across polls.
 */
export function dedupeKey(type, accountOrCategory, period) {
  return `${type}:${accountOrCategory}:${period}`;
}

const isPositiveNumber = (v) => typeof v === 'number' && Number.isFinite(v) && v > 0;

/**
 * Resolve a raw `alerts` block (possibly absent, partial, or malformed) to the
 * guaranteed-sane LOADED shape detectors and the dispatcher consume. User config
 * is a trust boundary: every invalid field falls back to its default, and this
 * never throws. Dollar thresholds are converted to milliunits HERE — the one
 * boundary — so nothing downstream ever mixes units.
 *
 * @returns {{
 *   enabled: boolean,
 *   largeTransactionMilliunits: number,  // large_transaction_amount × 1000
 *   unusualMultiplier: number,
 *   budgetOverrunPct: number,
 *   billDueLookaheadDays: number,
 *   overdrawn: boolean,
 *   channel: string,                     // one of CHANNELS
 * }}
 */
export function sanitizeAlertsConfig(raw) {
  const r = raw !== null && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
  const d = DEFAULT_ALERTS_CONFIG;
  const dollars = isPositiveNumber(r.large_transaction_amount)
    ? r.large_transaction_amount : d.large_transaction_amount;
  return {
    enabled: typeof r.enabled === 'boolean' ? r.enabled : d.enabled,
    largeTransactionMilliunits: dollarsToMilliunits(dollars),
    unusualMultiplier: isPositiveNumber(r.unusual_multiplier) ? r.unusual_multiplier : d.unusual_multiplier,
    budgetOverrunPct: isPositiveNumber(r.budget_overrun_pct) ? r.budget_overrun_pct : d.budget_overrun_pct,
    billDueLookaheadDays: Number.isInteger(r.bill_due_lookahead_days) && r.bill_due_lookahead_days >= 0
      ? r.bill_due_lookahead_days : d.bill_due_lookahead_days,
    overdrawn: typeof r.overdrawn === 'boolean' ? r.overdrawn : d.overdrawn,
    channel: CHANNELS.includes(r.channel) ? r.channel : d.channel,
  };
}

/**
 * Read the `alerts` block from the user's config.json and return the sanitized
 * loaded shape. Path resolution mirrors lib/tax/confidence.mjs loadThresholds
 * (the same seam bin/config.sh honours): `options.configFile` → env
 * `YNAB_CONFIG_FILE` → the canonical plugin-data path. A missing/unreadable/
 * malformed file or an absent `alerts` block degrades to the defaults — never
 * a throw (zero-config requirement).
 */
export function loadAlertsConfig(options = {}, env = process.env) {
  const configFile = options.configFile
    ?? env.YNAB_CONFIG_FILE
    ?? join(homedir(), DATA_DIR_REL, CONFIG_FILENAME);
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(configFile, 'utf8'));
  } catch {
    parsed = {};
  }
  const alerts = parsed !== null && typeof parsed === 'object' ? parsed.alerts : undefined;
  return sanitizeAlertsConfig(alerts);
}

// --- Rendering -----------------------------------------------------------------

const rank = (f) => SEVERITY_RANK[f?.severity] ?? SEVERITY_RANK[INFO];

/**
 * Return a new array of findings ordered most-severe first (action → attention
 * → info). The sort is stable: findings of equal severity keep the order the
 * detector gave them. Pure — never mutates the input.
 */
export function sortFindings(findings) {
  return [...findings].sort((a, b) => rank(a) - rank(b));
}

/**
 * Render a pre-built list of findings to the dispatch text: most-severe first,
 * capped at MAX_FINDINGS, one line per finding in the frozen shape
 * (docs/dispatch-format.md §3):
 *
 *   {emoji} **{title}** {suggested_action}
 *
 * `detail` is NOT rendered — it travels in the alert-log entry for the audit
 * trail. An unknown severity renders as 🟢 (informational) rather than failing
 * an unattended pass. Pure — no IO.
 */
export function renderAlerts(findings) {
  return sortFindings(findings)
    .slice(0, MAX_FINDINGS)
    .map((f) => `${SEVERITY_EMOJI[f.severity] ?? SEVERITY_EMOJI[INFO]} **${f.title}** ${f.suggested_action}`)
    .join('\n');
}

// --- Delivery: macOS notification (best-effort) --------------------------------

/**
 * Fire a macOS desktop notification. BEST-EFFORT BY CONTRACT: returns true on
 * success and false on any failure or on a non-darwin platform — it never
 * throws, so a broken notifier can never crash a monitor pass. The text is
 * passed to osascript as ARGV (never interpolated into the AppleScript source),
 * so finding content cannot inject script.
 *
 * @param {string} body   notification body text.
 * @param {object} [options]
 * @param {string}   [options.title]     notification title (default 'YNAB Monitor').
 * @param {string}   [options.platform]  test seam, defaults to process.platform.
 * @param {Function} [options.spawnImpl] test seam, defaults to node:child_process spawnSync.
 * @returns {boolean} whether the notification was delivered.
 */
export function sendMacNotification(body, options = {}) {
  const platform = options.platform ?? process.platform;
  if (platform !== 'darwin') return false;
  const spawnImpl = options.spawnImpl ?? spawnSync;
  try {
    const result = spawnImpl('osascript', [
      '-e', 'on run argv',
      '-e', 'display notification (item 1 of argv) with title (item 2 of argv)',
      '-e', 'end run',
      body,
      options.title ?? 'YNAB Monitor',
    ], { stdio: 'ignore' });
    return result?.status === 0;
  } catch (err) {
    process.stderr.write(`[alerts] notification failed (best-effort, continuing): ${err.message}\n`);
    return false;
  }
}

// --- Delivery: alert log (the audit trail) --------------------------------------

/**
 * Resolve the alert-log path: explicit `options.logPath` → env
 * YNAB_ALERT_LOG_FILE → `<dataDir>/alert-log.jsonl`, where dataDir is
 * `options.dataDir` → env YNAB_DATA_DIR → the canonical plugin-data dir —
 * exactly the seam lib/monitor/state.mjs resolveStatePath uses.
 */
export function resolveAlertLogPath(options = {}) {
  const env = options.env ?? process.env;
  if (options.logPath) return options.logPath;
  if (env.YNAB_ALERT_LOG_FILE) return env.YNAB_ALERT_LOG_FILE;
  const dataDir = options.dataDir ?? env.YNAB_DATA_DIR ?? join(homedir(), DATA_DIR_REL);
  return join(dataDir, ALERT_LOG_FILENAME);
}

/**
 * Append one JSON line to the alert log, creating the data dir if needed. The
 * log records real financial findings — the same sensitivity class as the
 * monitor state — so the leaf dir is created 0700 and the file 0600, matching
 * lib/monitor/state.mjs writeState. Returns the path written.
 */
export function appendAlertLog(entry, options = {}) {
  const path = resolveAlertLogPath(options);
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  appendFileSync(path, `${JSON.stringify(entry)}\n`, { encoding: 'utf8', mode: 0o600 });
  return path;
}

// --- Dispatch (the channel switch) ----------------------------------------------

/**
 * Deliver a list of structured findings — THE entry point the monitor pass
 * calls. Behaviour:
 *
 *   * `enabled: false` in the alerts config, or an empty findings list, is a
 *     complete no-op (`dispatched: false`).
 *   * Findings are ordered most-severe first and capped at MAX_FINDINGS.
 *   * The rendered alert is ALWAYS appended to the alert log (the audit trail),
 *     regardless of which channel is active.
 *   * The `channel` value then switches delivery: CHANNEL_MACOS additionally
 *     fires a best-effort desktop notification; CHANNEL_LOG_ONLY stops at the
 *     log. Adding a channel = one new branch here + one new CHANNELS value.
 *   * NEVER throws: alert delivery is best-effort end-to-end, so a full disk or
 *     a broken notifier can never crash an unattended monitor pass. Failures go
 *     to stderr.
 *
 * @param {Array<object>} findings  structured findings (see the contract above).
 * @param {object} [options]
 * @param {object} [options.config]  pre-loaded alerts config (loadAlertsConfig
 *   shape); when absent the config is loaded from config.json.
 *   Plus the loadAlertsConfig / resolveAlertLogPath / sendMacNotification seams
 *   (configFile, env, logPath, dataDir, platform, spawnImpl, now).
 * @returns {{ dispatched: boolean, rendered: string, logPath: string|null, notified: boolean }}
 */
export function dispatchAlerts(findings, options = {}) {
  const config = options.config ?? loadAlertsConfig(options, options.env ?? process.env);
  if (!config.enabled || !Array.isArray(findings) || findings.length === 0) {
    return { dispatched: false, rendered: '', logPath: null, notified: false };
  }

  const kept = sortFindings(findings).slice(0, MAX_FINDINGS);
  const rendered = renderAlerts(kept);

  // The audit trail comes first and is channel-independent.
  let logPath = null;
  try {
    logPath = appendAlertLog({
      timestamp: options.now ?? new Date().toISOString(),
      channel: config.channel,
      findings: kept,
      rendered,
    }, options);
  } catch (err) {
    process.stderr.write(`[alerts] alert-log append failed (continuing): ${err.message}\n`);
  }

  // The channel switch. New channels slot in as new branches — detectors and
  // the log path above never change.
  let notified = false;
  switch (config.channel) {
    case CHANNEL_MACOS:
      notified = sendMacNotification(rendered.replace(/\*\*/g, ''), options);
      break;
    case CHANNEL_LOG_ONLY:
    default:
      break;
  }

  return { dispatched: true, rendered, logPath, notified };
}
