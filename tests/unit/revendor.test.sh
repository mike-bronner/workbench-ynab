#!/usr/bin/env bash
#
# tests/unit/revendor.test.sh — covers bin/revendor.sh (the M1-4 re-vendor
# script, issue #11) with a MOCK npm so no network or real registry is touched.
#
# Two AC-load-bearing paths are exercised:
#   * Idempotency — re-vendoring the already-pinned version, whose bundle bytes
#     are unchanged, must print a "no change" line, exit 0, and modify nothing.
#   * Prereq failure — with `npm` absent from $PATH the script must hard-error
#     (non-zero) and name the missing prerequisite, rather than failing obscurely
#     half-way through.
#
# The mock `npm pack --json` packs MOCK_BUNDLE_SRC as package/dist/bundle/index.cjs
# and prints npm's --json shape; a stub `node` exists only so the prereq check's
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
[ "${1:-}" = "pack" ] || { echo "mock npm: only 'pack' supported, got: $*" >&2; exit 1; }
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
  local sb mockbin marker bundle marker_before bundle_before out rc
  sb="$(make_sandbox)"
  mockbin="$(make_mockbin "$sb")"
  marker="$sb/vendor/ynab-mcp/vendored.json"
  bundle="$sb/vendor/ynab-mcp/index.cjs"
  marker_before="$(hash_of "$marker")"
  bundle_before="$(hash_of "$bundle")"

  set +e
  out="$(env PATH="$mockbin:$PATH" MOCK_BUNDLE_SRC="$bundle" "$BASH_BIN" "$sb/bin/revendor.sh" 2>/dev/null)"
  rc=$?
  set -e

  assert_eq 0 "$rc" "idempotent re-vendor should exit 0"
  assert_contains "$out" "No change" "should report no change on stdout"
  assert_eq "$marker_before" "$(hash_of "$marker")" "marker must be untouched"
  assert_eq "$bundle_before" "$(hash_of "$bundle")" "bundle must be untouched"
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
