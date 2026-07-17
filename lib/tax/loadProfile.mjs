// lib/tax/loadProfile.mjs — the workbench-ynab tax-profile loader (issue #22, M3-3).
//
// WHAT THIS IS
//   The single, trustworthy way to obtain the *effective* tax profile: the
//   bundled default US ruleset (assets/tax/us-tax-lines.json, #21) deep-merged
//   with the user's profile instance (~/.claude/plugins/data/
//   workbench-ynab-claude-workbench/tax-profile.json, #25) and any explicit
//   `overrides` layered on top. The merged, frozen object — plus a per-leaf
//   provenance map — is what the tax engine and the review skill consume.
//
//   See docs/tax-profile-loader.md for the full contract (precedence, path
//   resolution, accessors).
//
// WHO CALLS THIS
//   Plugin SKILLS (and the tax engine they invoke), never the vendored YNAB
//   MCP. This is pure local config resolution: no network, no YNAB calls.
//
// STDOUT / STDERR DISCIPLINE
//   This module emits NOTHING to stdout. It is pure library code that returns a
//   structured result; it never logs on the happy path. Errors are RETURNED as
//   data (or, for packaging invariants like a missing bundled ruleset, thrown —
//   Node prints uncaught throws to stderr). Keeping stdout clean means this is
//   safe even if it is ever invoked from a JSON-RPC / MCP path, where a single
//   stray stdout byte corrupts the handshake (see workbench-core/hooks/
//   mcp-memory.sh). Diagnostic output, if ever added, must go to stderr only.
//
// MONEY UNITS
//   Every dollar amount here is in DOLLARS, not YNAB milliunits (divide YNAB
//   milliunits by 1000 to get dollars). See assets/tax/README.md.
//
// VALIDATION — DEPENDENCY-FREE BY DESIGN
//   The user profile is validated against the canonical JSON Schema produced by
//   #20 (assets/tax/tax-profile.schema.json, draft 2020-12) BEFORE any merge.
//   Validation uses a compact, purpose-built JSON-Schema-subset validator built
//   on node: built-ins only — never an installed framework (no ajv). This keeps
//   the loader faithful to the plugin's "nothing to install" premise and the
//   recorded "no node_modules, ever" test-harness decision (docs/testing.md):
//   the runtime path the skills use must not assume any npm package is present.

import { readFileSync, existsSync, realpathSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, join, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

// --- Paths ------------------------------------------------------------------

const HERE = dirname(fileURLToPath(import.meta.url));
// Bundled assets live in the repo (relative to repo root, NOT the data dir), so
// they ship with the plugin and survive plugin updates. lib/tax → ../../assets/tax.
const ASSETS_TAX = join(HERE, '..', '..', 'assets', 'tax');
const DEFAULT_DEFAULTS_PATH = join(ASSETS_TAX, 'us-tax-lines.json');
const DEFAULT_SCHEMA_PATH = join(ASSETS_TAX, 'tax-profile.schema.json');
// Out-of-repo data dir, mirroring workbench-core's convention. Overridable for
// the test harness via the YNAB_DATA_DIR / YNAB_TAX_PROFILE_FILE env seams,
// exactly as bin/config.sh honours YNAB_CONFIG_FILE.
const DATA_DIR_REL = join('.claude', 'plugins', 'data', 'workbench-ynab-claude-workbench');

// Provenance source tiers — the three layers, lowest precedence first.
export const SOURCES = Object.freeze({ DEFAULTS: 'defaults', USER: 'user', OVERRIDES: 'overrides' });

// --- Path containment (issue #169) -------------------------------------------
//
// loadProfile forwards caller-supplied paths (options.profilePath / dataDir /
// defaultsPath / schemaPath, or their env seams) into readFileSync. Unchecked,
// that is a latent arbitrary-file-read primitive if any of those values ever
// arrive from a less-trusted source. So before ANY read, the requested path is
// canonicalized (realpath — resolving `..` traversal and symlinks to the true
// target the kernel would open) and verified to fall inside an explicit
// allowlist of roots:
//
//   1. the resolved data dir — options.dataDir → env YNAB_DATA_DIR → the
//      canonical plugin-data dir. Naming a root is an embedding-level trust
//      decision (it is how the test harness points the loader at a mkdtemp
//      root), so an explicit dataDir joins the allowlist WITHOUT widening the
//      default no-options surface;
//   2. the bundled assets/tax/ directory (the defaults + schema live there).
//
// A path that resolves outside every root is refused with a structured
// `containment` failure — the file is never opened.
//
// RESIDUAL RACE (TOCTOU) — a known, accepted limitation. The guard canonicalizes
// the path, then the read reopens that same raw path (AC #2 prescribes exactly
// this check-then-open shape). A filesystem mutation *between* the check and the
// read — swapping a component for a symlink in the microseconds between them —
// could still redirect the read. Closing that fully needs an open-then-fstat /
// O_NOFOLLOW-style read, out of scope for the AC. It is not exploitable via the
// only caller (paths come from env/defaults, not an attacker who also controls
// the filesystem mid-call); documented here so a future reader knows the guard
// defends against malicious *paths*, not concurrent filesystem *mutation*.

// Canonicalize a path the way the kernel resolves it for open(2), so the
// containment verdict matches what readFileSync/existsSync will actually open.
//
// Uses realpathSync.NATIVE — the C realpath(3) that dereferences symlinks in
// true kernel order (symlink first, then `..`). The non-native realpathSync
// begins with path.resolve(p), collapsing `..` LEXICALLY before any symlink is
// walked, so `link/../x` (link → outside) resolves to the wrong file and the
// check disagrees with the read (issue #169's exact bypass). For a not-yet-
// existing target, walk up via dirname on the RAW path — never path.resolve,
// which would reintroduce the same lexical `..` collapse — realpath the deepest
// existing ancestor natively, and re-attach the untraversed suffix. Re-attaching
// with join is safe not because the suffix is special, but because every suffix
// component ENOENT'd: whatever verdict containment reaches, opening the raw path
// can only ENOENT too, so no bytes can leak through a fabricated suffix.
//
// Fails CLOSED: only a not-yet-existing target (ENOENT) is safely resolvable —
// a read of a missing path ENOENTs regardless, so no bytes leak. Any other
// realpath error (EACCES / ELOOP / ENOTDIR / …) means the true target is
// unknowable, so canonicalize returns null and the caller treats it as outside
// every root rather than fabricating an in-root path it never resolved.
function canonicalize(p) {
  try {
    return realpathSync.native(p);
  } catch (err) {
    if (err.code !== 'ENOENT') return null;
  }
  let prefix = p;
  let suffix = '';
  for (;;) {
    const parent = dirname(prefix);
    if (parent === prefix) return null; // reached the fs root unresolved — fail closed
    suffix = suffix ? join(basename(prefix), suffix) : basename(prefix);
    prefix = parent;
    try {
      return join(realpathSync.native(prefix), suffix);
    } catch (err) {
      if (err.code !== 'ENOENT') return null; // fail closed
      // ancestor missing too — keep walking up
    }
  }
}

function isWithin(root, p) {
  return p === root || p.startsWith(root + sep);
}

// Both spellings of the home directory — as reported by os.homedir() (raw) and
// as the kernel resolves it (canonical). When $HOME itself sits behind a symlink
// or macOS firmlink (homedir() !== realpath(homedir())), a caller-spelled path
// carries the RAW form while a canonicalized path carries the CANONICAL form —
// redaction must mask both, or the un-matched spelling ships the OS username.
// Longest form first so the tighter mask wins if one form contains the other.
// Computed once; empty only if home itself is unresolvable (redact then no-ops,
// same as before: there is no known home prefix to mask).
const HOME_FORMS = [...new Set([homedir(), canonicalize(homedir())])]
  .filter((h) => typeof h === 'string' && h.length > 1)
  .sort((a, b) => b.length - a.length);

// Redact every home-directory spelling to `~` in a string destined for a
// FAILURE envelope. Error text may cross an MCP/JSON-RPC boundary — the tax
// facade (lib/tax/index.mjs) re-throws error.message verbatim — so everything
// in the failure envelope passes through here: containment/io/parse messages
// (Node's own err.message never rides the envelope verbatim — describeError
// below reduces it to content-free facts first), the structured
// params, the echoed `sources`, and the packaging-invariant throws. Success-path
// `sources` stays raw by design: callers consume those real paths
// programmatically, and success values never ride an error across the boundary.
const redact = (s) => (typeof s !== 'string' ? s : HOME_FORMS.reduce((acc, h) => acc.split(h).join('~'), s));

// Reduce a caught read-or-parse error to CONTENT-FREE facts for the failure
// envelope (issue #207). V8's JSON.parse SyntaxError.message quotes a snippet
// of the offending file's raw bytes (`Unexpected token 'A', "AWS_SECRET"... is
// not valid JSON`) and Node's fs err.message embeds the raw path — neither may
// be echoed verbatim where error text can cross an MCP/JSON-RPC boundary.
// SyntaxErrors keep only the parse position, re-emitted from strictly-matched
// digits (never the matched text); fs errors keep only the errno code (strict
// uppercase shape); anything else degrades to a fixed word. Additive to
// redact() above, which still home-masks the paths the composed messages echo.
function describeError(err) {
  if (err instanceof SyntaxError) {
    const m = /at position (\d+)(?: \(line (\d+) column (\d+)\))?/.exec(err.message);
    if (!m) return 'parse error';
    return `parse error at position ${m[1]}${m[2] ? ` (line ${m[2]} column ${m[3]})` : ''}`;
  }
  return err && typeof err.code === 'string' && /^[A-Z][A-Z0-9_]*$/.test(err.code) ? err.code : 'unreadable';
}

// --- Small structural helpers ----------------------------------------------

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

// Keys that must never be copied, stamped, or merged from externally-sourced
// JSON. Writing to `__proto__` / `constructor` / `prototype` walks the prototype
// chain and can mutate the global Object.prototype of the whole Node process
// (prototype pollution). A JSON.parse'd `__proto__` survives as an OWN property,
// so a deep-merge that reads it via bracket access lands on Object.prototype.
// Every routine that copies keys out of untrusted input skips these outright;
// they are never legitimate tax-profile keys.
const DANGEROUS_KEYS = new Set(['__proto__', 'constructor', 'prototype']);
function isDangerousKey(k) {
  return DANGEROUS_KEYS.has(k);
}

// Defensive ceiling on structural nesting depth. The `overrides` layer is
// intentionally schema-open (`additionalProperties: true`), and `scheduleLineMap`
// is too, so the schema validator does NOT recurse into them — a pathologically
// deep value there would otherwise flow unchecked into the recursive
// merge/stamp/strip routines and overflow the call stack, escaping the loader as
// an uncaught RangeError instead of the structured failure the contract promises
// everywhere else (and taking down the consuming skill — or, on an MCP path, the
// JSON-RPC handshake). Real tax profiles are only a handful of levels deep, so
// this ceiling sits far above any legitimate input and far below the engine's
// actual stack limit. Crossing it throws a RangeError that loadProfile converts
// to a structured `depth` failure; direct callers of resolveProfile / deepMerge
// get the same clear RangeError instead of a cryptic stack overflow.
const MAX_DEPTH = 100;
function tooDeep(path) {
  return new RangeError(
    `tax profile nesting exceeds the maximum supported depth of ${MAX_DEPTH}${path ? ` at ${path}` : ''}`,
  );
}

// Pure-JSON deep clone — these inputs are always plain JSON (no functions,
// dates, or cycles), so this is faithful and dependency-free.
function deepClone(v) {
  return v === undefined ? undefined : JSON.parse(JSON.stringify(v));
}

function deepFreeze(v) {
  if (v !== null && typeof v === 'object') {
    for (const k of Object.keys(v)) deepFreeze(v[k]);
    Object.freeze(v);
  }
  return v;
}

function deepEqual(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

// Drop annotation-only keys ($comment, $schema, $id, …) so they never leak into
// the resolved profile or its provenance. None of the real data keys start "$".
function stripComments(v, depth = 0) {
  if (depth > MAX_DEPTH) throw tooDeep();
  if (Array.isArray(v)) return v.map((e) => stripComments(e, depth + 1));
  if (isPlainObject(v)) {
    const out = {};
    for (const k of Object.keys(v)) {
      if (k.startsWith('$') || isDangerousKey(k)) continue;
      out[k] = stripComments(v[k], depth + 1);
    }
    return out;
  }
  return v;
}

// An "array of entities" is a non-empty array whose every element is an object
// carrying a string `id` — the shape the merge keys on (AC: arrays of entities
// merge by id; all other arrays override wholesale).
function isEntityArray(v) {
  return (
    Array.isArray(v) &&
    v.length > 0 &&
    v.every((e) => isPlainObject(e) && typeof e.id === 'string')
  );
}

// --- JSON-Schema-subset validator (node: built-ins only) -------------------

function mkErr(path, keyword, message, params) {
  return { path: path || '/', keyword, message, params: params || {} };
}

function matchesType(type, data) {
  switch (type) {
    case 'object':
      return isPlainObject(data);
    case 'array':
      return Array.isArray(data);
    case 'string':
      return typeof data === 'string';
    case 'integer':
      return typeof data === 'number' && Number.isInteger(data);
    case 'number':
      return typeof data === 'number' && Number.isFinite(data);
    case 'boolean':
      return typeof data === 'boolean';
    case 'null':
      return data === null;
    default:
      return true;
  }
}

// Validate `data` against `schema` at JSON-Pointer `path`, collecting every
// violation into `errors` (allErrors-style). Supports exactly the keyword subset
// the tax-profile schema uses: type, required, properties, additionalProperties
// (false | subschema | true), propertyNames, enum, oneOf, items, minimum,
// maximum, minLength, minItems, pattern. Unknown/annotation keywords are ignored.
function validateNode(schema, data, path, errors) {
  if (schema === true || schema === undefined) return;
  if (schema === false) {
    errors.push(mkErr(path, 'false', 'no value is allowed here', {}));
    return;
  }

  if (Array.isArray(schema.oneOf)) {
    let passes = 0;
    for (const sub of schema.oneOf) {
      const subErrs = [];
      validateNode(sub, data, path, subErrs);
      if (subErrs.length === 0) passes += 1;
    }
    if (passes !== 1) {
      errors.push(
        mkErr(path, 'oneOf', `must match exactly one schema in oneOf (matched ${passes})`, { passes }),
      );
    }
  }

  if (schema.type !== undefined && !matchesType(schema.type, data)) {
    errors.push(mkErr(path, 'type', `must be ${schema.type}`, { type: schema.type }));
    return; // deeper keyword checks assume the type already holds
  }

  if (Array.isArray(schema.enum) && !schema.enum.some((e) => deepEqual(e, data))) {
    errors.push(
      mkErr(path, 'enum', 'must be equal to one of the allowed values', { allowedValues: schema.enum }),
    );
  }

  if (typeof data === 'number') {
    if (schema.minimum !== undefined && data < schema.minimum) {
      errors.push(mkErr(path, 'minimum', `must be >= ${schema.minimum}`, { limit: schema.minimum }));
    }
    if (schema.maximum !== undefined && data > schema.maximum) {
      errors.push(mkErr(path, 'maximum', `must be <= ${schema.maximum}`, { limit: schema.maximum }));
    }
  }

  if (typeof data === 'string') {
    if (schema.minLength !== undefined && data.length < schema.minLength) {
      errors.push(
        mkErr(path, 'minLength', `must be at least ${schema.minLength} character(s)`, { limit: schema.minLength }),
      );
    }
    if (typeof schema.pattern === 'string' && !new RegExp(schema.pattern).test(data)) {
      errors.push(mkErr(path, 'pattern', `must match pattern ${schema.pattern}`, { pattern: schema.pattern }));
    }
  }

  if (Array.isArray(data)) {
    if (schema.minItems !== undefined && data.length < schema.minItems) {
      errors.push(mkErr(path, 'minItems', `must have at least ${schema.minItems} item(s)`, { limit: schema.minItems }));
    }
    if (schema.items !== undefined) {
      data.forEach((item, i) => validateNode(schema.items, item, `${path}/${i}`, errors));
    }
  }

  if (isPlainObject(data)) {
    if (Array.isArray(schema.required)) {
      for (const key of schema.required) {
        if (!Object.prototype.hasOwnProperty.call(data, key)) {
          errors.push(mkErr(`${path}/${key}`, 'required', `must have required property '${key}'`, { missingProperty: key }));
        }
      }
    }

    if (schema.propertyNames !== undefined) {
      for (const key of Object.keys(data)) {
        const subErrs = [];
        validateNode(schema.propertyNames, key, `${path}/${key}`, subErrs);
        if (subErrs.length > 0) {
          // JSON-Schema convention: a propertyNames failure is reported at the
          // CONTAINER path (the offending property name is named in the message
          // + params), not at `${path}/${key}` — that points at a value position.
          errors.push(mkErr(path, 'propertyNames', `property name '${key}' is not allowed`, { propertyName: key }));
        }
      }
    }

    const props = schema.properties || {};
    for (const key of Object.keys(data)) {
      if (Object.prototype.hasOwnProperty.call(props, key)) {
        validateNode(props[key], data[key], `${path}/${key}`, errors);
      } else if (schema.additionalProperties === false) {
        errors.push(mkErr(`${path}/${key}`, 'additionalProperties', `must NOT have additional property '${key}'`, { additionalProperty: key }));
      } else if (isPlainObject(schema.additionalProperties)) {
        validateNode(schema.additionalProperties, data[key], `${path}/${key}`, errors);
      }
      // additionalProperties === true | undefined → any value allowed
    }
  }
}

/**
 * Validate a parsed instance against a JSON Schema (the supported subset).
 * @param {unknown} data   parsed instance to validate.
 * @param {object}  schema parsed JSON Schema.
 * @returns {{ valid: boolean, errors: Array<{path:string,keyword:string,message:string,params:object}> }}
 */
export function validateAgainstSchema(data, schema) {
  const errors = [];
  validateNode(schema, data, '', errors);
  return { valid: errors.length === 0, errors };
}

/**
 * Derive the schema used to type-check an `overrides` block from the main
 * tax-profile schema. The main schema deliberately leaves `overrides` open
 * (`additionalProperties: true`), so an override's leaf values are otherwise
 * UNCHECKED — a mistyped override (a string where a rate belongs) would flow
 * straight into the frozen profile and silently corrupt every downstream tax
 * number, exactly the failure the issue tells us to prevent. This builds a
 * "partial profile" schema that:
 *   - drops the root `required` and opens root `additionalProperties`, because
 *     an override is a partial that may also target ruleset-only keys (`lines`,
 *     `thresholds`, …) that aren't named profile properties;
 *   - requires ONLY `id` on a `businessEntities` item — the merge keys on `id`,
 *     so an id-less entity override would silently DROP every lower-tier entity;
 *     the remaining entity fields stay optional so an id-only patch is legal;
 *   - inherits every other typed constraint (type/enum/minimum/pattern/…)
 *     unchanged, so a type-incompatible override fails loud with its JSON path.
 * @param {object} mainSchema the parsed tax-profile JSON Schema.
 * @returns {object} a schema suitable for validating an `overrides` object.
 */
export function buildOverridesSchema(mainSchema) {
  const props = {};
  for (const [key, sub] of Object.entries(mainSchema.properties || {})) {
    if (key === 'overrides') continue;
    props[key] = sub;
  }
  if (props.businessEntities && isPlainObject(props.businessEntities.items)) {
    props.businessEntities = {
      ...props.businessEntities,
      // An EMPTY entity-array override (`businessEntities: []`) has no element to
      // carry an `id`, so it skips the by-id merge and wholesale-replaces the
      // array — silently dropping every lower-tier Schedule C entity. minItems:1
      // makes it fail loud at `/overrides/businessEntities` instead. A legitimate
      // "clear all entities via an override" is implausible (the user would
      // simply not declare them), and silently zeroing tax entities is
      // catastrophic, so the asymmetry favours rejecting the empty array.
      minItems: 1,
      items: { ...props.businessEntities.items, required: ['id'] },
    };
  }
  return { type: 'object', additionalProperties: true, properties: props };
}

// --- Provenance + deep merge ------------------------------------------------

// Child path key. Objects use dot notation (a.b); arrays of entities key by the
// entity id (a[biz-a]); other arrays key by index (a[0]).
function childKey(prefix, key) {
  return prefix ? `${prefix}.${key}` : key;
}
function indexKey(prefix, idx) {
  return `${prefix}[${idx}]`;
}

// Record the source tier of every leaf under `value`, keyed by its path. Empty
// containers are recorded as a single leaf so provenance is never silently
// missing for them.
function stampLeaves(value, path, tier, prov, depth = 0) {
  if (depth > MAX_DEPTH) throw tooDeep(path);
  if (isPlainObject(value)) {
    const keys = Object.keys(value).filter((k) => !k.startsWith('$') && !isDangerousKey(k));
    if (keys.length === 0) {
      prov[path] = tier;
      return;
    }
    for (const k of keys) stampLeaves(value[k], childKey(path, k), tier, prov, depth + 1);
  } else if (Array.isArray(value)) {
    if (value.length === 0) {
      prov[path] = tier;
      return;
    }
    const entity = isEntityArray(value);
    value.forEach((item, i) => stampLeaves(item, indexKey(path, entity ? item.id : i), tier, prov, depth + 1));
  } else {
    prov[path] = tier;
  }
}

// Drop any provenance entries at or under `path` (used before a wholesale
// override replaces a subtree, so stale leaf paths can't linger).
function clearProvUnder(prov, path) {
  for (const k of Object.keys(prov)) {
    if (k === path || k.startsWith(`${path}.`) || k.startsWith(`${path}[`)) delete prov[k];
  }
}

// Merge `layer` into `base` (mutating `base`), stamping touched leaves with
// `tier` in `prov`. Semantics (AC #5): objects merge recursively; arrays of
// entities merge by `id` (recursively merging matched entities, appending new
// ones); every other value — scalars and non-entity arrays — overrides wholesale.
function mergeLayer(base, layer, tier, prov, path, depth = 0) {
  if (depth > MAX_DEPTH) throw tooDeep(path);
  for (const key of Object.keys(layer)) {
    // Never copy a dangerous or annotation key out of externally-sourced JSON.
    // `__proto__` / `constructor` / `prototype` are prototype-pollution vectors;
    // `$`-prefixed keys ($comment/$schema/…) are annotation-only and would leak
    // into the frozen profile, which the resolved object's own schema forbids
    // (`additionalProperties: false`). The `overrides` layer is schema-open, so
    // this is the only place such keys are filtered for the user/overrides tiers
    // (defaults are stripped via stripComments).
    if (key.startsWith('$') || isDangerousKey(key)) continue;
    const p = childKey(path, key);
    const bv = base[key];
    const lv = layer[key];

    if (isPlainObject(bv) && isPlainObject(lv)) {
      mergeLayer(bv, lv, tier, prov, p, depth + 1);
    } else if (isEntityArray(bv) && isEntityArray(lv)) {
      const byId = new Map(bv.map((e) => [e.id, e]));
      for (const item of lv) {
        const existing = byId.get(item.id);
        const ip = indexKey(p, item.id);
        if (existing) {
          mergeLayer(existing, item, tier, prov, ip, depth + 1);
        } else {
          // stripComments (not deepClone): a newly-appended entity may carry
          // nested $/dangerous keys under its schema-open scheduleLineMap.
          const clone = stripComments(item, depth + 1);
          bv.push(clone);
          byId.set(item.id, clone);
          stampLeaves(clone, ip, tier, prov, depth + 1);
        }
      }
    } else if (!deepEqual(bv, lv)) {
      clearProvUnder(prov, p);
      // stripComments (not deepClone): a wholesale-replaced subtree from a
      // schema-open override key may contain nested $/dangerous keys that must
      // never reach the frozen profile.
      base[key] = stripComments(lv, depth + 1);
      stampLeaves(base[key], p, tier, prov, depth + 1);
    }
    // else: this layer restates the already-resolved value verbatim — it does
    // not change the result, so it does not claim provenance (the lower tier's
    // stamp stands). This is what keeps an entity's `id`, used only as the merge
    // key, from being mislabelled as the higher layer's contribution.
  }
}

/**
 * Resolve the effective profile from the bundled defaults and (optional) user
 * instance, producing the merged object plus a per-leaf provenance map. Pure:
 * no filesystem, no validation — feed it already-parsed objects.
 *
 * Precedence (lowest → highest): defaults → user profile → user `overrides`.
 *
 * @param {object}      defaultsRaw parsed bundled default ruleset (#21).
 * @param {object|null} userRaw     parsed user profile instance, or null for defaults-only.
 * @returns {{ profile: object, provenance: Record<string,string>, defaultsOnly: boolean }}
 */
export function resolveProfile(defaultsRaw, userRaw) {
  const defaults = stripComments(deepClone(defaultsRaw));
  const prov = {};
  const profile = deepClone(defaults);
  stampLeaves(defaults, '', SOURCES.DEFAULTS, prov);

  if (userRaw) {
    const user = deepClone(userRaw);
    const overrides = isPlainObject(user.overrides) ? user.overrides : null;
    delete user.overrides; // applied as its own top-precedence layer, not a profile field
    mergeLayer(profile, user, SOURCES.USER, prov, '');
    if (overrides) mergeLayer(profile, overrides, SOURCES.OVERRIDES, prov, '');
  }

  return { profile, provenance: prov, defaultsOnly: !userRaw };
}

/**
 * Plain two-layer deep merge with the loader's semantics (objects recurse,
 * entity arrays merge by id, everything else overrides). Exported for direct
 * unit testing of the merge contract. Does not mutate its arguments.
 */
export function deepMerge(base, layer) {
  const out = deepClone(base);
  mergeLayer(out, layer, SOURCES.OVERRIDES, {}, '');
  return out;
}

// --- Accessors --------------------------------------------------------------

// Bind the engine/skill-facing accessors to a resolved profile. Year and filing
// status default to the profile's own taxYear / filingStatus when omitted.
function makeAccessors(profile) {
  return {
    /** Standard deduction (dollars) for a year + filing status, or undefined. */
    getStandardDeduction(year, filingStatus) {
      const status = filingStatus ?? profile.filingStatus;
      const y = String(year ?? profile.taxYear);
      const byStatus = profile.standardDeductionByYear && profile.standardDeductionByYear[status];
      return byStatus ? byStatus[y] : undefined;
    },
    /** A tunable threshold/rate by name (e.g. 'seTaxRate'), or undefined. */
    getThreshold(name) {
      return profile.thresholds ? profile.thresholds[name] : undefined;
    },
    /** The resolved business entities (always an array, possibly empty). */
    getBusinessEntities() {
      return profile.businessEntities ?? [];
    },
    /** The scheduleLineMap for one entity by id, or undefined if no such entity. */
    getScheduleLineMap(entityId) {
      const entity = (profile.businessEntities ?? []).find((e) => e && e.id === entityId);
      return entity ? entity.scheduleLineMap : undefined;
    },
    /**
     * Quarterly estimated-tax due dates resolved to calendar dates for `year`
     * (defaults to the profile's taxYear). Q1–Q3 fall in the tax year; Q4 falls
     * in January of the FOLLOWING year (see the schema's format note). Weekend /
     * holiday shifting is the engine's responsibility, not this loader's.
     */
    getQuarterlyDueDates(year) {
      const taxYear = year ?? profile.taxYear;
      return (profile.quarterlyEstimatedDueDates ?? []).map((d) => {
        const calendarYear = d.quarter === 4 ? taxYear + 1 : taxYear;
        const mm = String(d.month).padStart(2, '0');
        const dd = String(d.day).padStart(2, '0');
        const out = { quarter: d.quarter, month: d.month, day: d.day, year: calendarYear, date: `${calendarYear}-${mm}-${dd}` };
        // Pass the uneven income-attribution boundaries through unchanged when the
        // data carries them, so the estimated-tax engine (#82) can bucket income
        // by quarter without re-reading the raw profile.
        for (const k of ['periodStartMonth', 'periodStartDay', 'periodEndMonth', 'periodEndDay']) {
          if (d[k] !== undefined) out[k] = d[k];
        }
        return out;
      });
    },
    /**
     * Federal income-tax marginal brackets (ascending) for a year + filing
     * status, defaulting to the profile's own taxYear / filingStatus. Returns
     * the bracket array, or undefined when none is configured (issue #82).
     */
    getIncomeTaxBrackets(year, filingStatus) {
      const status = filingStatus ?? profile.filingStatus;
      const y = String(year ?? profile.taxYear);
      const byStatus = profile.incomeTaxBracketsByYear && profile.incomeTaxBracketsByYear[status];
      return byStatus ? byStatus[y] : undefined;
    },
    /**
     * Detection matchers for estimated-tax payments recorded in YNAB (issue #82).
     * Always returns an object with the four match arrays (possibly empty), so
     * the engine never has to null-guard.
     */
    getEstimatedTaxPaymentMatchers() {
      const m = profile.estimatedTaxPayments ?? {};
      return {
        payeeKeywords: m.payeeKeywords ?? [],
        categoryNames: m.categoryNames ?? [],
        categoryGroups: m.categoryGroups ?? [],
        accounts: m.accounts ?? [],
      };
    },
  };
}

// --- Public loader ----------------------------------------------------------

function failure(kind, errors, sources) {
  return Object.freeze({
    ok: false,
    error: Object.freeze({
      kind,
      message:
        kind === 'schema'
          ? `tax profile failed schema validation (${errors.length} error(s)); first offending path: ${errors[0] ? errors[0].path : '/'}`
          : errors[0]
            ? errors[0].message
            : `tax profile could not be loaded (${kind})`,
      errors: Object.freeze(errors.map((e) => Object.freeze(e))),
    }),
    // The failure envelope is redacted end-to-end (see redact above): `sources`
    // echoes the same filesystem paths the messages do, in the same envelope,
    // so it gets the same masking. Success-path sources stay raw.
    sources: Object.freeze({ defaults: redact(sources.defaults), profile: redact(sources.profile), schema: redact(sources.schema) }),
    profile: null,
    provenance: null,
  });
}

/**
 * Load, validate, and merge the effective tax profile.
 *
 * Resolution order for the user profile path: options.profilePath → env
 * YNAB_TAX_PROFILE_FILE → `<dataDir>/tax-profile.json`, where dataDir is
 * options.dataDir → env YNAB_DATA_DIR → the canonical plugin-data dir. An ABSENT
 * profile is a normal result: a defaults-only profile with every provenance
 * entry stamped `defaults` and no error. A present-but-schema-invalid profile is
 * a structured FAILURE that names the offending JSON path — it never silently
 * falls back to defaults.
 *
 * Path containment (issue #169): every requested read path must canonicalize
 * into the resolved dataDir or the bundled assets/tax/ directory (see "Path
 * containment" above); a path escaping both roots yields a structured
 * `containment` failure before any read.
 *
 * @param {object} [options]
 * @param {string} [options.profilePath] explicit user-profile path (test seam).
 * @param {string} [options.dataDir]     explicit data dir (test seam).
 * @param {string} [options.defaultsPath] explicit bundled-ruleset path.
 * @param {string} [options.schemaPath]   explicit schema path.
 * @param {object} [options.env]          environment object (defaults to process.env).
 * @returns {Readonly<object>} on success: { ok:true, defaultsOnly, sources, profile(frozen),
 *   provenance(frozen), getStandardDeduction, getThreshold, getBusinessEntities,
 *   getScheduleLineMap, getQuarterlyDueDates }. On failure: { ok:false, error, sources,
 *   profile:null, provenance:null }.
 */
export function loadProfile(options = {}) {
  const env = options.env ?? process.env;
  const dataDir = options.dataDir ?? env.YNAB_DATA_DIR ?? join(homedir(), DATA_DIR_REL);
  const profilePath = options.profilePath ?? env.YNAB_TAX_PROFILE_FILE ?? join(dataDir, 'tax-profile.json');
  const defaultsPath = options.defaultsPath ?? DEFAULT_DEFAULTS_PATH;
  const schemaPath = options.schemaPath ?? DEFAULT_SCHEMA_PATH;
  const sources = { defaults: defaultsPath, profile: null, schema: schemaPath };

  // Containment allowlist (see "Path containment" above): every read below must
  // canonicalize into one of these roots. Returns null when `p` is contained,
  // else the structured failure to hand straight back to the caller. A root that
  // cannot be canonicalized (canonicalize → null, e.g. EACCES) is dropped: it
  // can vouch for nothing, so contain against the roots we could actually
  // resolve rather than admitting paths under an unresolvable one. If BOTH
  // roots drop, every read is refused — note the mode change: even the bundled
  // defaults then surface as a structured `containment` failure instead of the
  // packaging-invariant throw below. Fail-closed, and effectively unreachable
  // (assets/tax ships alongside this module).
  const roots = [canonicalize(dataDir), canonicalize(ASSETS_TAX)].filter((r) => r !== null);
  // Error text may cross an MCP/JSON-RPC boundary, so keep it from leaking the OS
  // username / absolute plugin-data path: echo only the caller's own supplied
  // path with every homedir spelling redacted (see redact/HOME_FORMS above), and
  // drop the absolute resolved roots from the human-readable message (they
  // survive, redacted, in the structured detail).
  const containmentFailure = (label, p) => {
    const real = canonicalize(p);
    if (real !== null && roots.some((root) => isWithin(root, real))) return null;
    return failure(
      'containment',
      [mkErr('', 'containment', `refusing to read ${label} at ${redact(p)}: it resolves outside the allowed roots`, { path: redact(real), roots: roots.map(redact) })],
      sources,
    );
  };

  // The bundled default ruleset is a packaging invariant — its absence is a bug
  // in the plugin, not a user error, so fail loud rather than fabricating data.
  // But a defaultsPath pointing OUTSIDE the allowed roots is a containment
  // violation, not a packaging bug: refuse it without reading.
  const defaultsEscape = containmentFailure('the bundled default ruleset', defaultsPath);
  if (defaultsEscape) return defaultsEscape;
  let defaultsRaw;
  try {
    defaultsRaw = JSON.parse(readFileSync(defaultsPath, 'utf8'));
  } catch (err) {
    // Content hygiene (#207): never echo err.message — fs errors embed the raw
    // path and JSON.parse quotes raw file bytes. redact() still masks the path.
    throw new Error(redact(`tax loader: cannot read bundled default ruleset at ${defaultsPath}: ${describeError(err)}`));
  }

  // Checked before existsSync, not just before the read: an escaping profile
  // path is an illegitimate REQUEST — refusing it outright (rather than only
  // when the target happens to exist) keeps the failure deterministic and
  // avoids acting as an existence oracle for paths outside the roots.
  const profileEscape = containmentFailure('the tax profile', profilePath);
  if (profileEscape) return profileEscape;

  let userRaw = null;
  if (existsSync(profilePath)) {
    sources.profile = profilePath;
    let text;
    try {
      text = readFileSync(profilePath, 'utf8');
    } catch (err) {
      // Content hygiene (#207): only the errno code — never Node's composed
      // err.message, which embeds the raw path. redact() masks the echoed path.
      return failure('io', [mkErr('', 'io', redact(`cannot read tax profile at ${profilePath}: ${describeError(err)}`), {})], sources);
    }
    try {
      userRaw = JSON.parse(text);
    } catch (err) {
      // Content hygiene (#207): position only — V8's SyntaxError.message quotes
      // ~10 raw bytes of the offending file, so it never rides the envelope.
      return failure('parse', [mkErr('', 'parse', redact(`invalid JSON in tax profile at ${profilePath}: ${describeError(err)}`), {})], sources);
    }

    // Validate the user instance against the #20 schema BEFORE merging. A
    // half-valid profile must never silently proceed — a wrong standard
    // deduction used downstream would corrupt every tax number.
    const schemaEscape = containmentFailure('the tax-profile schema', schemaPath);
    if (schemaEscape) return schemaEscape;
    let schema;
    try {
      schema = JSON.parse(readFileSync(schemaPath, 'utf8'));
    } catch (err) {
      // Content hygiene (#207): same as the defaults read above.
      throw new Error(redact(`tax loader: cannot read tax-profile schema at ${schemaPath}: ${describeError(err)}`));
    }
    const { valid, errors } = validateAgainstSchema(userRaw, schema);
    if (!valid) return failure('schema', errors, sources);

    // The main schema leaves `overrides` open, but the overrides layer can patch
    // ANY computed value — so its leaves get the same typed validation as the
    // profile body. A mistyped override (wrong type) or an id-less entity
    // override (which would silently drop lower-tier entities) fails loud here,
    // naming the offending JSON path, instead of corrupting the merged profile.
    if (isPlainObject(userRaw.overrides)) {
      const ov = validateAgainstSchema(userRaw.overrides, buildOverridesSchema(schema));
      if (!ov.valid) {
        const prefixed = ov.errors.map((e) => ({
          ...e,
          path: `/overrides${e.path === '/' ? '' : e.path}`,
        }));
        return failure('schema', prefixed, sources);
      }
    }
  }

  // Resolve + freeze. The `overrides` (and `scheduleLineMap`) layers are
  // schema-open, so a pathologically deep value is not caught upstream; the
  // recursive merge/stamp/strip guards throw a RangeError on excessive nesting,
  // which we convert to a structured `depth` failure rather than letting it
  // escape as an uncaught crash (which would take down the consuming skill — and,
  // on an MCP path, the JSON-RPC handshake).
  let resolved;
  try {
    resolved = resolveProfile(defaultsRaw, userRaw);
  } catch (err) {
    if (err instanceof RangeError) {
      return failure('depth', [mkErr('', 'maxDepth', err.message, {})], sources);
    }
    throw err;
  }
  const { profile, provenance, defaultsOnly } = resolved;
  deepFreeze(profile);
  deepFreeze(provenance);

  return Object.freeze({
    ok: true,
    defaultsOnly,
    sources: Object.freeze(sources),
    profile,
    provenance,
    ...makeAccessors(profile),
  });
}

export default loadProfile;
