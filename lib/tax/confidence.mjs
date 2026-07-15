// lib/tax/confidence.mjs — confidence bands + human-review routing policy for
// classifications (issue #19, GAP-20).
//
// WHAT THIS IS
//   The single place that turns a classifier confidence score (0..1, from the
//   M3-4 mapping engine, lib/tax/classifyTransaction.mjs) into a routing BAND
//   that downstream consumers act on:
//
//     high         → eligible to be PRE-FILLED as an op in the M4-10 apply
//                    proposal (still subject to the human approval gate).
//     medium       → rendered in the M2 report as a "review suggested" item;
//                    NEVER pre-fills a proposal op.
//     low          → flagged for human attention only; no proposed change.
//     unclassified → same as low: human attention only, no proposed change.
//
//   The full consumer contract lives in docs/confidence-contract.md.
//
// CONFIGURABLE, CONSERVATIVE DEFAULTS
//   Thresholds are read from the user's plugin config (config.json) under
//   classification.highThreshold / classification.mediumThreshold via
//   loadThresholds(), falling back to the exported defaults (0.85 / 0.60).
//   The defaults are deliberately conservative: a fresh user errs toward
//   flag-for-review rather than a proposal full of speculative changes.
//   Invalid or contradictory config values fall back to the defaults — a
//   malformed user config must degrade safely, never throw or loosen the bar.
//
// PURITY
//   assignBand() is PURE — no I/O, no side effects. Only loadThresholds()
//   touches the filesystem (one config read), mirroring the loadProfile.mjs
//   pattern: the CALLER resolves config once and passes thresholds into
//   classify(options.thresholds); classify() itself stays pure.

/**
 * Confidence-band policy module (issue #19 / GAP-20).
 *
 * Confidence governs proposal composition only — whether an op is pre-filled
 * in the proposal. The human approval gate is mandatory and independent of
 * confidence; nothing bypasses it.
 *
 * Band semantics (enforced by assignBand):
 *   confidence ≥ HIGH_THRESHOLD                        → 'high'
 *   MEDIUM_THRESHOLD ≤ confidence < HIGH_THRESHOLD     → 'medium'
 *   0 < confidence < MEDIUM_THRESHOLD                  → 'low'
 *   confidence === 0 (or the unclassified sentinel)    → 'unclassified'
 *
 * Split transactions and transfer legs are ambiguous by construction (GAP-19)
 * and are hard-coded by the mapping engine to band 'unclassified' regardless
 * of any computed confidence — no exception path overrides this.
 */

import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

// --- Band constants (public API) ---------------------------------------------

export const HIGH = 'high';
export const MEDIUM = 'medium';
export const LOW = 'low';
export const UNCLASSIFIED = 'unclassified';

// --- Default numeric thresholds (public API) ---------------------------------

// Conservative by design: only strong matches pre-fill a proposal op.
export const HIGH_THRESHOLD = 0.85;
export const MEDIUM_THRESHOLD = 0.6;

/** The default thresholds object, in the exact shape loadThresholds returns. */
export const DEFAULT_THRESHOLDS = Object.freeze({
  highThreshold: HIGH_THRESHOLD,
  mediumThreshold: MEDIUM_THRESHOLD,
});

// Canonical plugin-data dir, mirroring bin/config.sh and lib/tax/loadProfile.mjs.
const DATA_DIR_REL = join('.claude', 'plugins', 'data', 'workbench-ynab-claude-workbench');
const CONFIG_FILENAME = 'config.json';

// A usable threshold is a finite number in (0, 1].
function isValidThreshold(v) {
  return typeof v === 'number' && Number.isFinite(v) && v > 0 && v <= 1;
}

// Resolve a raw thresholds-shaped object to a guaranteed-sane pair: each key
// falls back to its default when absent/invalid, and a contradictory pair
// (medium ≥ high, which would make the 'medium' band unreachable) falls back
// to the defaults wholesale. User config is a trust boundary — this never
// throws and never returns an unusable pair.
function sanitizeThresholds(raw) {
  const r = raw !== null && typeof raw === 'object' ? raw : {};
  const highThreshold = isValidThreshold(r.highThreshold) ? r.highThreshold : HIGH_THRESHOLD;
  const mediumThreshold = isValidThreshold(r.mediumThreshold) ? r.mediumThreshold : MEDIUM_THRESHOLD;
  if (mediumThreshold >= highThreshold) return { ...DEFAULT_THRESHOLDS };
  return { highThreshold, mediumThreshold };
}

/**
 * Read the confidence thresholds from the user's plugin config, falling back
 * to the conservative defaults. The config file is the plugin's config.json
 * (docs/config-schema.md), keys `classification.highThreshold` and
 * `classification.mediumThreshold` — so any user can override the policy in
 * their own config instance without touching repo files.
 *
 * Resolution order for the file path (the same seam bin/config.sh honours):
 * `options.configFile` → env `YNAB_CONFIG_FILE` → the canonical plugin-data
 * path. A missing/unreadable/malformed file, an absent classification block,
 * or invalid values all degrade to the defaults — never a throw.
 *
 * @param {object} [options]
 * @param {string} [options.configFile] explicit config.json path (test seam).
 * @param {object} [env] environment, defaults to process.env (test seam).
 * @returns {{ highThreshold: number, mediumThreshold: number }} sane thresholds.
 */
export function loadThresholds(options = {}, env = process.env) {
  const configFile = options.configFile
    ?? env.YNAB_CONFIG_FILE
    ?? join(homedir(), DATA_DIR_REL, CONFIG_FILENAME);
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(configFile, 'utf8'));
  } catch {
    return { ...DEFAULT_THRESHOLDS }; // no config (or unreadable) → defaults
  }
  const classification = parsed !== null && typeof parsed === 'object' ? parsed.classification : null;
  return sanitizeThresholds(classification);
}

/**
 * Assign the routing band for a classifier confidence score. PURE.
 *
 * `confidence ≥ highThreshold → 'high'`;
 * `mediumThreshold ≤ confidence < highThreshold → 'medium'`;
 * `0 < confidence < mediumThreshold → 'low'`;
 * `confidence === 0` (the unclassified sentinel) — or any non-finite /
 * non-numeric / non-positive value — `→ 'unclassified'`.
 *
 * @param {number} confidence classifier confidence in [0, 1].
 * @param {{ highThreshold?: number, mediumThreshold?: number }} [thresholds]
 *   from loadThresholds(); invalid/contradictory values fall back to defaults.
 * @returns {'high'|'medium'|'low'|'unclassified'} the routing band.
 */
export function assignBand(confidence, thresholds = DEFAULT_THRESHOLDS) {
  const t = sanitizeThresholds(thresholds);
  if (typeof confidence !== 'number' || !Number.isFinite(confidence) || confidence <= 0) {
    return UNCLASSIFIED;
  }
  if (confidence >= t.highThreshold) return HIGH;
  if (confidence >= t.mediumThreshold) return MEDIUM;
  return LOW;
}
