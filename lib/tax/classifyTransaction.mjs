// lib/tax/classifyTransaction.mjs — the workbench-ynab payee/category → tax-line
// mapping engine (issue #23, M3-4).
//
// WHAT THIS IS
//   The data-driven, user-editable classifier that turns an already-fetched
//   YNAB transaction (payee, category, category-group, account, amount) into a
//   suggested tax line from the bundled catalog (assets/tax/us-tax-lines.json,
//   #21), with a confidence, a routing band (issue #19, lib/tax/confidence.mjs),
//   and a human-readable reason. It replaces the
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

import {
  assignBand,
  DEFAULT_THRESHOLDS,
  UNCLASSIFIED as UNCLASSIFIED_BAND,
} from './confidence.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
// Bundled defaults ship in the repo (lib/tax → ../../assets/tax), so they travel
// with the plugin and survive updates — the same anchoring loadProfile.mjs uses.
const DEFAULT_RULES_PATH = join(HERE, '..', '..', 'assets', 'tax', 'mapping-rules.json');

// The explicit "we could not classify this" result. Never a guess: taxLineId is
// the reserved sentinel, confidence is 0, and the routing band is 'unclassified'
// (issue #23 AC; band per issue #19).
export const UNCLASSIFIED = Object.freeze({
  taxLineId: 'unclassified',
  confidence: 0,
  band: UNCLASSIFIED_BAND,
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
  const categoryName = t.category_name ?? t.categoryName ?? null;
  const subtransactions = t.subtransactions ?? t.subTransactions;
  const transferAccountId = t.transfer_account_id ?? t.transferAccountId ?? null;
  return {
    payee: t.payee_name ?? t.payeeName ?? t.payee ?? null,
    categoryName,
    categoryGroup: t.category_group_name ?? t.categoryGroupName ?? t.categoryGroup ?? null,
    accountName: t.account_name ?? t.accountName ?? null,
    // DOLLARS, converted from YNAB milliunits. null when the transaction carries
    // no numeric amount (amount criteria then never match).
    amountDollars: amount === null ? null : amount / 1000,
    // Ambiguous by construction (GAP-19 / issue #19): a split (non-empty
    // subtransactions, or YNAB's literal 'Split' category on list endpoints)
    // or a transfer leg (transfer_account_id set) is ALWAYS routed to the
    // human-only band, regardless of any computed confidence.
    humanOnly: (Array.isArray(subtransactions) && subtransactions.length > 0)
      || eqCaseInsensitive(categoryName, 'Split')
      || transferAccountId !== null,
  };
}

// --- Keyword matching (case-insensitive substring OR regex) ----------------

// ReDoS bounds for the regex keyword path (issue #170). Generous for real
// rules: YNAB payee/category/account names are well under these, and a pattern
// anywhere near 256 chars is not a payee keyword.
const MAX_REGEX_PATTERN_LENGTH = 256;
const MAX_REGEX_HAYSTACK_LENGTH = 1024;

// --- Atom match-set approximation (for the sequential-quantifier check) -----
//
// Each regex atom gets an approximate set of characters it can match, folded
// to lowercase because matchKeyword always adds the `i` flag. `ANY` (null)
// means "could match anything" — the conservative direction: where an atom's
// alphabet can't be known statically (dot, negated classes, hex/unicode
// escapes, groups) we assume it overlaps everything, preferring a false
// rejection (that keyword degrades to a non-match) over a missed hang.

const ANY = null;
const DIGIT_CHARS = [...'0123456789'];
const WORD_CHARS = [...'abcdefghijklmnopqrstuvwxyz0123456789_'];
const SPACE_CHARS = [...' \t\n\r\f\v', '\u00a0'];

// Zero-width atoms (^ $ \b \B) carry an EMPTY set: they consume nothing, so
// they can never make two neighbouring repetition runs ambiguous.
function setsOverlap(a, b) {
  if (a !== ANY && a.size === 0) return false;
  if (b !== ANY && b.size === 0) return false;
  if (a === ANY || b === ANY) return true;
  const [small, big] = a.size <= b.size ? [a, b] : [b, a];
  for (const ch of small) if (big.has(ch)) return true;
  return false;
}

// Resolve one escape (the char after '\') to its atom set. Backreferences
// never reach here — the scanner rejects them outright first.
function escapeSet(e) {
  switch (e) {
    case undefined: return new Set(); // trailing '\' — new RegExp() rejects it later
    case 'd': return new Set(DIGIT_CHARS);
    case 'w': return new Set(WORD_CHARS);
    case 's': return new Set(SPACE_CHARS);
    case 'b': case 'B': return new Set(); // zero-width assertion
    case 'n': return new Set(['\n']);
    case 't': return new Set(['\t']);
    case 'r': return new Set(['\r']);
    case 'f': return new Set(['\f']);
    case 'v': return new Set(['\v']);
    case '0': return new Set(['\0']);
    // Negated classes and undecoded hex/unicode/property escapes: unknown
    // alphabet → conservative ANY.
    case 'D': case 'W': case 'S': case 'x': case 'u': case 'p': case 'P': return ANY;
    default: return new Set([e.toLowerCase()]);
  }
}

// Approximate a character class's match set. Returns { set, end } with `end`
// on the closing ']' (or past the source's end when unterminated — new
// RegExp() rejects that later). Negated classes and very wide ranges are ANY.
const MAX_RANGE_SPAN = 64;

function classSet(source, start) {
  let i = start + 1;
  if (source[i] === '^') {
    // Negated class — unknown alphabet. Still scan to the closing ']' so the
    // class body's literal `(|*+?{` chars can't miscount as syntax.
    i += 1;
    while (i < source.length && source[i] !== ']') i += source[i] === '\\' ? 2 : 1;
    return { set: ANY, end: i };
  }
  let set = new Set();
  while (i < source.length && source[i] !== ']') {
    if (source[i] === '\\') {
      const s = escapeSet(source[i + 1]);
      if (s === ANY) set = ANY;
      else if (set !== ANY) for (const ch of s) set.add(ch);
      i += 2;
    } else if (source[i + 1] === '-' && source[i + 2] !== undefined
      && source[i + 2] !== ']' && source[i + 2] !== '\\') {
      const lo = source.charCodeAt(i);
      const hi = source.charCodeAt(i + 2);
      if (hi < lo || hi - lo > MAX_RANGE_SPAN) set = ANY; // wide/invalid range
      else if (set !== ANY) {
        for (let c = lo; c <= hi; c += 1) set.add(String.fromCharCode(c).toLowerCase());
      }
      i += 3;
    } else {
      if (set !== ANY) set.add(source[i].toLowerCase());
      i += 1;
    }
  }
  return { set, end: i };
}

// Is this quantifier FLEXIBLE — able to match a varying number of repetitions?
// * + ? {n,} {n,m} (m>n) are; the exact {n} / {n,n} are not (no ambiguity).
function isFlexibleQuantifier(q) {
  if (q === '*' || q === '+' || q === '?') return true;
  const m = /^\{(\d+)(?:,(\d*))?\}$/.exec(q);
  if (!m || m[2] === undefined) return false; // {n} — exact
  return m[2] === '' || Number(m[2]) > Number(m[1]);
}

// Deterministic, dependency-free scan of a regex source for the constructs
// behind catastrophic backtracking (issue #170):
//   1. a quantified group whose body itself contains a quantifier — the
//      star-height > 1 shapes like (a+)+ or ((a*)b)* — exponential;
//   2. alternation anywhere inside a quantified group — overlap shapes like
//      (a|aa)+ — exponential, and invisible to a pure star-height check;
//   3. backreferences (\1–\9, \k<name>) — matching with backreferences is
//      super-polynomial in general;
//   4. a run of two or more FLEXIBLE quantifiers over overlapping alphabets in
//      one concatenation — the sibling-quantifier / ambiguous-adjacency family
//      (a*a*…, .*.*…, .*x.*, a+a+…, and the grouped (a+)(a+)) — whose cost
//      grows a polynomial degree per atom, effectively unbounded within the
//      length caps (surfaced reviewing PR #201). Non-overlapping runs (a+b+)
//      stay allowed: the repetition boundary there is unambiguous and linear.
// Escapes and character classes are parsed so their literal `(|*+?{` chars
// can't miscount. Conservative by design: a false positive (e.g. the pointless
// but safe `(aws|gcp)+`, or `\S+\s+` whose ANY-approximated alphabets only
// seem to overlap) just means that keyword never matches — the same
// degrade-to-non-match contract as a malformed regex — while a false negative
// would be a hang.
function isHighRiskRegexSource(source) {
  const newFrame = () => ({
    quantified: false, // any quantifier seen in this frame (nesting check)
    alternated: false, // any top-of-frame '|' seen (overlap-under-quantifier check)
    hasFlexible: false, // any flexible quantifier applied in this frame
    quantAtoms: [], // match sets of this branch's flexibly-quantified atoms
    union: new Set(), // approximate alphabet of everything in this frame
    unionAny: false,
    lastAtom: undefined, // match set of the most recent atom (quantifier target)
  });
  const frames = [newFrame()];
  let afterQuantifier = false; // a following '?' is a lazy modifier, not a quantifier

  // Apply a flexible quantifier to an atom: a second flexible quantifier over
  // an overlapping alphabet in the same concatenation run is shape 4 → reject.
  const applyFlexible = (frame, atom) => {
    if (atom === undefined) return false; // no target (invalid regex) — compile decides
    for (const prev of frame.quantAtoms) if (setsOverlap(prev, atom)) return true;
    frame.quantAtoms.push(atom);
    frame.hasFlexible = true;
    return false;
  };
  const mergeUnion = (frame, set) => {
    if (set === ANY) frame.unionAny = true;
    else for (const ch of set) frame.union.add(ch);
  };

  for (let i = 0; i < source.length; i += 1) {
    const c = source[i];
    const frame = frames[frames.length - 1];
    if (c === '\\') {
      if (/[1-9k]/.test(source[i + 1] ?? '')) return true; // backreference
      frame.lastAtom = escapeSet(source[i + 1]);
      mergeUnion(frame, frame.lastAtom);
      i += 1;
      afterQuantifier = false;
    } else if (c === '[') {
      const { set, end } = classSet(source, i);
      frame.lastAtom = set;
      mergeUnion(frame, set);
      i = end;
      afterQuantifier = false;
    } else if (c === '.') {
      frame.lastAtom = ANY;
      frame.unionAny = true;
      afterQuantifier = false;
    } else if (c === '(') {
      frames.push(newFrame());
      if (source[i + 1] === '?') { // (?: (?= (?! (?<name> (?<= (?<! — prefix, not atoms
        i += 1;
        const n = source[i + 1];
        if (n === ':' || n === '=' || n === '!') i += 1;
        else if (n === '<') {
          i += 1;
          if (source[i + 1] === '=' || source[i + 1] === '!') i += 1;
          else while (i + 1 < source.length && source[i] !== '>') i += 1;
        }
      }
      afterQuantifier = false;
    } else if (c === ')') {
      if (frames.length === 1) { afterQuantifier = false; continue; } // unbalanced — new RegExp() rejects it later
      const group = frames.pop();
      const parent = frames[frames.length - 1];
      const q = /^(?:[*+?]|\{\d+(?:,\d*)?\})/.exec(source.slice(i + 1));
      if (q && (group.quantified || group.alternated)) return true; // shapes 1–2
      parent.quantified ||= group.quantified || q !== null;
      parent.alternated ||= group.alternated;
      const groupSet = group.unionAny ? ANY : group.union;
      mergeUnion(parent, groupSet);
      // A flexibly-quantified group — or a group carrying its own flexible
      // run, like the (a+) in (a+)(a+) — joins the parent's concatenation run
      // as one atom whose alphabet is the group's whole approximate alphabet.
      if (((q && isFlexibleQuantifier(q[0])) || group.hasFlexible)
        && applyFlexible(parent, groupSet)) return true;
      if (q) {
        i += q[0].length; // consume the group's quantifier — handled above
        parent.lastAtom = undefined;
        afterQuantifier = true;
      } else {
        parent.lastAtom = groupSet;
        afterQuantifier = false;
      }
    } else if (c === '|') {
      frame.alternated = true;
      frame.quantAtoms = []; // concatenation runs don't cross alternation branches
      frame.lastAtom = undefined;
      afterQuantifier = false;
    } else if (c === '*' || c === '+' || (c === '?' && !afterQuantifier)) {
      frame.quantified = true;
      if (applyFlexible(frame, frame.lastAtom)) return true;
      frame.lastAtom = undefined;
      afterQuantifier = true;
    } else if (c === '?') {
      afterQuantifier = false; // lazy modifier on the preceding quantifier (a*?)
    } else if (c === '{' && /^\{\d+(?:,\d*)?\}/.test(source.slice(i))) {
      const q = /^\{\d+(?:,\d*)?\}/.exec(source.slice(i))[0];
      frame.quantified = true; // interval quantifier {n} {n,} {n,m}
      if (isFlexibleQuantifier(q) && applyFlexible(frame, frame.lastAtom)) return true;
      frame.lastAtom = undefined;
      i += q.length - 1;
      afterQuantifier = true;
    } else if (c === '^' || c === '$') {
      frame.lastAtom = new Set(); // zero-width anchor
      afterQuantifier = false;
    } else {
      frame.lastAtom = new Set([c.toLowerCase()]);
      frame.union.add(c.toLowerCase());
      afterQuantifier = false;
    }
  }
  return false;
}

// A keyword wrapped in slashes ("/aws|gcp/") is a regex (the i flag is always
// added); anything else is a case-insensitive substring. Returns the keyword
// that matched (for the reason template) or null. A malformed user regex is a
// trust-boundary input: it is swallowed to a non-match rather than throwing and
// taking down the classify() call.
//
// ReDoS MITIGATION (issue #170) — approach and tradeoff. A rule's "/pattern/"
// and the transaction-derived haystack are both trust-boundary inputs, so the
// regex path bounds its worst-case backtracking cost BEFORE compiling:
//   - length caps on pattern and haystack (bounds the input a backtracking
//     engine can chew on);
//   - isHighRiskRegexSource() rejects the exponential-family shapes: nested
//     quantifiers, alternation under a quantifier, backreferences, and runs
//     of two or more flexible quantifiers over overlapping alphabets in one
//     concatenation (a*a*…, .*.*…, .*x.* — grouped or bare, at any depth).
// Rejected/over-long inputs degrade to a NON-MATCH — the exact contract a
// malformed regex already has — never a throw. This is heuristic + caps rather
// than a time-boxed match because classify() must stay PURE and deterministic
// (issue #23 AC): a wall-clock budget would make the same inputs classify
// differently under load, and a worker would be a side effect. Zero new
// dependencies per docs/testing.md. Residual risk: what the scanner admits
// backtracks at worst at a low fixed polynomial degree (a single flexible
// quantifier, or a non-overlapping run like a+b+), which the length caps DO
// keep small; where an atom's alphabet can't be known statically (dot, negated
// classes, hex/unicode escapes, groups) the scanner assumes overlap, trading
// false rejection for a guaranteed absence of hangs. The substring path is
// linear and stays uncapped.
function matchKeyword(keyword, haystack) {
  if (typeof keyword !== 'string' || typeof haystack !== 'string') return false;
  // Slash-wrapped detection is linear string work, not a detector regex: the
  // previous /^\/(.+)\/([a-z]*)$/ backtracked O(n²) on a long raw keyword
  // dense with '/' (PR #201 review follow-up). Flags admit no '/', so only
  // the LAST '/' can ever close the pattern — lastIndexOf is equivalent.
  if (keyword.length > 2 && keyword[0] === '/') {
    const close = keyword.lastIndexOf('/');
    const flags = keyword.slice(close + 1);
    if (close > 1 && /^[a-z]*$/.test(flags)) {
      const pattern = keyword.slice(1, close);
      if (pattern.length > MAX_REGEX_PATTERN_LENGTH
        || haystack.length > MAX_REGEX_HAYSTACK_LENGTH
        || isHighRiskRegexSource(pattern)) return false; // bounded → no match, never a crash
      try {
        return new RegExp(pattern, flags.includes('i') ? flags : `${flags}i`).test(haystack);
      } catch {
        return false; // invalid regex in a (user) rule → no match, never a crash
      }
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
 * Every result carries a routing `band` (issue #19, lib/tax/confidence.mjs):
 * 'high' | 'medium' | 'low' | 'unclassified', assigned from the confidence
 * against `options.thresholds`. Split transactions and transfer legs are
 * hard-coded to band 'unclassified' regardless of the computed confidence —
 * they are ambiguous by construction (GAP-19) and always route to a human.
 * Confidence governs proposal composition only; the human approval gate is
 * mandatory and independent of confidence (see docs/confidence-contract.md).
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
 * @param {{ highThreshold?:number, mediumThreshold?:number }} [options.thresholds]
 *   band thresholds from loadThresholds() (lib/tax/confidence.mjs); the caller
 *   resolves config once and passes them in, keeping classify() pure. Defaults
 *   to the conservative bundled defaults (0.85 / 0.60).
 * @returns {{ taxLineId:string, businessEntityId?:string, confidence:number,
 *   band:('high'|'medium'|'low'|'unclassified'), matchedRuleId:string|null,
 *   reason:string }} the highest-priority match, or the UNCLASSIFIED sentinel
 *   when nothing matches.
 */
export function classify(transaction, profile, options = {}) {
  const tx = normalizeTransaction(transaction);
  const businessEntities = profile && Array.isArray(profile.businessEntities) ? profile.businessEntities : [];
  const ownerEntityId = resolveBusinessEntity(tx, businessEntities);
  const minConfidence = typeof options.minConfidence === 'number' ? options.minConfidence : 0;
  const thresholds = options.thresholds ?? DEFAULT_THRESHOLDS;

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

    // The routing band (issue #19). Splits/transfer legs are hard-coded to
    // 'unclassified' — no exception path overrides this, whatever the score.
    const band = tx.humanOnly ? UNCLASSIFIED_BAND : assignBand(confidence, thresholds);

    const result = { taxLineId: rule.taxLineId, confidence, band, matchedRuleId: rule.id, reason };
    if (businessEntityId !== undefined) result.businessEntityId = businessEntityId;
    return result;
  }

  return { ...UNCLASSIFIED };
}

export default classify;
