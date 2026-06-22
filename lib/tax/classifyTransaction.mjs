// lib/tax/classifyTransaction.mjs — the workbench-ynab payee/category → tax-line
// mapping engine (issue #23, M3-4).
//
// WHAT THIS IS
//   The data-driven, user-editable classifier that turns an already-fetched
//   YNAB transaction (payee, category, category-group, account, amount) into a
//   suggested tax line from the bundled catalog (assets/tax/us-tax-lines.json,
//   #21), with a confidence and a human-readable reason. It replaces the
//   prototype's inline prose heuristics (SKILL.md) with an ordered ruleset:
//   bundled generic US defaults (assets/tax/mapping-rules.json) overlaid by the
//   user's own rules, evaluated by ascending priority.
//
// WHO CALLS THIS — AND THE YNAB NAMESPACING REMINDER
//   Plugin SKILLS (the M2 review flow), never the vendored YNAB MCP. classify()
//   takes transaction objects that have ALREADY been fetched; the caller fetches
//   them with the vendored MCP tools namespaced `mcp__plugin_workbench-ynab_ynab__*`
//   (e.g. `ynab_list_transactions`, `ynab_list_payees`) — NOT `mcp__ynab__*`.
//   This engine is deliberately MCP-agnostic: it reads plain objects and never
//   touches the wire.
//
// PURITY (issue #23 AC)
//   classify() is PURE: given the same transaction + profile (+ options) it
//   returns the same result, with no network calls, no MCP calls, no file I/O,
//   and no side effects. The ONLY file read in this module is the one-time,
//   import-time load of the bundled default ruleset into the frozen DEFAULT_RULES
//   constant below — analogous to importing a JSON asset, and outside any
//   classify() call. Tests that need zero-I/O purity inject `options.rules`.
//
// MONEY UNITS
//   YNAB transaction amounts are MILLIUNITS (1000 milliunits = $1). Every amount
//   comparison here (amountSign, amountThresholdDollars) is done in DOLLARS: the
//   engine divides the milliunit amount by 1000 first. See assets/tax/README.md
//   and docs/mapping-engine.md.
//
// EVALUATION MODEL (see docs/mapping-engine.md for the full contract)
//   1. Effective ruleset = bundled defaults overlaid by the user's rules. A user
//      rule REPLACES a bundled rule with the same id (disable / re-prioritize /
//      patch); a new id is appended. Disabled rules (enabled:false) drop out.
//   2. Rules are sorted ASCENDING by priority; the first matching rule wins.
//      Ties break by source (user before default), then match-type strength
//      (categoryName > categoryGroup ≈ businessSignal > accountName >
//      payeeKeywords > amount), then declaration order (stable).
//   3. A rule matches when EVERY criterion in its match object matches (AND).
//   4. No match (or best confidence < options.minConfidence) → the explicit
//      UNCLASSIFIED sentinel, never a wrong guess.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
// Bundled defaults ship in the repo (lib/tax → ../../assets/tax), so they travel
// with the plugin and survive updates — the same anchoring loadProfile.mjs uses.
const DEFAULT_RULES_PATH = join(HERE, '..', '..', 'assets', 'tax', 'mapping-rules.json');

// The explicit "we could not classify this" result. Never a guess: taxLineId is
// the reserved sentinel and confidence is 0 (issue #23 AC).
export const UNCLASSIFIED = Object.freeze({
  taxLineId: 'unclassified',
  confidence: 0,
  matchedRuleId: null,
  reason: 'No mapping rule matched this transaction with sufficient confidence.',
});

// Sentinel businessEntityId in a bundled rule: "resolve the owning entity from
// the profile at classify time" (keeps owner-specific ids out of the defaults).
const PROFILE_ENTITY = '$profile';

function deepFreeze(v) {
  if (v !== null && typeof v === 'object') {
    for (const k of Object.keys(v)) deepFreeze(v[k]);
    Object.freeze(v);
  }
  return v;
}

// One-time, import-time load of the bundled default ruleset. A missing/corrupt
// bundle is a PACKAGING bug, not a user error, so fail loud rather than classify
// against nothing. This read is outside classify() — classify() stays pure.
function readDefaultRules() {
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(DEFAULT_RULES_PATH, 'utf8'));
  } catch (err) {
    throw new Error(`tax classifier: cannot read bundled mapping rules at ${DEFAULT_RULES_PATH}: ${err.message}`);
  }
  return deepFreeze(Array.isArray(parsed.rules) ? parsed.rules : []);
}

export const DEFAULT_RULES = readDefaultRules();

// --- Transaction normalization ---------------------------------------------

// Read a YNAB transaction tolerantly: accept both YNAB-native snake_case fields
// and normalized camelCase, so callers can pass raw MCP objects or their own
// shape. Unknown/absent fields become null (a null haystack never matches).
function normalizeTransaction(tx) {
  const t = tx && typeof tx === 'object' ? tx : {};
  const amount = typeof t.amount === 'number' ? t.amount
    : typeof t.amount_milliunits === 'number' ? t.amount_milliunits
      : null;
  return {
    payee: t.payee_name ?? t.payeeName ?? t.payee ?? null,
    categoryName: t.category_name ?? t.categoryName ?? null,
    categoryGroup: t.category_group_name ?? t.categoryGroupName ?? t.categoryGroup ?? null,
    accountName: t.account_name ?? t.accountName ?? null,
    // DOLLARS, converted from YNAB milliunits. null when the transaction carries
    // no numeric amount (amount criteria then never match).
    amountDollars: amount === null ? null : amount / 1000,
  };
}

// --- Keyword matching (case-insensitive substring OR regex) ----------------

// A keyword wrapped in slashes ("/aws|gcp/") is a regex (the i flag is always
// added); anything else is a case-insensitive substring. Returns the keyword
// that matched (for the reason template) or null. A malformed user regex is a
// trust-boundary input: it is swallowed to a non-match rather than throwing and
// taking down the classify() call.
function matchKeyword(keyword, haystack) {
  if (typeof keyword !== 'string' || typeof haystack !== 'string') return false;
  const re = /^\/(.+)\/([a-z]*)$/.exec(keyword);
  if (re) {
    try {
      const flags = re[2].includes('i') ? re[2] : `${re[2]}i`;
      return new RegExp(re[1], flags).test(haystack);
    } catch {
      return false; // invalid regex in a (user) rule → no match, never a crash
    }
  }
  return haystack.toLowerCase().includes(keyword.toLowerCase());
}

function firstMatchingKeyword(keywords, haystack) {
  if (!Array.isArray(keywords)) return null;
  for (const k of keywords) if (matchKeyword(k, haystack)) return k;
  return null;
}

function eqCaseInsensitive(a, b) {
  return typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase();
}

// --- Business structural signal --------------------------------------------

// Resolve which profile business entity (if any) "owns" this transaction: the
// first entity whose declared business category-groups or accounts contain the
// transaction's category-group / account (case-insensitive). The declared lists
// live on the OPEN scheduleLineMap (shape owned by this issue): user-supplied
// arrays scheduleLineMap.categoryGroups / scheduleLineMap.accounts. Returns the
// entity id, or null. No real entity name ever appears in the bundled rules —
// only this profile-derived lookup.
function resolveBusinessEntity(tx, businessEntities) {
  for (const entity of businessEntities) {
    const map = entity && typeof entity.scheduleLineMap === 'object' && entity.scheduleLineMap !== null
      ? entity.scheduleLineMap
      : {};
    const groups = Array.isArray(map.categoryGroups) ? map.categoryGroups : [];
    const accounts = Array.isArray(map.accounts) ? map.accounts : [];
    const inGroup = tx.categoryGroup != null && groups.some((g) => eqCaseInsensitive(g, tx.categoryGroup));
    const inAccount = tx.accountName != null && accounts.some((a) => eqCaseInsensitive(a, tx.accountName));
    if (inGroup || inAccount) return entity.id ?? null;
  }
  return null;
}

// --- Single-rule matching ---------------------------------------------------

// Match-type strength (LOWER = stronger), used only for tie-breaking among
// equal-priority, equal-source rules. Mirrors the documented precedence:
// categoryName > categoryGroup ≈ businessSignal > accountName > payeeKeywords >
// amount criteria.
const STRENGTH = { categoryName: 0, categoryGroup: 1, businessSignal: 1, accountName: 2, payeeKeywords: 3, amountSign: 4, amountThresholdDollars: 4 };

function ruleStrength(match) {
  let best = 99;
  for (const key of Object.keys(match || {})) {
    if (key in STRENGTH && STRENGTH[key] < best) best = STRENGTH[key];
  }
  return best;
}

// Evaluate one rule against a normalized transaction + business context. Returns
// { matchedKeyword } on a match, or null. EVERY present criterion must match
// (AND); the criteria are checked in documented precedence order so the strongest
// signal is decided first.
function matchRule(rule, tx, businessEntityId) {
  const m = rule && rule.match;
  if (!m || typeof m !== 'object') return null;
  let matchedKeyword = null;

  if ('categoryName' in m && !eqCaseInsensitive(m.categoryName, tx.categoryName)) return null;
  if ('categoryGroup' in m && !eqCaseInsensitive(m.categoryGroup, tx.categoryGroup)) return null;
  if (m.businessSignal === true && businessEntityId == null) return null;
  if ('accountName' in m && !eqCaseInsensitive(m.accountName, tx.accountName)) return null;

  if ('payeeKeywords' in m) {
    matchedKeyword = firstMatchingKeyword(m.payeeKeywords, tx.payee);
    if (matchedKeyword === null) return null;
  }

  if ('amountSign' in m) {
    if (tx.amountDollars === null || tx.amountDollars === 0) return null;
    const sign = tx.amountDollars < 0 ? 'outflow' : 'inflow';
    if (sign !== m.amountSign) return null;
  }
  if ('amountThresholdDollars' in m) {
    if (tx.amountDollars === null || Math.abs(tx.amountDollars) < m.amountThresholdDollars) return null;
  }

  return { matchedKeyword };
}

// --- Ruleset assembly (defaults + user overlay) ----------------------------

function isEnabled(rule) {
  return rule && rule.enabled !== false;
}

// Overlay user rules onto base rules BY ID (a user rule replaces the same-id
// base rule wholesale; a new id is appended), then drop disabled rules. Tags
// each surviving rule with its source for the tie-break. Pure: clones inputs,
// mutates nothing the caller owns.
function overlayRules(baseRules, userRules) {
  const order = [];
  const byId = new Map();
  const add = (rule, source) => {
    if (!rule || typeof rule.id !== 'string') return;
    const tagged = { rule, source };
    if (byId.has(rule.id)) {
      byId.set(rule.id, tagged); // user replaces same-id default wholesale
    } else {
      byId.set(rule.id, tagged);
      order.push(rule.id);
    }
  };
  for (const r of Array.isArray(baseRules) ? baseRules : []) add(r, 'default');
  for (const r of Array.isArray(userRules) ? userRules : []) add(r, 'user');
  return order.map((id) => byId.get(id)).filter((t) => isEnabled(t.rule));
}

const SOURCE_RANK = { user: 0, default: 1 };

// Sort the overlaid rules into evaluation order (first = wins): priority asc →
// source (user first) → match-type strength → stable declaration index.
function sortRules(tagged) {
  return tagged
    .map((t, i) => ({ ...t, i, strength: ruleStrength(t.rule.match) }))
    .sort((a, b) => {
      const pa = Number.isFinite(a.rule.priority) ? a.rule.priority : Number.POSITIVE_INFINITY;
      const pb = Number.isFinite(b.rule.priority) ? b.rule.priority : Number.POSITIVE_INFINITY;
      if (pa !== pb) return pa - pb;
      if (SOURCE_RANK[a.source] !== SOURCE_RANK[b.source]) return SOURCE_RANK[a.source] - SOURCE_RANK[b.source];
      if (a.strength !== b.strength) return a.strength - b.strength;
      return a.i - b.i;
    });
}

/**
 * Build the effective, evaluation-ordered ruleset for a profile. Exported for
 * direct unit testing of the overlay + ordering contract. Pure.
 *
 * @param {object|null} profile resolved tax profile (loadProfile().profile).
 * @param {object} [options]
 * @param {Array}  [options.rules]     base ruleset, defaults to the bundled DEFAULT_RULES.
 * @param {Array}  [options.userRules] user overlay, defaults to profile.mappingRules.
 * @returns {Array<{rule:object, source:'user'|'default'}>} ordered rules.
 */
export function buildRuleset(profile, options = {}) {
  const base = options.rules ?? DEFAULT_RULES;
  const userRules = options.userRules ?? (profile && Array.isArray(profile.mappingRules) ? profile.mappingRules : []);
  return sortRules(overlayRules(base, userRules)).map(({ rule, source }) => ({ rule, source }));
}

// --- Reason template --------------------------------------------------------

function renderReason(template, vars) {
  if (typeof template !== 'string') return '';
  return template.replace(/\{(\w+)\}/g, (whole, key) => (key in vars && vars[key] != null ? String(vars[key]) : whole));
}

// --- Public classifier ------------------------------------------------------

/**
 * Classify an already-fetched YNAB transaction to a suggested tax line.
 *
 * The `transaction` is a plain object already fetched by the caller via the
 * vendored MCP tools namespaced `mcp__plugin_workbench-ynab_ynab__*` (e.g.
 * `ynab_list_transactions`) — NOT `mcp__ynab__*`. This function never fetches;
 * it reads these fields (YNAB snake_case or camelCase both accepted): payee_name,
 * category_name, category_group_name, account_name, and amount (YNAB MILLIUNITS,
 * converted to dollars internally).
 *
 * PURE: no network, no MCP, no file I/O, no side effects.
 *
 * @param {object}      transaction already-fetched YNAB transaction object.
 * @param {object|null} profile     resolved tax profile (loadProfile().profile);
 *   supplies businessEntities (for Schedule C scoping) and the user rule overlay
 *   at profile.mappingRules.
 * @param {object} [options]
 * @param {number} [options.minConfidence=0] return UNCLASSIFIED when the best
 *   match's confidence is below this — lets the review skill raise the bar for
 *   auto-suggestion versus human approval.
 * @param {Array}  [options.rules]     base ruleset override (default: bundled DEFAULT_RULES).
 * @param {Array}  [options.userRules] user overlay override (default: profile.mappingRules).
 * @returns {{ taxLineId:string, businessEntityId?:string, confidence:number,
 *   matchedRuleId:string|null, reason:string }} the highest-priority match, or
 *   the UNCLASSIFIED sentinel when nothing matches.
 */
export function classify(transaction, profile, options = {}) {
  const tx = normalizeTransaction(transaction);
  const businessEntities = profile && Array.isArray(profile.businessEntities) ? profile.businessEntities : [];
  const ownerEntityId = resolveBusinessEntity(tx, businessEntities);
  const minConfidence = typeof options.minConfidence === 'number' ? options.minConfidence : 0;

  for (const { rule } of buildRuleset(profile, options)) {
    const hit = matchRule(rule, tx, ownerEntityId);
    if (!hit) continue;

    const confidence = typeof rule.confidence === 'number' ? rule.confidence : 0.5;
    if (confidence < minConfidence) return { ...UNCLASSIFIED };

    // Resolve a "$profile" businessEntityId: the structurally-owning entity when
    // known, else the sole business entity (unambiguous), else leave it unset.
    let businessEntityId = rule.businessEntityId;
    if (businessEntityId === PROFILE_ENTITY) {
      businessEntityId = ownerEntityId
        ?? (businessEntities.length === 1 ? businessEntities[0].id : undefined);
    }

    const reason = renderReason(rule.reason, {
      payee: tx.payee, categoryName: tx.categoryName, categoryGroup: tx.categoryGroup,
      accountName: tx.accountName, taxLineId: rule.taxLineId, businessEntityId,
      matchedKeyword: hit.matchedKeyword,
    });

    const result = { taxLineId: rule.taxLineId, confidence, matchedRuleId: rule.id, reason };
    if (businessEntityId !== undefined) result.businessEntityId = businessEntityId;
    return result;
  }

  return { ...UNCLASSIFIED };
}

export default classify;
