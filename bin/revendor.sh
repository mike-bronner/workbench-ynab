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
#   2. Extracts dist/bundle/index.cjs and overwrites vendor/ynab-mcp/index.cjs.
#   3. Recomputes the upstream tarball + vendored-bundle SHA-256 and rewrites the
#      version marker (vendored.json) — package, version, both hashes, today's
#      date, provenance URL + integrity.
#   4. Prints a human-readable old → new diff summary and reminds the operator to
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

[ -f "$MARKER" ] || die "version marker not found: $MARKER (was M1-3 vendoring run?)"

# --- Resolve target version + provenance from the marker --------------------
NAME="$(jq -r '.name' "$MARKER")"
[ -n "$NAME" ] && [ "$NAME" != "null" ] || die "vendored.json has no .name"

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
TARBALL_INTEGRITY="$(jq -r '.[0].integrity // ""' "$TMP/pack.json")"
TARBALL="$TMP/$TARBALL_FILE"
[ -f "$TARBALL" ] || die "npm pack reported '$TARBALL_FILE' but it is not in $TMP"

TARBALL_SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"

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
if [ "$VERSION" = "$PINNED_VERSION" ] && [ "$NEW_BUNDLE_SHA" = "$OLD_BUNDLE_SHA" ]; then
  printf 'No change: %s is already vendored (bundle %s).\n' "$SPEC" "$NEW_BUNDLE_SHA"
  printf 'Nothing was modified.\n'
  exit 0
fi

# --- Write the new bundle + rewrite the marker ------------------------------
log "Bundle changed — updating $VENDORED_PATH and the marker…"
cp "$SRC_BUNDLE" "$BUNDLE"

UNSCOPED="${NAME##*/}"
TARBALL_URL="https://registry.npmjs.org/${NAME}/-/${UNSCOPED}-${VERSION}.tgz"
DATE_VENDORED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n \
  --arg name "$NAME" \
  --arg version "$VERSION" \
  --arg tarball_sha256 "$TARBALL_SHA" \
  --arg bundle_sha256 "$NEW_BUNDLE_SHA" \
  --arg date_vendored "$DATE_VENDORED" \
  --arg tarball_url "$TARBALL_URL" \
  --arg tarball_integrity "$TARBALL_INTEGRITY" \
  --arg bundle_source_path "$BUNDLE_SRC_PATH" \
  --arg vendored_path "$VENDORED_PATH" \
  --argjson self_contained "$SELF_CONTAINED" \
  '{
    name: $name,
    version: $version,
    tarball_sha256: $tarball_sha256,
    bundle_sha256: $bundle_sha256,
    date_vendored: $date_vendored,
    tarball_url: $tarball_url,
    tarball_integrity: $tarball_integrity,
    bundle_source_path: $bundle_source_path,
    vendored_path: $vendored_path,
    self_contained: $self_contained
  }' > "$MARKER.tmp"
mv "$MARKER.tmp" "$MARKER"

# --- Result summary (stdout) ------------------------------------------------
short() { printf '%.12s…' "$1"; }
printf 'Re-vendored %s\n' "$NAME"
printf '  version:  %s → %s\n' "$PINNED_VERSION" "$VERSION"
printf '  bundle:   %s → %s\n' "$(short "${OLD_BUNDLE_SHA:-none}")" "$(short "$NEW_BUNDLE_SHA")"
printf '  tarball:  %s\n' "$(short "$TARBALL_SHA")"
printf '  marker:   %s\n' "$VENDORED_PATH (vendored.json updated)"
printf '\n'
printf 'Next steps (NOT done for you):\n'
printf '  1. Run the offline-boot verification before committing:\n'
printf '       scripts/test.sh tests/integration/offline-boot.test.sh\n'
printf '  2. Review the diff, then commit manually (no auto-commit).\n'
