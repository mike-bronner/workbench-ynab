#!/usr/bin/env bash
#
# tests/unit/revendor.test.sh — covers bin/revendor.sh (the M1-4 re-vendor
# script, issue #11) with a MOCK npm so no network or real registry is touched.
#
# The AC-load-bearing paths are exercised:
#   * Idempotency — re-vendoring the already-pinned version, whose bundle bytes
#     are unchanged, must print a "no change" line, exit 0, and modify nothing.
#   * Changed bundle (the primary write path) — new bytes + a new version must
#     overwrite index.cjs, rewrite the marker (version, both hashes, date), print
#     an old → new summary to stdout, and leave no vendored.json.tmp behind.
#   * Same version, different bytes — the headline "identity is the HASH" invariant:
#     a republished pinned version with new bytes must still write.
#   * npm non-JSON stdout — pack exits 0 but emits noise; the script must hard-error
#     with an actionable message, not a raw jq parse failure.
#   * Prereq failure — with `npm` absent from $PATH the script must hard-error
#     (non-zero) and name the missing prerequisite, rather than failing obscurely
#     half-way through.
#
# The mock `npm pack --json` asserts the real call shape (pack + --json + the
# expected spec), packs MOCK_BUNDLE_SRC as package/dist/bundle/index.cjs, and
# prints npm's --json shape; a stub `node` exists only so the prereq check's
# `command -v node` passes. Real jq/shasum/tar come from $PATH. Zero third-party
# deps — pure bash + the assert lib (see docs/testing.md).
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/tests/lib/assert.sh"

REVENDOR_SRC="$ROOT/bin/revendor.sh"
MARKER_SRC="$ROOT/vendor/ynab-mcp/vendored.json"
BUNDLE_SRC="$ROOT/vendor/ynab-mcp/index.cjs"
BASH_BIN="$(command -v bash)"

# A sandbox repo mirroring the layout revendor.sh resolves against (it derives
# its root from its own location), so tests never mutate the real vendor tree.
make_sandbox() {
  local sb
  sb="$(mktemp -d "${TMPDIR:-/tmp}/revendor-test.XXXXXX")"
  mkdir -p "$sb/bin" "$sb/vendor/ynab-mcp"
  cp "$REVENDOR_SRC" "$sb/bin/revendor.sh"
  cp "$MARKER_SRC" "$sb/vendor/ynab-mcp/vendored.json"
  cp "$BUNDLE_SRC" "$sb/vendor/ynab-mcp/index.cjs"
  printf '%s' "$sb"
}

# Write a mock `npm` + stub `node` into <sandbox>/mockbin and echo that dir.
make_mockbin() {
  local dir="$1/mockbin"
  mkdir -p "$dir"
  cat > "$dir/npm" <<'NPM'
#!/usr/bin/env bash
set -euo pipefail
# Assert the real invocation shape (bin/revendor.sh:93): `npm pack --json <spec>`.
# Dropping --json would make real npm emit non-JSON and the script's jq choke, so
# the mock fails loudly if the contract regresses rather than passing silently.
[ "${1:-}" = "pack" ] || { echo "mock npm: only 'pack' supported, got: $*" >&2; exit 1; }
[ "${2:-}" = "--json" ] || { echo "mock npm: expected 'pack --json', got: $*" >&2; exit 1; }
if [ -n "${EXPECTED_SPEC:-}" ] && [ "${3:-}" != "$EXPECTED_SPEC" ]; then
  echo "mock npm: expected spec '$EXPECTED_SPEC', got: '${3:-}'" >&2; exit 1
fi
: "${MOCK_BUNDLE_SRC:?mock npm needs MOCK_BUNDLE_SRC}"
work="$(mktemp -d)"
mkdir -p "$work/package/dist/bundle"
cp "$MOCK_BUNDLE_SRC" "$work/package/dist/bundle/index.cjs"
file="mock-ynab-mcpb.tgz"
tar -czf "$PWD/$file" -C "$work" package
rm -rf "$work"
printf '[{"filename":"%s","integrity":"sha512-mockintegrity=="}]\n' "$file"
NPM
  cat > "$dir/node" <<'NODE'
#!/usr/bin/env bash
exit 0
NODE
  chmod +x "$dir/npm" "$dir/node"
  printf '%s' "$dir"
}

hash_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# Re-vendoring the pinned version with identical bundle bytes is a no-op.
test_idempotent_no_change() {
  local sb mockbin marker bundle marker_before bundle_before spec out rc
  sb="$(make_sandbox)"
  mockbin="$(make_mockbin "$sb")"
  marker="$sb/vendor/ynab-mcp/vendored.json"
  bundle="$sb/vendor/ynab-mcp/index.cjs"
  marker_before="$(hash_of "$marker")"
  bundle_before="$(hash_of "$bundle")"
  # No version arg → the script defaults to the pinned version (bin/revendor.sh:76).
  spec="$(jq -r '.name' "$marker")@$(jq -r '.version' "$marker")"

  set +e
  out="$(env PATH="$mockbin:$PATH" MOCK_BUNDLE_SRC="$bundle" EXPECTED_SPEC="$spec" \
    "$BASH_BIN" "$sb/bin/revendor.sh" 2>/dev/null)"
  rc=$?
  set -e

  assert_eq 0 "$rc" "idempotent re-vendor should exit 0"
  assert_contains "$out" "No change" "should report no change on stdout"
  assert_eq "$marker_before" "$(hash_of "$marker")" "marker must be untouched"
  assert_eq "$bundle_before" "$(hash_of "$bundle")" "bundle must be untouched"
  rm -rf "$sb"
}

# A CHANGED bundle (new bytes + a new version) drives the script's primary path:
# index.cjs overwritten, the marker rewritten (version, both hashes, today's
# date), an old → new summary on stdout, and — guarding the trap fix — NO
# vendored.json.tmp stranded in the tracked vendor dir afterward.
test_changed_bundle_updates_marker_and_bundle() {
  local sb mockbin marker bundle newsrc name old_version new_version new_sha date_before out rc tsha
  sb="$(make_sandbox)"
  mockbin="$(make_mockbin "$sb")"
  marker="$sb/vendor/ynab-mcp/vendored.json"
  bundle="$sb/vendor/ynab-mcp/index.cjs"
  new_version="9.9.9-test"
  name="$(jq -r '.name' "$marker")"
  # Read the pinned version from the marker BEFORE the run (the script rewrites
  # it), so the old → new assertion never hardcodes the value this tool exists to
  # change — re-vendoring to a real new version would otherwise break this test.
  old_version="$(jq -r '.version' "$marker")"
  date_before="$(jq -r '.date_vendored' "$marker")"

  # Bundle bytes that differ from the pinned vendored bundle, so the hash-keyed
  # idempotency check falls through to the write path instead of no-op'ing.
  newsrc="$sb/new-index.cjs"
  printf 'changed-bundle-bytes %s\n' "$(date +%s)-$RANDOM" > "$newsrc"
  new_sha="$(hash_of "$newsrc")"

  set +e
  out="$(env PATH="$mockbin:$PATH" MOCK_BUNDLE_SRC="$newsrc" EXPECTED_SPEC="$name@$new_version" \
    "$BASH_BIN" "$sb/bin/revendor.sh" "$new_version" 2>/dev/null)"
  rc=$?
  set -e

  assert_eq 0 "$rc" "changed-bundle re-vendor should exit 0"
  # (a) index.cjs overwritten with the new bytes
  assert_eq "$new_sha" "$(hash_of "$bundle")" "index.cjs must be overwritten with the new bundle bytes"
  # (b) marker rewritten: version, bundle hash, tarball hash, and date
  assert_eq "$new_version" "$(jq -r '.version' "$marker")" "marker version must be rewritten"
  assert_eq "$new_sha" "$(jq -r '.bundle_sha256' "$marker")" "marker bundle_sha256 must match the new bytes"
  tsha="$(jq -r '.tarball_sha256' "$marker")"
  assert_eq 64 "${#tsha}" "marker tarball_sha256 must be a 64-char SHA-256"
  assert_eq false "$([ "$date_before" = "$(jq -r '.date_vendored' "$marker")" ] && echo true || echo false)" \
    "marker date_vendored must be rewritten"
  # (c) human-readable old → new summary on stdout
  assert_contains "$out" "Re-vendored" "summary header must print to stdout"
  assert_contains "$out" "$old_version → $new_version" "summary must show the old → new version"
  # (d) no marker temp stranded in the tracked vendor dir (guards the trap fix)
  if [ -e "$marker.tmp" ]; then
    fail "vendored.json.tmp must not remain in the vendor dir after a successful write"
  fi
  rm -rf "$sb"
}

# The headline invariant (bin/revendor.sh:23-25): identity is the artifact HASH,
# not the version string. Same PINNED version BUT different bundle bytes must
# still write — the one case that proves the hash half of the idempotency guard
# (bin/revendor.sh:117) matters. A regression dropping the bundle-hash term would
# pass both the no-change and changed-version tests silently; this catches it.
test_same_version_different_bytes_writes() {
  local sb mockbin marker bundle newsrc name pinned new_sha out rc
  sb="$(make_sandbox)"
  mockbin="$(make_mockbin "$sb")"
  marker="$sb/vendor/ynab-mcp/vendored.json"
  bundle="$sb/vendor/ynab-mcp/index.cjs"
  name="$(jq -r '.name' "$marker")"
  pinned="$(jq -r '.version' "$marker")"

  # Same version (no version arg → defaults to pinned), but NEW bytes.
  newsrc="$sb/new-index.cjs"
  printf 'republished-same-version-new-bytes %s\n' "$(date +%s)-$RANDOM" > "$newsrc"
  new_sha="$(hash_of "$newsrc")"

  set +e
  out="$(env PATH="$mockbin:$PATH" MOCK_BUNDLE_SRC="$newsrc" EXPECTED_SPEC="$name@$pinned" \
    "$BASH_BIN" "$sb/bin/revendor.sh" 2>/dev/null)"
  rc=$?
  set -e

  assert_eq 0 "$rc" "same-version/changed-bytes re-vendor should exit 0"
  assert_eq "$new_sha" "$(hash_of "$bundle")" "index.cjs must be overwritten even though the version is unchanged"
  assert_eq "$new_sha" "$(jq -r '.bundle_sha256' "$marker")" "marker bundle_sha256 must track the new bytes"
  assert_eq "$pinned" "$(jq -r '.version' "$marker")" "version must stay the pinned value (only the bytes changed)"
  assert_contains "$out" "Re-vendored" "a write must print the summary, not the no-change line"
  rm -rf "$sb"
}

# Hardening: if npm pack exits 0 but emits non-JSON noise on stdout, the script
# must surface the actionable "did not return the expected JSON" message (and the
# captured output), not a raw jq parse error mid-pipeline (bin/revendor.sh:99-105).
test_npm_non_json_stdout_errors() {
  local sb dir out rc
  sb="$(make_sandbox)"
  dir="$sb/mockbin"
  mkdir -p "$dir"
  cat > "$dir/npm" <<'NPM'
#!/usr/bin/env bash
[ "${1:-}" = "pack" ] || exit 1
# Exit 0, but print noise instead of npm's --json array.
echo "npm warn: heads up, this line is not JSON"
exit 0
NPM
  cat > "$dir/node" <<'NODE'
#!/usr/bin/env bash
exit 0
NODE
  chmod +x "$dir/npm" "$dir/node"

  set +e
  out="$(env PATH="$dir:$PATH" "$BASH_BIN" "$sb/bin/revendor.sh" 2>&1)"
  rc=$?
  set -e

  assert_eq 1 "$rc" "non-JSON npm stdout must hard-error"
  assert_contains "$out" "expected JSON" "error must name the JSON-shape failure"
  rm -rf "$sb"
}

# With npm missing from $PATH the script must hard-error and name the prereq.
test_prereq_missing_npm_errors() {
  local sb nodeonly out rc
  sb="$(make_sandbox)"
  nodeonly="$sb/nodeonly"
  mkdir -p "$nodeonly"
  cat > "$nodeonly/node" <<'NODE'
#!/usr/bin/env bash
exit 0
NODE
  chmod +x "$nodeonly/node"

  set +e
  out="$(env PATH="$nodeonly" "$BASH_BIN" "$sb/bin/revendor.sh" 2>&1)"
  rc=$?
  set -e

  assert_eq 1 "$rc" "missing npm should exit non-zero"
  assert_contains "$out" "npm" "error must name the missing prerequisite"
  rm -rf "$sb"
}

run_tests
