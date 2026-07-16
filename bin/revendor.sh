#!/usr/bin/env bash
#
# bin/revendor.sh — re-vendor the YNAB MCP bundle in one controlled command.
#
# The bundle at vendor/ynab-mcp/index.cjs is the FROZEN copy of record (M1-3):
# pinned in git, booted offline on system `node`, never edited by hand. When a
# new @dizzlkheinz/ynab-mcpb version ships, this script performs the update so
# re-vendoring is reproducible, not a manual ritual:
#
#   1. Downloads the target version's tarball into a temp dir (npm pack), never
#      touching the repo root or installing into it.
#   2. PROVENANCE GATE (GAP-2 / #5): before unpacking a single byte, cross-checks
#      the download against the npm registry's PUBLISHED integrity metadata
#      (`npm view … dist.integrity dist.shasum`). The tarball's computed SHA-512
#      SRI and SHA-1 shasum must BOTH match the registry, or extraction is
#      refused. Then verifies the registry's cryptographic signature on the
#      version via npm's own published keys (`npm audit signatures`); if the
#      registry publishes no signature for the package the gate is not skipped
#      silently — it is recorded as a residual supply-chain risk in the marker.
#   3. Extracts dist/bundle/index.cjs and overwrites vendor/ynab-mcp/index.cjs.
#   4. Recomputes the upstream tarball + vendored-bundle SHA-256 and rewrites the
#      version marker (vendored.json) — package, version, both hashes, today's
#      date, provenance URL + integrity, the registry SHA-1, and the signature
#      verification outcome.
#   5. Prints a human-readable old → new diff summary and reminds the operator to
#      run the M1-7 offline-boot verification before committing.
#
# It is IDEMPOTENT: re-running with a version whose bundle is already vendored
# detects no change and exits 0 without writing. It NEVER auto-commits — the
# operator reviews the diff and commits manually (the commit-approval gate).
#
# Identity is the artifact HASH, not just the version string (mirrors bujo's
# build-wheel content-hash approach): a version republished with different bytes
# is correctly detected as a change.
#
# CONVENTIONS
#   * stdout carries the RESULT — the diff summary, the no-change line, and the
#     post-update reminder. All progress/noise goes to stderr (log()).
#   * macOS-first bash; zero third-party deps beyond what the plugin already
#     requires (node, npm, jq, shasum, tar).
#
# USAGE
#   bin/revendor.sh [<version>]
#     <version>  npm version to vendor (default: the version pinned in
#                vendor/ynab-mcp/vendored.json).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT/vendor/ynab-mcp"
MARKER="$VENDOR_DIR/vendored.json"
BUNDLE="$VENDOR_DIR/index.cjs"

# All progress/diagnostics go to stderr; stdout is reserved for the result.
log() { printf '%s\n' "$*" >&2; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

# --- Prerequisites ----------------------------------------------------------
# node + npm do the download; jq reads/writes the JSON marker; shasum hashes;
# tar unpacks. Hard-error with actionable guidance rather than failing obscurely
# half-way through.
require() {
  command -v "$1" >/dev/null 2>&1 \
    || die "'$1' is required but not on \$PATH — $2"
}
require node "install Node (e.g. 'brew install node') so the bundle can be packed"
require npm  "install npm (ships with Node — 'brew install node') to fetch the package"
require jq   "install jq ('brew install jq') to read/write the version marker"
require shasum "shasum is part of macOS/Perl — ensure it is on \$PATH to hash artifacts"
require tar  "tar is required to unpack the npm tarball"
require openssl "install openssl (ships with macOS/Linux) to compute the tarball's SHA-512 SRI for the registry provenance check"

[ -f "$MARKER" ] || die "version marker not found: $MARKER (was M1-3 vendoring run?)"

# --- Resolve target version + provenance from the marker --------------------
NAME="$(jq -r '.name' "$MARKER")"
if [ -z "$NAME" ] || [ "$NAME" = "null" ]; then die "vendored.json has no .name"; fi

PINNED_VERSION="$(jq -r '.version' "$MARKER")"
OLD_BUNDLE_SHA="$(jq -r '.bundle_sha256 // ""' "$MARKER")"
# Where the bundle lives inside the unpacked tarball (npm unpacks under package/).
BUNDLE_SRC_PATH="$(jq -r '.bundle_source_path // "package/dist/bundle/index.cjs"' "$MARKER")"
VENDORED_PATH="$(jq -r '.vendored_path // "vendor/ynab-mcp/index.cjs"' "$MARKER")"
SELF_CONTAINED="$(jq -r 'if has("self_contained") then .self_contained else true end' "$MARKER")"

VERSION="${1:-$PINNED_VERSION}"
SPEC="$NAME@$VERSION"

log "Re-vendoring $SPEC"
log "  marker:  $MARKER"
log "  pinned:  $PINNED_VERSION"

# --- Temp workspace (cleaned on ANY exit, including error) ------------------
# The marker temp ($MARKER.tmp) is rewritten in the tracked vendor dir, NOT under
# $TMP, so its mv into place stays same-filesystem and atomic. That puts it
# outside $TMP's cleanup, so the trap drops it too: a jq/mv failure mid-write (or
# any `set -e` abort) must never strand vendored.json.tmp in the tracked tree.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/revendor-ynab.XXXXXX")"
trap 'rm -rf "$TMP" "$MARKER.tmp"' EXIT

# --- Download via npm pack --json (no install, no repo pollution) -----------
log "Downloading $SPEC via npm pack…"
if ! ( cd "$TMP" && npm pack --json "$SPEC" ) > "$TMP/pack.json" 2> "$TMP/npm.err"; then
  log "--- npm output ---"
  cat "$TMP/npm.err" >&2 || true
  die "npm pack failed for $SPEC (does that version exist on the registry?)"
fi

# npm pack exited 0, but a future npm (or a wrapper) could still emit non-JSON
# noise on stdout. Validate the shape up front so a parse failure surfaces this
# actionable message plus the captured output, not a raw jq error mid-pipeline.
if ! jq -e '.[0].filename' "$TMP/pack.json" >/dev/null 2>&1; then
  log "--- npm stdout ---"; cat "$TMP/pack.json" >&2 || true
  log "--- npm stderr ---"; cat "$TMP/npm.err" >&2 || true
  die "npm pack did not return the expected JSON for $SPEC (npm output above)"
fi

TARBALL_FILE="$(jq -r '.[0].filename' "$TMP/pack.json")"
TARBALL="$TMP/$TARBALL_FILE"
[ -f "$TARBALL" ] || die "npm pack reported '$TARBALL_FILE' but it is not in $TMP"

TARBALL_SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"

# --- Provenance gate: registry integrity (BEFORE extraction) ----------------
# GAP-2 / #5: npm pack already fetches from the registry, but nothing made the
# trust link explicit. Cross-check the downloaded tarball against the registry's
# PUBLISHED integrity metadata before unpacking a single byte: the computed
# SHA-512 SRI must match dist.integrity AND the computed SHA-1 must match
# dist.shasum. A mismatch means the download does not descend from the
# registry-published artifact — refuse to extract.
log "Verifying tarball against npm registry provenance for $SPEC…"
if ! REG_META="$(npm view "$SPEC" --json dist.integrity dist.shasum dist.tarball 2>"$TMP/view.err")"; then
  cat "$TMP/view.err" >&2 || true
  die "npm view failed for $SPEC — cannot fetch the registry integrity metadata to verify against"
fi
# Fail-CLOSED schema guard, mirroring the npm pack (above) and npm audit (below)
# guards: npm view exited 0, but a future npm — or a wrapper — could still emit
# non-JSON noise on stdout. `npm view --json <field>…` returns a JSON OBJECT keyed
# by the requested fields; validate that shape up front so a malformed payload
# surfaces this actionable message plus the captured output, not a raw jq error
# when the registry fields are indexed below.
if ! jq -e 'type == "object"' <<<"$REG_META" >/dev/null 2>&1; then
  log "--- npm stdout ---"; printf '%s\n' "$REG_META" >&2 || true
  log "--- npm stderr ---"; cat "$TMP/view.err" >&2 || true
  die "npm view did not return the expected JSON for $SPEC (npm output above)"
fi
REG_INTEGRITY="$(jq -r '."dist.integrity" // ""' <<<"$REG_META")"
REG_SHASUM="$(jq -r '."dist.shasum" // ""' <<<"$REG_META")"
REG_TARBALL="$(jq -r '."dist.tarball" // ""' <<<"$REG_META")"
[ -n "$REG_INTEGRITY" ] || die "registry returned no dist.integrity for $SPEC — cannot verify provenance"
[ -n "$REG_SHASUM" ]    || die "registry returned no dist.shasum for $SPEC — cannot verify provenance"

# Computed SHA-512 SRI (base64 of the raw digest, npm's integrity format) and
# SHA-1 of the SAME downloaded file.
TARBALL_SRI="sha512-$(openssl dgst -sha512 -binary "$TARBALL" | openssl base64 -A)"
TARBALL_SHA1="$(shasum -a 1 "$TARBALL" | awk '{print $1}')"

[ "$TARBALL_SRI" = "$REG_INTEGRITY" ] \
  || die "tarball SHA-512 SRI mismatch — registry says $REG_INTEGRITY but the download is $TARBALL_SRI; refusing to extract"
[ "$TARBALL_SHA1" = "$REG_SHASUM" ] \
  || die "tarball SHA-1 shasum mismatch — registry says $REG_SHASUM but the download is $TARBALL_SHA1; refusing to extract"
log "  ✓ integrity verified — SHA-512 SRI and SHA-1 both match the registry"

# --- Extract + locate the bundle --------------------------------------------
EXTRACT="$TMP/extract"
mkdir -p "$EXTRACT"
# --no-same-owner: never honor uid/gid recorded in a registry tarball (defense
# if this is ever run as root). Modern bsdtar/GNU tar already strip a leading
# '/' and refuse '..' components, and the operator reviews the bundle diff
# before committing — so this is belt-and-suspenders on the supply-chain edge.
tar -xzf "$TARBALL" -C "$EXTRACT" --no-same-owner
SRC_BUNDLE="$EXTRACT/$BUNDLE_SRC_PATH"
[ -f "$SRC_BUNDLE" ] \
  || die "expected bundle at '$BUNDLE_SRC_PATH' inside the tarball, but it is missing — upstream layout may have changed"

NEW_BUNDLE_SHA="$(shasum -a 256 "$SRC_BUNDLE" | awk '{print $1}')"

# --- Idempotency: same version AND same bundle bytes → nothing to do --------
# Carve-out: this early return is BEFORE the signature gate below, so a no-change
# re-pin does NOT re-verify the registry signature — a signature revoked upstream
# after the original vendor is not re-checked here. Re-vendoring changed bytes (a
# new version or republished bytes) always runs the full gate. Documented in
# docs/vendoring.md and SECURITY.md so the behavior is auditable.
if [ "$VERSION" = "$PINNED_VERSION" ] && [ "$NEW_BUNDLE_SHA" = "$OLD_BUNDLE_SHA" ]; then
  printf 'No change: %s is already vendored (bundle %s).\n' "$SPEC" "$NEW_BUNDLE_SHA"
  printf 'Nothing was modified.\n'
  exit 0
fi

# --- Provenance gate: registry signature ------------------------------------
# We are about to adopt new bytes, so verify the registry's cryptographic
# signature on this version using npm's OWN published keys (`npm audit
# signatures`) — provenance must not rest on hashes alone. Installed into an
# isolated temp dir under $TMP (NEVER the repo root, NEVER the working tree). An
# INVALID signature is a hard stop (possible tampering); a MISSING signature is
# recorded as a residual supply-chain risk rather than skipped silently.
log "Verifying registry signature for $SPEC via 'npm audit signatures'…"
SIGDIR="$TMP/sigcheck"
mkdir -p "$SIGDIR"
printf '{"name":"ynab-mcpb-sigcheck","version":"0.0.0","private":true}\n' > "$SIGDIR/package.json"
SIG_STATUS="unavailable"
SIG_NOTE=""
if ! ( cd "$SIGDIR" && npm install --ignore-scripts --no-audit --no-fund "$SPEC" ) >"$TMP/sig-install.log" 2>&1; then
  cat "$TMP/sig-install.log" >&2 || true
  die "isolated install for signature verification failed for $SPEC"
fi
# Keep the audit's stderr (mirroring the install step's sig-install.log) so a
# non-signature failure — old npm, network, a registry hiccup — is shown with
# npm's own diagnostics, not swallowed behind the generic guard below.
AUDIT="$( cd "$SIGDIR" && npm audit signatures --json 2>"$TMP/sig-audit.log" )" || true
# Fail-CLOSED schema guard. `npm audit signatures --json` reports findings under
# exactly two arrays — `invalid` and `missing`; a package absent from both is a
# pass. We trust that "verified by elimination" ONLY when the output is a shape
# we fully recognize: it is an object, BOTH fields are arrays (not null/scalar),
# and there is NO unrecognized top-level key. This is what makes "verified"
# require positive evidence instead of being a blind catch-all `else`:
#   * {"invalid":null,"missing":null} — the keys exist but aren't arrays, so the
#     old has()-only check passed it while both length probes returned 0 → a
#     FALSE "verified". The array-type test rejects it.
#   * {"invalid":[],"missing":[],"revoked":[…]} — a NEW failure category a future
#     npm might add would otherwise fall straight through to "verified". The
#     unknown-key test rejects it.
# For a gate whose premise is zero-trust toward a possibly-compromised registry,
# the safe default on an unexpected shape is to STOP, not to pass.
if ! jq -e '
      type == "object"
      and (.invalid | type) == "array"
      and (.missing | type) == "array"
      and ([keys[] | select(. != "invalid" and . != "missing")] | length) == 0
    ' <<<"$AUDIT" >/dev/null 2>&1; then
  cat "$TMP/sig-audit.log" >&2 || true
  die "could not parse or recognize 'npm audit signatures' output for $SPEC — signature verification did not run"
fi
# Lift the counts into plain variables BEFORE the if. A `$(jq …)` evaluated
# inside an `if`-condition runs with `set -e` suspended, so a jq failure there
# would be silently treated as a count rather than aborting the run.
SIG_INVALID="$(jq --arg n "$NAME" '[.invalid[]? | select(.name==$n)] | length' <<<"$AUDIT")"
SIG_MISSING="$(jq --arg n "$NAME" '[.missing[]? | select(.name==$n)] | length' <<<"$AUDIT")"
if [ "$SIG_INVALID" -gt 0 ]; then
  die "registry signature INVALID for $SPEC — possible tampering; refusing to vendor"
elif [ "$SIG_MISSING" -gt 0 ]; then
  SIG_STATUS="unavailable"
  SIG_NOTE="npm registry publishes no signature for $SPEC; provenance rests on the integrity-hash chain only — residual supply-chain risk."
  log "  ⚠ no registry signature for $SPEC — recorded as a residual supply-chain risk"
else
  SIG_STATUS="verified"
  log "  ✓ registry signature verified against npm's published keys"
fi

# --- Node floor re-derivation (issue #3) -------------------------------------
# vendor/ynab-mcp/NODE_VERSION pins the minimum Node major the bundle supports;
# adopting new bundle bytes is exactly when that requirement can move, so
# re-derive it here from the incoming package's engines.node declaration. The
# floor is RAISED when upstream demands more, never lowered automatically —
# lowering needs a human boot-proof on the older major, not a metadata read.
#
# SCOPE: this reads the incoming package's OWN engines.node only — a pre-built
# bundle's tarball carries no node_modules, so transitive dependencies'
# constraints are invisible here. The current floor (18) in fact came from a
# transitive dep (@modelcontextprotocol/sdk's `engines.node >=18`), which this
# metadata read can never see; the CI floor lane (which boots the bundle on
# exactly the floor major) is the enforcement that catches a transitive raise.
# Upstream currently declares no engines field; in that case too the floor is
# kept and the CI floor lane stays the proof. See docs/vendoring.md
# ("The Node floor").

# derive_node_floor <engines.node expression> — print the minimum Node major
# the expression implies, or nothing when it implies no minimum. Operator-
# aware: only a lower bound (`>=X`, `>X`, `=X`), a caret/tilde range (`^X`,
# `~X`), or a bare / x-range version (`X`, `X.x`, `X.*`) establishes a floor;
# upper bounds (`<X`, `<=X`) never do. A hyphen range (`A - B`) means
# `>=A <=B`, so it contributes A (its RHS is an upper bound, no floor). A
# bare-major `>N` (or `>N.x`) desugars — exactly as node-semver does — to
# `>=(N+1).0.0`, contributing N+1; `>N.m…` with a concrete minor stays at N.
# `||` alternatives OR together, so the result is the MINIMUM across them;
# comparators inside one alternative AND together, so its floor is the
# MAXIMUM of its lower bounds. Any alternative with no lower bound (e.g.
# `<20` alone, or `*`) is satisfiable by arbitrarily old majors — the whole
# expression then implies no minimum.
# Subshell body: `set -f` must not leak (engines can legally contain `*`,
# which a plain word-split would glob against the CWD).
derive_node_floor() (
  expr="$1" floor=""
  set -f
  while IFS= read -r alt; do
    [ -n "${alt//[[:space:]]/}" ] || continue
    alt_floor="" skip_next=0
    # shellcheck disable=SC2086  # word-splitting the comparators is the point
    for comp in $alt; do
      # A detached upper-bound operator (`< 20`) — or the `-` of a hyphen
      # range (`16 - 20`), whose RHS is likewise an upper endpoint — consumes
      # the next word too, so its version is never misread as a bare-version
      # floor. (The hyphen range's LOWER endpoint was already taken as a bare
      # version by the time the `-` is seen — exactly the floor it implies.)
      if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
      case "$comp" in
        '<' | '<=' | '-') skip_next=1; continue ;;   # detached upper bound
        \<*) continue ;;                        # <X / <=X: no floor implied
        \>=*) major="${comp#>=}" ;;
        \>*)
          # node-semver desugars a bare-major `>N` (and `>N.x`) to
          # `>=(N+1).0.0` — no major-N version satisfies it, so the floor is
          # N+1. A concrete minor (`>N.m…`) keeps major N (N.m+1 satisfies it).
          major="${comp#>}"; major="${major#v}"
          maj="${major%%.*}"
          case "$maj" in '' | *[!0-9]*) continue ;; esac
          minor=""
          [ "$major" != "$maj" ] && { minor="${major#*.}"; minor="${minor%%.*}"; }
          case "$minor" in '' | x | X | \*) maj=$((maj + 1)) ;; esac
          major="$maj"
          ;;
        '^'*) major="${comp#^}" ;;
        \~*)  major="${comp#\~}" ;;   # \~: bare ~ in the pattern would tilde-expand
        =*)   major="${comp#=}" ;;
        *)    major="$comp" ;;                  # bare version or x-range
      esac
      major="${major#v}"
      major="${major%%.*}"
      case "$major" in '' | *[!0-9]*) continue ;; esac   # x, *, garbage
      if [ -z "$alt_floor" ] || [ "$major" -gt "$alt_floor" ]; then
        alt_floor="$major"
      fi
    done
    if [ -z "$alt_floor" ]; then
      return 0   # one unbounded-below alternative → no minimum at all
    fi
    if [ -z "$floor" ] || [ "$alt_floor" -lt "$floor" ]; then
      floor="$alt_floor"
    fi
  done <<< "${expr//\|\|/$'\n'}"
  printf '%s' "$floor"
)

FLOOR_FILE="$VENDOR_DIR/NODE_VERSION"
CUR_FLOOR=""
[ -f "$FLOOR_FILE" ] && CUR_FLOOR="$(tr -d '[:space:]' < "$FLOOR_FILE")"
# engines.node is untrusted upstream metadata that gets spliced into the
# summary (stdout) and the progress log (stderr): map control bytes (ANSI
# escapes, tabs, embedded newlines) to spaces — a safe comparator separator —
# before anything parses or prints it (CWE-150 escape injection), then trim
# the trailing blank jq's own newline leaves so an absent field still reads
# as empty.
ENGINES_NODE="$(jq -r '.engines.node // ""' "$EXTRACT/package/package.json" 2>/dev/null | tr -c '[:print:]' ' ' || true)"
ENGINES_NODE="${ENGINES_NODE%"${ENGINES_NODE##*[! ]}"}"
DERIVED_FLOOR="$(derive_node_floor "$ENGINES_NODE")"
if [ -n "$DERIVED_FLOOR" ] && { [ -z "$CUR_FLOOR" ] || [ "$DERIVED_FLOOR" -gt "$CUR_FLOOR" ]; }; then
  printf '%s\n' "$DERIVED_FLOOR" > "$FLOOR_FILE"
  FLOOR_NOTE="${CUR_FLOOR:-unset} → $DERIVED_FLOOR (upstream engines.node '$ENGINES_NODE')"
  log "  ⚠ Node floor raised to $DERIVED_FLOOR by upstream engines.node ('$ENGINES_NODE') — update the README bullet and the ci.yml matrix (tests/unit/node-floor.test.sh enforces the sync)"
elif [ -n "$DERIVED_FLOOR" ]; then
  FLOOR_NOTE="$CUR_FLOOR (unchanged; upstream engines.node '$ENGINES_NODE' implies $DERIVED_FLOOR)"
elif [ -n "$ENGINES_NODE" ]; then
  FLOOR_NOTE="${CUR_FLOOR:-unset} (unchanged; upstream engines.node '$ENGINES_NODE' implies no minimum — the CI floor lane's boot proof carries the floor)"
else
  FLOOR_NOTE="${CUR_FLOOR:-unset} (unchanged; upstream declares no engines.node — transitive constraints are invisible to this read, so the CI floor lane's boot proof carries the floor)"
fi

# --- Write the new bundle + rewrite the marker ------------------------------
log "Bundle changed — updating $VENDORED_PATH and the marker…"
cp "$SRC_BUNDLE" "$BUNDLE"

# Record the registry's reported dist.tarball; fall back to the canonical URL
# shape only if the registry omitted it (it never should for a published version).
UNSCOPED="${NAME##*/}"
TARBALL_URL="${REG_TARBALL:-https://registry.npmjs.org/${NAME}/-/${UNSCOPED}-${VERSION}.tgz}"
DATE_VENDORED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n \
  --arg name "$NAME" \
  --arg version "$VERSION" \
  --arg tarball_sha256 "$TARBALL_SHA" \
  --arg tarball_shasum "$TARBALL_SHA1" \
  --arg bundle_sha256 "$NEW_BUNDLE_SHA" \
  --arg date_vendored "$DATE_VENDORED" \
  --arg tarball_url "$TARBALL_URL" \
  --arg tarball_integrity "$REG_INTEGRITY" \
  --arg signature_status "$SIG_STATUS" \
  --arg signature_method "npm audit signatures" \
  --arg signature_note "$SIG_NOTE" \
  --arg bundle_source_path "$BUNDLE_SRC_PATH" \
  --arg vendored_path "$VENDORED_PATH" \
  --argjson self_contained "$SELF_CONTAINED" \
  '{
    name: $name,
    version: $version,
    tarball_sha256: $tarball_sha256,
    tarball_shasum: $tarball_shasum,
    bundle_sha256: $bundle_sha256,
    date_vendored: $date_vendored,
    tarball_url: $tarball_url,
    tarball_integrity: $tarball_integrity,
    signature_status: $signature_status,
    signature_method: $signature_method,
    bundle_source_path: $bundle_source_path,
    vendored_path: $vendored_path,
    self_contained: $self_contained
  }
  + (if $signature_note == "" then {} else {signature_note: $signature_note} end)' > "$MARKER.tmp"
mv "$MARKER.tmp" "$MARKER"

# --- Result summary (stdout) ------------------------------------------------
short() { printf '%.12s…' "$1"; }
printf 'Re-vendored %s\n' "$NAME"
printf '  version:   %s → %s\n' "$PINNED_VERSION" "$VERSION"
printf '  bundle:    %s → %s\n' "$(short "${OLD_BUNDLE_SHA:-none}")" "$(short "$NEW_BUNDLE_SHA")"
printf '  tarball:   %s\n' "$(short "$TARBALL_SHA")"
printf '  provenance: integrity ✓ (SHA-512 SRI + SHA-1 match registry); signature %s\n' "$SIG_STATUS"
printf '  node floor: %s\n' "$FLOOR_NOTE"
printf '  marker:    %s\n' "$VENDORED_PATH (vendored.json updated)"
printf '\n'
printf 'Next steps (NOT done for you):\n'
printf '  1. Run the offline-boot verification before committing:\n'
printf '       scripts/test.sh tests/integration/offline-boot.test.sh\n'
printf '     (CI also boots the bundle on the pinned Node floor — vendor/ynab-mcp/NODE_VERSION.)\n'
printf '  2. Review the diff, then commit manually (no auto-commit).\n'
