# `lib/tax/loadProfile.mjs` — the tax-profile loader contract

The tax-profile loader is the single, trustworthy way to obtain the **effective**
tax profile: the bundled default US ruleset deep-merged with the user's profile
instance and any explicit `overrides`. The tax engine and the review skill consume
its frozen output instead of reading config files themselves.

It is **pure local config resolution** — no network, no YNAB calls — and is read by
the plugin **skills**, never by the vendored third-party YNAB MCP.

> Design ref: M3-3 (issue #22). Depends on the schema (#20) and the default US
> ruleset (#21).

## What it reads

| Layer | Source | Precedence |
| --- | --- | --- |
| **defaults** | `assets/tax/us-tax-lines.json` (#21) — bundled in the repo, relative to repo root, so it survives plugin updates. | lowest |
| **user profile** | `tax-profile.json` in the plugin data dir (#25). | middle |
| **overrides** | the user profile's own `overrides` object. | **highest** |

The bundled defaults and the JSON Schema (`assets/tax/tax-profile.schema.json`,
#20) are resolved relative to the module's own location, never from the data dir.

### User-profile path resolution

The user profile path resolves in this order (first hit wins):

1. `options.profilePath` — explicit, used by the test harness.
2. `YNAB_TAX_PROFILE_FILE` — environment seam.
3. `<dataDir>/tax-profile.json`, where `dataDir` is `options.dataDir` →
   `YNAB_DATA_DIR` → `$HOME/.claude/plugins/data/workbench-ynab-claude-workbench`.

This mirrors how `bin/config.sh` honours `YNAB_CONFIG_FILE`.

An **absent** user profile is a normal result, not an error: the loader returns a
**defaults-only** profile with every provenance entry stamped `defaults`.

## Path containment — reads are allowlisted (issue #169)

The loader forwards caller-supplied paths (`options.profilePath` / `dataDir` /
`defaultsPath` / `schemaPath`, or their env seams) into `readFileSync` — left
unchecked, a latent **arbitrary-file-read** primitive if any of those values ever
arrive from a less-trusted source. So before **any** read, the requested path is
**canonicalized** — resolved to the exact target the kernel would `open(2)`,
using the native `realpathSync.native` so symlinks are dereferenced in true
kernel order (**symlink first, then `..`**). This matters: the non-native
`realpathSync` collapses `..` *lexically* before walking any symlink, so a
`link/../x` path (`link` → outside the roots) would canonicalize to the wrong,
in-root location while `readFileSync` opens the real, outside target — the two
would disagree and the read would win. A not-yet-existing target is canonicalized
via its deepest existing ancestor (walking up on the raw path, never a lexical
`resolve`, so the same kernel ordering holds). The canonicalized path must fall
inside an explicit allowlist of roots:

1. the **resolved data dir** — `options.dataDir` → `YNAB_DATA_DIR` → the
   canonical plugin-data dir;
2. the **bundled `assets/tax/` directory** (the defaults and schema live there).

A path that resolves outside every root is refused with a structured failure —
`error.kind === 'containment'`, following the `io`/`parse`/`schema`/`depth`
pattern — and the file is **never opened**. The profile path is checked before
the existence probe, so an escaping request fails deterministically whether or
not its target exists (no existence oracle). An escaping `defaultsPath` /
`schemaPath` is likewise a structured `containment` failure — only a
missing-but-contained bundled file remains the packaging-invariant **throw**.

The canonicalizer **fails closed**: only a not-yet-existing target (`ENOENT`) is
resolved via its deepest existing ancestor — a read of a missing path `ENOENT`s
regardless, so nothing leaks. Any *other* `realpath` error (`EACCES`, `ELOOP`, a
symlink loop, `ENOTDIR`, …) means the true target is unknowable, so the path is
treated as outside every root and refused, never vouched for with a fabricated
in-root path.

The **failure envelope is redacted end-to-end**: every path echoed on an error
path — the `containment` message (which echoes only the caller's own supplied
path, with the absolute resolved roots dropped from the human-readable text and
surviving, redacted, in the structured `params`), the pre-existing `io`/`parse`
messages (including the OS-level `err.message`, which embeds the raw path), the
`sources` field of a failure result, and the packaging-invariant throw messages
— has the home directory masked to `~`. **Both spellings** of home are masked:
as reported by `os.homedir()` *and* as the kernel canonicalizes it, so the
masking holds even when `$HOME` itself resolves through a symlink or macOS
firmlink (`homedir() !== realpath(homedir())`). This keeps the OS username /
absolute plugin-data path from leaking should the failure cross an MCP/JSON-RPC
boundary. On a **successful** load, `sources` deliberately carries the real,
unredacted paths — callers consume those programmatically, and success values
never ride an error message across that boundary.

**Residual race (known limitation).** The guard canonicalizes the path, then the
read reopens that same raw path (the check-then-open shape the AC prescribes). A
filesystem mutation *between* check and read — swapping a component for a symlink
in that window — could still redirect the read; closing it fully needs an
open-then-`fstat` / `O_NOFOLLOW`-style read, out of scope here. It is not
reachable through the only caller (paths come from env/defaults, not an attacker
who also controls the filesystem mid-call). The guard defends against malicious
*paths*, not concurrent filesystem *mutation*.

**How the test seams stay usable without weakening production:** naming a root is
an embedding-level trust decision. An explicitly-passed `options.dataDir` (or
`YNAB_DATA_DIR`) *joins the allowlist as a root* — that is how the test harness
points the loader at a `mkdtemp` directory (`{ dataDir: TMP, profilePath: … }`)
— while the default no-options surface stays pinned to the canonical plugin-data
dir plus `assets/tax/`. A bare `options.profilePath` does **not** widen the
allowlist: it must still canonicalize into one of the roots.

## Validation — before any merge

The user profile is validated against the canonical JSON Schema (#20, draft
2020-12) **before** it is merged. On a schema violation the loader returns a
structured failure that names the offending JSON path (`error.errors[].path`) — it
**never** silently proceeds with a half-valid profile, because a wrong standard
deduction used downstream would corrupt every tax number.

Validation is **dependency-free**: a compact, purpose-built JSON-Schema-subset
validator built on `node:` built-ins only — no `ajv`, no `node_modules`. This keeps
the loader faithful to the plugin's "nothing to install" premise and the recorded
"no `node_modules`, ever" test-harness decision (`docs/testing.md`). The supported
keyword subset (`type`, `required`, `properties`, `additionalProperties`,
`propertyNames`, `enum`, `oneOf`, `items`, `minimum`, `maximum`, `minLength`,
`minItems`, `pattern`) is exactly what `tax-profile.schema.json` uses.

### The `overrides` layer is type-checked too

The schema deliberately leaves `overrides` **open** (`additionalProperties: true`)
so any subset of the ruleset may be patched — but the overrides layer can change
**any** computed value, so the loader gives its leaves the same typed validation as
the profile body. It derives a "partial profile" schema from the main schema
(`buildOverridesSchema`): the root `required` is dropped and the root is opened (an
override is a partial that may also target ruleset-only keys like `lines`), but
every typed constraint (`type`/`enum`/`minimum`/`pattern`/…) is inherited. A
**type-incompatible** override (e.g. a string where a rate belongs) therefore fails
loud with its JSON path under `/overrides/…`, instead of silently corrupting the
merged profile. A `businessEntities` override item must carry an `id` (the merge
keys on it); the other entity fields stay optional so an id-only patch is legal, but
an **id-less** entity override is rejected rather than silently dropping every
lower-tier entity. For the same reason an **empty** `businessEntities` override
(`[]`) is rejected (`minItems: 1`): it has no element to carry an `id`, so it would
skip the by-id merge and wholesale-replace the array, silently dropping every
lower-tier entity. (A legitimate "clear all entities" is implausible — the user
would simply not declare them — and silently zeroing tax entities is catastrophic.)

## Merge semantics (deterministic)

Applied in precedence order **defaults → user profile → overrides**:

- **Objects** merge recursively.
- **Arrays of entities** (every element is an object with a string `id`) merge by
  `id`: a matching entity is merged recursively, a new `id` is appended, and an
  entity present only in a lower layer is kept.
- **Everything else** — scalars and non-entity arrays (e.g. `categoryGroups`,
  `quarterlyEstimatedDueDates`) — **overrides** wholesale.

A layer that restates a value identical to the already-resolved one does **not**
claim provenance; the lower tier's stamp stands. (This is what keeps an entity's
`id`, used only as the merge key, from being mislabelled.)

The merge **skips the prototype-pollution keys** `__proto__`, `constructor`, and
`prototype` wherever it copies keys out of externally-sourced JSON. A JSON
`__proto__` survives `JSON.parse` as an *own* property, so a naive deep-merge would
read it via bracket access and mutate the global `Object.prototype` of the whole
process; these keys are never legitimate tax-profile keys, so they are dropped
outright. The merge likewise **skips `$`-prefixed annotation keys** (`$comment`,
`$schema`, …) across all three tiers — both at the top of each merge step and
inside the deep clone of any wholesale-replaced or newly-appended subtree — so a
`$` key under a schema-open `overrides` (or `scheduleLineMap`) key can never leak
into the frozen profile, which the profile's own schema forbids
(`additionalProperties: false`). The exported `resolveProfile` and `deepMerge` carry
the same guards, since the engine consumes them with raw `JSON.parse` output.

### Bounded nesting depth

`overrides` and `scheduleLineMap` are schema-open (`additionalProperties: true`), so
the validator does not recurse into them — a pathologically deep value there would
otherwise overflow the recursive merge and escape as an uncaught `RangeError`. The
merge/stamp/strip routines enforce a generous **maximum nesting depth** (well above
any real profile, well below the engine's stack limit); crossing it produces a
structured `depth` failure (`error.kind === 'depth'`) instead of crashing the
consuming skill — or, on an MCP path, the JSON-RPC handshake. Direct callers of
`resolveProfile` / `deepMerge` get a clear `RangeError` rather than a cryptic stack
overflow.

## Provenance

The result includes a `provenance` map keyed by leaf path → source tier
(`defaults` | `user` | `overrides`), so the report can show transparently where
each effective value came from. Paths use dot notation for objects, `[id]` for
entity arrays, and `[i]` for other arrays — e.g.
`thresholds.saltCap`, `standardDeductionByYear.single.2025`,
`businessEntities[biz-a].scheduleLineMap.office`.

## Result shape

```js
import { loadProfile } from '../../lib/tax/loadProfile.mjs';

const r = loadProfile();
if (!r.ok) {
  // r.error = { kind: 'schema' | 'parse' | 'io' | 'depth' | 'containment', message, errors: [{ path, keyword, message, params }] }
  // r.profile === null  (no silent fallback)
} else {
  // r.defaultsOnly  — true when no user profile was found
  // r.sources       — { defaults, profile, schema } resolved paths
  // r.profile       — the frozen, merged profile object
  // r.provenance    — the frozen leaf-path → tier map
  // accessors (bound to the resolved profile):
  r.getStandardDeduction(year, filingStatus); // dollars, or undefined
  r.getThreshold(name);                        // e.g. 'seTaxRate'
  r.getBusinessEntities();                     // always an array
  r.getScheduleLineMap(entityId);              // an entity's map, or undefined
  r.getQuarterlyDueDates(year);                // [{ quarter, month, day, year, date, period* }]
  r.getIncomeTaxBrackets(year, filingStatus);  // marginal brackets, or undefined (#82)
  r.getEstimatedTaxPaymentMatchers();          // { payeeKeywords, categoryNames, categoryGroups, accounts } (#82)
}
```

The returned `profile` and `provenance` are **frozen** (`Object.freeze`,
recursively) to prevent shared-state mutation.

`getQuarterlyDueDates(year)` resolves each due date to a calendar date: Q1–Q3 fall
in the tax year; **Q4 falls in January of the following year** (see the schema's
format note). Weekend/holiday shifting is the engine's responsibility, not this
loader's.

## stdout / stderr discipline

The module emits **nothing to stdout**. It is pure library code that returns a
structured result; errors are returned as data (packaging invariants like a
missing bundled ruleset are thrown — Node prints those to stderr). Keeping stdout
clean means the loader is safe even if it is ever invoked from a JSON-RPC / MCP
path, where a single stray stdout byte corrupts the handshake (see
`workbench-core/hooks/mcp-memory.sh`). Any future diagnostic output must go to
stderr only.

## Testing

`tests/unit/load-profile.test.mjs` runs under the built-in `node:test` runner with
**no `node_modules`** and covers: defaults-only fallback, user-over-defaults,
overrides-over-user, schema-invalid failure (with the offending path), provenance
across all three tiers, array-merge-by-id + object deep-merge, the accessors, and
the no-stdout guarantee (asserted by spawning a child process). It also covers the
security and robustness edges: prototype-pollution via a `__proto__` override and
`constructor.prototype` (and through the exported `resolveProfile`/`deepMerge`),
type-incompatible / id-less / empty-array overrides failing loud, `$`-prefixed
annotation keys never leaking into the frozen profile, a too-deep override yielding
a structured `depth` failure instead of a crash, the `propertyNames` container-path
convention, the `schemaVersion` `oneOf` arms, the `io`/missing-ruleset/missing-schema
failure paths, and a beyond-two-levels deep-freeze assertion. The path-containment
allowlist (#169) is covered too: `..`-traversal, symlink-escape, the combined
**symlink-then-`..`** kernel-order bypass (both existing- and absent-target),
absolute-escape, and escaping `defaultsPath`/`schemaPath` requests all refused
with a structured `containment` failure and a wiped result envelope; a symlink
loop (`ELOOP`) proves the canonicalizer **fails closed** on a non-`ENOENT` error;
and the `YNAB_DATA_DIR` env seam is exercised as an allowlist root, with a bare
escaping `profilePath` (no `dataDir`) confirmed not to widen it. The tests' own
`mkdtemp` dir is admitted via the explicit `dataDir` root. Out-of-process tests
(a spawned child with a re-pointed `$HOME`) pin the redaction under a
**symlinked home** — neither the raw nor the canonical home spelling leaks from
a `containment` or `io` failure envelope — and guard the real **no-options
default chain**: a profile under `~/.claude/plugins/data/…` loads and merges
with zero options, and a fresh install with no data dir at all still resolves
defaults-only rather than tripping containment.

> **Not tax advice.** This tool organizes financial data and surfaces tax-relevant
> signals. It is not a substitute for professional tax advice.
