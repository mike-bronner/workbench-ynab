// lib/containment.mjs — the shared path-containment guard (issue #169, extended
// to every remaining filesystem seam by #206).
//
// WHAT THIS IS
//   The single implementation of the plugin's filesystem containment invariant.
//   Several modules resolve a read/write path from caller options or env vars
//   (`options.<path>` → `env.YNAB_*` → `join(homedir(), <data-dir>)`) and hand
//   it to readFileSync / writeFileSync / renameSync. Unchecked, that seam is a
//   latent arbitrary-file-read (or, on the write seams, arbitrary-file-WRITE)
//   primitive if any of those values ever arrive from a less-trusted source.
//   So before ANY read or write, the requested path is canonicalized (realpath
//   — resolving `..` traversal and symlinks to the true target the kernel would
//   open) and verified to fall inside an explicit allowlist of roots. A path
//   that resolves outside every root is refused with a structured `containment`
//   failure — the file is never opened.
//
//   Naming a root is an embedding-level trust decision (it is how the test
//   harness points a module at a mkdtemp root): an explicit `dataDir` option or
//   env seam joins the allowlist WITHOUT widening the default no-options
//   surface, and an explicit file path never vouches for itself.
//
//   Factored out of lib/tax/loadProfile.mjs (#169) so the guarded modules —
//   loadProfile, estimatedTax, confidence, monitor/state — share one
//   implementation and one test surface (#206).
//
// WHO CALLS THIS
//   The four guarded modules above, at their options/env → filesystem seams.
//   Pure local path logic: no network, no YNAB calls.
//
// STDOUT / STDERR DISCIPLINE
//   Emits NOTHING to stdout (or stderr). Verdicts are returned as data; the
//   throwing wrapper throws. Safe on any MCP / JSON-RPC path.
//
// RESIDUAL RACE (TOCTOU) — a known, accepted limitation. The guard
// canonicalizes the path, then the caller reopens that same raw path (#169's
// AC prescribes exactly this check-then-open shape). A filesystem mutation
// *between* the check and the open — swapping a component for a symlink in the
// microseconds between them — could still redirect the access. Closing that
// fully needs an open-then-fstat / O_NOFOLLOW-style access, out of scope. It is
// not exploitable via any current caller (paths come from env/defaults, not an
// attacker who also controls the filesystem mid-call); documented so a future
// reader knows the guard defends against malicious *paths*, not concurrent
// filesystem *mutation*.

import { realpathSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, join, sep } from 'node:path';

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
export function canonicalize(p) {
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

// True when `p` is `root` itself or sits beneath it (separator-aware, so a
// sibling sharing the root's name as a prefix — /a/bc under /a/b — never passes).
export function isWithin(root, p) {
  return p === root || p.startsWith(root + sep);
}

// Both spellings of the home directory — as reported by os.homedir() (raw) and
// as the kernel resolves it (canonical). When $HOME itself sits behind a symlink
// or macOS firmlink (homedir() !== realpath(homedir())), a caller-spelled path
// carries the RAW form while a canonicalized path carries the CANONICAL form —
// redaction must mask both, or the un-matched spelling ships the OS username.
// Longest form first so the tighter mask wins if one form contains the other.
//
// os.homedir() itself can THROW (no $HOME and no passwd entry for the uid), so
// the call is guarded: on a throw this degrades to NO known home forms — redact
// then no-ops, mirroring canonicalize's own fail-safe posture — instead of the
// throw propagating out of module evaluation and crashing every importer.
// `getHome` is injectable for exactly that test (the throw case is not
// reproducible on a normal box).
export function buildHomeForms(getHome = homedir) {
  let home;
  try {
    home = getHome();
  } catch {
    return []; // home unresolvable → nothing to mask, and importing never crashes
  }
  return [...new Set([home, canonicalize(home)])]
    .filter((h) => typeof h === 'string' && h.length > 1)
    .sort((a, b) => b.length - a.length);
}

// Computed once at import; empty if home itself is unresolvable — including the
// homedir() throw case above (redact then no-ops: there is no known home prefix
// to mask).
const HOME_FORMS = buildHomeForms();

// Redact every home-directory spelling to `~` in a string destined for a
// failure envelope or thrown message. Error text may cross an MCP/JSON-RPC
// boundary — e.g. the tax facade (lib/tax/index.mjs) re-throws error.message
// verbatim — so everything failure-bound passes through here. Success-path
// values stay raw by design: callers consume those real paths programmatically,
// and success values never ride an error across the boundary.
export const redact = (s) => (typeof s !== 'string' ? s : HOME_FORMS.reduce((acc, h) => acc.split(h).join('~'), s));

// Canonicalize an allowlist of root directories, dropping any that cannot be
// canonicalized (canonicalize → null, e.g. EACCES): an unresolvable root can
// vouch for nothing, so contain against the roots that could actually resolve
// rather than admitting paths under an unresolvable one. If EVERY root drops,
// the returned list is empty and every path is refused — fail closed.
export function resolveRoots(dirs) {
  return dirs.map(canonicalize).filter((r) => r !== null);
}

/**
 * The containment verdict for one path against pre-resolved roots.
 *
 * @param {string}   label the human-readable name of the file ("the tax tracker").
 * @param {string}   p     the raw requested path (as the caller supplied it).
 * @param {string[]} roots canonicalized allowlist roots (from resolveRoots).
 * @param {string}   [verb] 'read' (default) or 'write' — for the message only.
 * @returns {null|{kind:'containment',message:string,path:string|null,roots:string[]}}
 *   null when `p` canonicalizes inside a root; otherwise a structured failure
 *   description. Every string in the failure is homedir-redacted (see redact) —
 *   the human-readable message echoes only the caller's own supplied path, and
 *   the resolved path/roots survive, redacted, in the structured detail.
 */
export function checkContainment(label, p, roots, verb = 'read') {
  const real = canonicalize(p);
  if (real !== null && roots.some((root) => isWithin(root, real))) return null;
  return {
    kind: 'containment',
    message: `refusing to ${verb} ${label} at ${redact(p)}: it resolves outside the allowed roots`,
    path: redact(real),
    roots: roots.map(redact),
  };
}

/**
 * The throwing form of checkContainment, for modules whose error convention is
 * to throw (estimatedTax's tracker, confidence's config, the monitor state
 * store). Throws an Error carrying `code: 'containment'` plus the structured
 * `path`/`roots` detail; returns undefined when contained.
 */
export function assertContained(label, p, roots, verb = 'read') {
  const failure = checkContainment(label, p, roots, verb);
  if (failure === null) return;
  throw Object.assign(new Error(failure.message), { code: failure.kind, path: failure.path, roots: failure.roots });
}
