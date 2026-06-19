#!/usr/bin/env bash
#
# verify-bundle.sh — integrity check for the vendored YNAB MCP artifact.
#
# Asserts that the committed bundle still matches the provenance recorded in
# vendored.json and that the entrypoint shim is present and executable. This is
# the regression guard for the vendored artifact: the bundle is the FROZEN copy
# of record, so any hand-edit (or a marker that drifts from the file) must fail
# loudly here.
#
# Offline by design — no node, no network. Pure file + hash checks using `jq`
# and `shasum`, both already plugin prerequisites. This is intentionally NOT:
#   - the re-vendor script (M1-4), which fetches and freezes a NEW version, nor
#   - the offline-boot proof (M1-7), which actually launches the MCP server.
# It only proves the on-disk copy of record has not drifted from its marker.
#
# Exit 0 = all checks pass. Exit 1 = a check failed.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
marker="$here/vendored.json"
bundle="$here/index.cjs"
shim="$here/../../bin/ynab-mcp"

fail() { printf '  ✗ %s\n' "$1" >&2; exit 1; }
pass() { printf '  ✓ %s\n' "$1"; }

echo "Verifying vendored YNAB MCP bundle…"

# 1. Marker, bundle, and shim all present.
[ -f "$marker" ] || fail "missing marker: vendored.json"
[ -f "$bundle" ] || fail "missing bundle: index.cjs"
[ -f "$shim" ]   || fail "missing shim: bin/ynab-mcp"
pass "marker, bundle, and shim are present"

# 2. Committed bundle SHA-256 matches the marker's recorded bundle_sha256.
recorded="$(jq -r '.bundle_sha256' "$marker")"
actual="$(shasum -a 256 "$bundle" | awk '{print $1}')"
[ -n "$recorded" ] && [ "$recorded" != "null" ] || fail "vendored.json has no bundle_sha256"
[ "$recorded" = "$actual" ] \
  || fail "bundle SHA-256 drift — recorded $recorded but file is $actual"
pass "bundle SHA-256 matches vendored.json ($actual)"

# 3. Shim is executable.
[ -x "$shim" ] || fail "shim bin/ynab-mcp is not executable"
pass "shim bin/ynab-mcp is executable"

echo "OK — vendored bundle matches its recorded provenance."
