#!/usr/bin/env bash
#
# tests/unit/revendor.test.sh — covers bin/revendor.sh (the M1-4 re-vendor
# script, issue #11) with a MOCK npm so no network or real registry is touched.
#
# The AC-load-bearing paths are exercised:
#   * Idempotency — re-vendoring the already-pinned version, whose bundle bytes
#     are unchanged, must print a "no change" line, exit 0, and modify nothing.
#   * Changed bundle (the primary write path) — new bytes + a new version must
#     overwrite index.cjs, rewrite the marker (version, both hashes, the registry
#     SHA-1, the signature outcome, date), print an old → new summary to stdout,
#     and leave no vendored.json.tmp behind.
#   * Same version, different bytes — the headline "identity is the HASH" invariant:
#     a republished pinned version with new bytes must still write.
#   * Provenance gate (GAP-2 / #5) — the registry integrity + signature checks:
#     - a SHA-512 SRI that disagrees with the registry aborts BEFORE extraction,
#       leaving the bundle and marker untouched;
#     - a SHA-1 shasum that disagrees with the registry aborts the same way;
#     - a MISSING registry signature is recorded as a residual supply-chain risk
#       (signature_status=unavailable + signature_note), never skipped silently;
#     - an INVALID registry signature is a hard stop before the bundle is written.
#   * npm non-JSON stdout — `pack` (and `npm view`) exit 0 but emit noise; the script
#     must hard-error with an actionable message, not a raw jq parse failure.
#   * Prereq failure — with a required tool (`npm`, or the provenance gate's
#     `openssl`) absent from $PATH the script must hard-error (non-zero) and name
#     the missing prerequisite, rather than failing obscurely half-way through.
#
# The mock `npm` covers the four subcommands the script now drives — `pack --json`
# (packs MOCK_BUNDLE_SRC and records the tarball's REAL hashes so `view`/`install`
# can echo registry-matching values), `view … --json` (returns
# dist.integrity/shasum/tarball, overridable via MOCK_REG_* to force a mismatch,
# MOCK_VIEW_NONJSON to emit non-JSON noise, or MOCK_VIEW_FAIL to exit non-zero),
# `install` (writes a package-lock.json recording the packed tarball's real SRI,
# overridable via MOCK_LOCK_INTEGRITY to simulate a divergent second fetch), and
# `audit signatures --json` (MOCK_SIG_STATUS ∈ verified|missing|invalid). A stub
# `node` exists only so the prereq check's `command -v node` passes; a transparent
# `tar` wrapper logs every invocation to state/tar.log (pinning the gate's
# before-extraction ordering) then delegates to the real tar. Real
# jq/shasum/openssl come from $PATH. Zero third-party deps — pure bash + the
# assert lib (see docs/testing.md).
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/tests/lib/assert.sh"

REVENDOR_SRC="$ROOT/bin/revendor.sh"
MARKER_SRC="$ROOT/vendor/ynab-mcp/vendored.json"
BUNDLE_SRC="$ROOT/vendor/ynab-mcp/index.cjs"
FLOOR_SRC="$ROOT/vendor/ynab-mcp/NODE_VERSION"
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
  cp "$FLOOR_SRC" "$sb/vendor/ynab-mcp/NODE_VERSION"
  printf '%s' "$sb"
}

# Write a mock `npm` + stub `node` into <sandbox>/mockbin and echo that dir.
# The mock drives all four subcommands the script now uses. pack records the
# REAL hashes of the tarball it builds into <mockbin>/state, so the `view` mock
# can echo registry-matching values by default (the integrity-gate PASS path);
# set MOCK_REG_INTEGRITY / MOCK_REG_SHASUM to force a mismatch.
make_mockbin() {
  local dir="$1/mockbin"
  mkdir -p "$dir/state"
  cat > "$dir/npm" <<'NPM'
#!/usr/bin/env bash
set -euo pipefail
MOCKBIN="$(cd "$(dirname "$0")" && pwd)"
STATE="$MOCKBIN/state"
case "${1:-}" in
  pack)
    # Assert the real invocation shape (bin/revendor.sh): `npm pack --json <spec>`.
    # Dropping --json would make real npm emit non-JSON and the script's jq choke,
    # so the mock fails loudly if the contract regresses.
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
    # Record this tarball's REAL hashes so `view`/`install` can return
    # registry-matching values (the integrity gate's PASS path) without the mock
    # invocations having to know each other's temp paths — and so the marker
    # tests can VALUE-assert tarball_sha256 instead of length-checking it.
    printf 'sha512-%s' "$(openssl dgst -sha512 -binary "$PWD/$file" | openssl base64 -A)" > "$STATE/integrity"
    shasum -a 1 "$PWD/$file" | awk '{print $1}' > "$STATE/shasum"
    shasum -a 256 "$PWD/$file" | awk '{print $1}' > "$STATE/sha256"
    printf '[{"filename":"%s","integrity":"%s"}]\n' "$file" "$(cat "$STATE/integrity")"
    ;;
  view)
    # `npm view <spec> --json dist.integrity dist.shasum dist.tarball`. Default to
    # the real hashes recorded by pack; MOCK_REG_* override to force a mismatch.
    # Production depends on --json here (bin/revendor.sh:144); drop it and real npm
    # emits non-JSON the script's jq chokes on — fail loudly if the contract regresses.
    [[ " $* " == *" --json "* ]] || { echo "mock npm: 'view' must pass --json, got: $*" >&2; exit 1; }
    # Production reads all three of these fields (bin/revendor.sh:144,159-161); drop
    # any one from the real call and the registry cross-check loses a term — fail
    # loudly so the contract is pinned, not just the --json flag.
    for f in dist.integrity dist.shasum dist.tarball; do
      [[ " $* " == *" $f "* ]] || { echo "mock npm: 'view' must request $f, got: $*" >&2; exit 1; }
    done
    # Pin the spec argument (bin/revendor.sh's `npm view "$SPEC" …`), matching the
    # pack branch's coverage: hardcoding a wrong package in the real call must go
    # red here, not ship green on a syntactically-plausible mock reply.
    if [ -n "${EXPECTED_SPEC:-}" ] && [ "${2:-}" != "$EXPECTED_SPEC" ]; then
      echo "mock npm: 'view' expected spec '$EXPECTED_SPEC', got: '${2:-}'" >&2; exit 1
    fi
    # Force a hard `npm view` failure (registry unreachable / npm error) to
    # exercise the fail-closed guard around the REG_META fetch — the script must
    # die with its own actionable message, surfacing npm's stderr diagnostics.
    if [ -n "${MOCK_VIEW_FAIL:-}" ]; then
      echo "npm error network request to https://registry.npmjs.org failed" >&2
      exit 1
    fi
    # Force a non-JSON payload on a clean exit 0 to exercise the script's view
    # shape-guard: a future npm/wrapper emitting noise must hard-error with an
    # actionable message, not a raw jq crash when the fields are indexed.
    if [ -n "${MOCK_VIEW_NONJSON:-}" ]; then
      printf 'npm warn: this is not the JSON you are looking for\n'
      exit 0
    fi
    integ="${MOCK_REG_INTEGRITY:-$(cat "$STATE/integrity" 2>/dev/null || true)}"
    sha="${MOCK_REG_SHASUM:-$(cat "$STATE/shasum" 2>/dev/null || true)}"
    printf '{"dist.integrity":"%s","dist.shasum":"%s","dist.tarball":"https://registry.npmjs.org/mock/-/mock.tgz"}\n' "$integ" "$sha"
    ;;
  install)
    # The script installs the package-under-audit into an isolated temp dir purely
    # so `audit signatures` has a tree to read; the mock need not actually install
    # anything. But --ignore-scripts is the script's single most security-load-bearing
    # flag: without it, `npm install` of a possibly-compromised package runs its
    # install hooks with full privileges during the very audit meant to catch
    # tampering (the isolated $SIGDIR scopes WHERE files land, not WHAT code runs).
    # Drop it from the real call (bin/revendor.sh:215) and the suite must go red —
    # so the mock fails loudly if the contract regresses.
    [[ " $* " == *" --ignore-scripts "* ]] || { echo "mock npm: 'install' must pass --ignore-scripts, got: $*" >&2; exit 1; }
    # Pin the spec argument, matching the pack branch's coverage: hardcoding a
    # wrong package in the audit install must go red here, not ship green.
    if [ -n "${EXPECTED_SPEC:-}" ] && [[ " $* " != *" $EXPECTED_SPEC "* ]]; then
      echo "mock npm: 'install' expected spec '$EXPECTED_SPEC', got: $*" >&2; exit 1
    fi
    # Production binds the signature audit to the packed tarball via the
    # lockfile-recorded integrity — emulate npm writing package-lock.json with
    # the integrity of what it installed (real npm enforces this with
    # EINTEGRITY). Defaults to the REAL SRI pack recorded (the bound PASS path);
    # MOCK_LOCK_INTEGRITY simulates a divergent second fetch.
    lockname="${MOCK_PKG_NAME:?mock npm install needs MOCK_PKG_NAME}"
    lockinteg="${MOCK_LOCK_INTEGRITY:-$(cat "$STATE/integrity" 2>/dev/null || true)}"
    printf '{"lockfileVersion":3,"packages":{"node_modules/%s":{"integrity":"%s"}}}\n' \
      "$lockname" "$lockinteg" > "$PWD/package-lock.json"
    exit 0
    ;;
  audit)
    [ "${2:-}" = "signatures" ] || { echo "mock npm: only 'audit signatures' supported, got: $*" >&2; exit 1; }
    # Production depends on --json here too (bin/revendor.sh:236); drop it and real
    # npm emits non-JSON — fail loudly if the contract regresses.
    [[ " $* " == *" --json "* ]] || { echo "mock npm: 'audit signatures' must pass --json, got: $*" >&2; exit 1; }
    name="${MOCK_PKG_NAME:?mock npm audit needs MOCK_PKG_NAME}"
    case "${MOCK_SIG_STATUS:-verified}" in
      verified) printf '{"invalid":[],"missing":[]}\n' ;;
      missing)  printf '{"invalid":[],"missing":[{"name":"%s","version":"0.0.0"}]}\n' "$name" ;;
      invalid)  printf '{"invalid":[{"name":"%s","version":"0.0.0"}],"missing":[]}\n' "$name" ;;
      # Malformed / unrecognized shapes — the fail-closed schema guard must reject
      # EVERY one of these (never stamp "verified"):
      #   notjson     — npm emitted non-JSON noise (old npm, a wrapper, a crash).
      #   nullshape   — keys present but null, the has()-only pre-check's blind spot.
      #   newcategory — a NEW failure array (e.g. "revoked") a future npm might add,
      #                 which a catch-all `else` would wave through to "verified".
      notjson)     printf 'npm warn: this is not the JSON you are looking for\n' ;;
      nullshape)   printf '{"invalid":null,"missing":null}\n' ;;
      newcategory) printf '{"invalid":[],"missing":[],"revoked":[{"name":"%s","version":"0.0.0"}]}\n' "$name" ;;
      *) echo "mock npm: bad MOCK_SIG_STATUS '${MOCK_SIG_STATUS:-}'" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "mock npm: unsupported subcommand: $*" >&2; exit 1
    ;;
esac
NPM
  cat > "$dir/node" <<'NODE'
#!/usr/bin/env bash
exit 0
NODE
  # Transparent tar wrapper: records every invocation's args to state/tar.log,
  # then delegates to the real tar. This is what lets the integrity-mismatch
  # tests assert extraction (`-xzf`) NEVER ran — pinning the gate's
  # before-extraction ORDERING, not just that the tracked files stayed
  # untouched (moving the gate after `tar -xzf` must go red). The success-path
  # test asserts `-xzf` IS logged, proving the wrapper intercepts extraction.
  local real_tar
  real_tar="$(command -v tar)"
  cat > "$dir/tar" <<TAR
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/state/tar.log"
exec "$real_tar" "\$@"
TAR
  chmod +x "$dir/npm" "$dir/node" "$dir/tar"
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
  # No version arg → the script defaults to the pinned version (bin/revendor.sh:90).
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
  local sb mockbin marker bundle newsrc name old_version new_version new_sha date_before out rc tsha tsha1
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
    MOCK_PKG_NAME="$name" \
    "$BASH_BIN" "$sb/bin/revendor.sh" "$new_version" 2>/dev/null)"
  rc=$?
  set -e

  assert_eq 0 "$rc" "changed-bundle re-vendor should exit 0"
  # (a) index.cjs overwritten with the new bytes
  assert_eq "$new_sha" "$(hash_of "$bundle")" "index.cjs must be overwritten with the new bundle bytes"
  # (b) marker rewritten: version, bundle hash, tarball hash, and date
  assert_eq "$new_version" "$(jq -r '.version' "$marker")" "marker version must be rewritten"
  assert_eq "$new_sha" "$(jq -r '.bundle_sha256' "$marker")" "marker bundle_sha256 must match the new bytes"
  # Value-assert tarball_sha256 against the SHA-256 the pack mock recorded for
  # the REAL tarball it built — a wrong-but-64-char digest must fail, matching
  # how the sibling tarball_integrity/tarball_shasum fields are compared.
  tsha="$(jq -r '.tarball_sha256' "$marker")"
  assert_eq "$(cat "$mockbin/state/sha256")" "$tsha" \
    "marker tarball_sha256 must equal the packed tarball's real SHA-256"
  # Value-assert tarball_url against the dist.tarball the view mock returns —
  # neutralizing the REG_TARBALL fallback (always synthesizing the URL instead
  # of recording the registry's) must fail this, since the synthesized shape
  # (…/${NAME}/-/…-${VERSION}.tgz) differs from the mock's recorded value.
  assert_eq "https://registry.npmjs.org/mock/-/mock.tgz" "$(jq -r '.tarball_url' "$marker")" \
    "marker tarball_url must record the registry's dist.tarball, not the synthesized fallback"
  # (b2) provenance fields: registry SHA-1 + verified signature outcome. Assert the
  # EXACT registry dist.shasum the pack mock recorded (view echoes it back), not a
  # 40-char length check — a wrong-but-40-char SHA-1 would pass a length probe but
  # fail this. Mirrors the tarball_integrity value assertion below.
  tsha1="$(jq -r '.tarball_shasum' "$marker")"
  assert_eq "$(cat "$mockbin/state/shasum")" "$tsha1" \
    "marker tarball_shasum must equal the registry dist.shasum SHA-1"
  # AC#4's chain-linking field: tarball_integrity must be the EXACT registry SRI —
  # the one value that links our copy to the registry-published artifact. Compare
  # to the real SRI the pack mock recorded (which view echoes back as
  # dist.integrity), not a length/non-empty check, so a regression blanking the
  # field (--arg tarball_integrity "") can't slip through green.
  assert_eq "$(cat "$mockbin/state/integrity")" "$(jq -r '.tarball_integrity' "$marker")" \
    "marker tarball_integrity must equal the registry dist.integrity SRI (AC#4)"
  assert_eq "verified" "$(jq -r '.signature_status' "$marker")" "marker signature_status must be 'verified'"
  assert_eq "npm audit signatures" "$(jq -r '.signature_method' "$marker")" "marker signature_method must be recorded"
  assert_eq "null" "$(jq -r '.signature_note // "null"' "$marker")" "verified status must carry NO residual-risk note"
  assert_eq false "$([ "$date_before" = "$(jq -r '.date_vendored' "$marker")" ] && echo true || echo false)" \
    "marker date_vendored must be rewritten"
  # (c) human-readable old → new summary on stdout
  assert_contains "$out" "Re-vendored" "summary header must print to stdout"
  assert_contains "$out" "$old_version → $new_version" "summary must show the old → new version"
  # (d) no marker temp stranded in the tracked vendor dir (guards the trap fix)
  if [ -e "$marker.tmp" ]; then
    fail "vendored.json.tmp must not remain in the vendor dir after a successful write"
  fi
  # (e) positive control for the tar-invocation log: the write path DOES extract,
  # so `-xzf` must be recorded — proving the wrapper intercepts extraction and
  # the mismatch tests' "no -xzf" assertions can't pass vacuously.
  assert_contains "$(cat "$mockbin/state/tar.log")" "-xzf" \
    "the success path must record a tar extraction in the invocation log"
  rm -rf "$sb"
}

# The headline invariant (bin/revendor.sh:36-38): identity is the artifact HASH,
# not the version string. Same PINNED version BUT different bundle bytes must
# still write — the one case that proves the hash half of the idempotency guard
# (bin/revendor.sh:196) matters. A regression dropping the bundle-hash term would
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
    MOCK_PKG_NAME="$name" \
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
# captured output), not a raw jq parse error mid-pipeline (bin/revendor.sh:113-120).
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

# Parity hardening for the registry-metadata fetch: if `npm view` exits 0 but emits
# non-JSON noise on stdout, the fail-closed shape guard must surface the actionable
# "did not return the expected JSON" message BEFORE the registry fields are indexed
# (bin/revendor.sh:154-158) — not a raw jq crash — and touch nothing. MOCK_VIEW_NONJSON
# forces that payload. Mirrors test_npm_non_json_stdout_errors (the pack path).
test_npm_view_non_json_aborts() {
  local sb mockbin marker bundle marker_before bundle_before out rc
  sb="$(make_sandbox)"
  mockbin="$(make_mockbin "$sb")"
  marker="$sb/vendor/ynab-mcp/vendored.json"
  bundle="$sb/vendor/ynab-mcp/index.cjs"
  marker_before="$(hash_of "$marker")"
  bundle_before="$(hash_of "$bundle")"

  set +e
  out="$(env PATH="$mockbin:$PATH" MOCK_BUNDLE_SRC="$bundle" MOCK_VIEW_NONJSON=1 \
    "$BASH_BIN" "$sb/bin/revendor.sh" 2>&1)"
  rc=$?
  set -e

  assert_eq 1 "$rc" "non-JSON npm view stdout must hard-error"
  assert_contains "$out" "expected JSON" "error must name the JSON-shape failure"
  assert_eq "$marker_before" "$(hash_of "$marker")" "marker must be untouched when view output is rejected"
  assert_eq "$bundle_before" "$(hash_of "$bundle")" "bundle must be untouched when view output is rejected"
  rm -rf "$sb"
}

# The `npm view` FAILURE branch (registry unreachable, npm error): the guard
# around the REG_META fetch must die with its own actionable message — and
# surface npm's stderr diagnostics — not fall through to a raw `set -e` abort.
# MOCK_VIEW_FAIL drives the mock's view case to a non-zero exit; removing the
# `if ! REG_META=…; then die; fi` guard loses the actionable message (the bare
# assignment still aborts under set -e, but silently), so this test pins the
# guard itself, not just the exit code.
test_npm_view_failure_aborts() {
  local sb mockbin marker bundle marker_before bundle_before out rc
  sb="$(make_sandbox)"
  mockbin="$(make_mockbin "$sb")"
  marker="$sb/vendor/ynab-mcp/vendored.json"
  bundle="$sb/vendor/ynab-mcp/index.cjs"
  marker_before="$(hash_of "$marker")"
  bundle_before="$(hash_of "$bundle")"

  set +e
  out="$(env PATH="$mockbin:$PATH" MOCK_BUNDLE_SRC="$bundle" MOCK_VIEW_FAIL=1 \
    "$BASH_BIN" "$sb/bin/revendor.sh" 2>&1)"
  rc=$?
  set -e

  assert_eq 1 "$rc" "a failing npm view must hard-error"
  assert_contains "$out" "npm view failed" "must die via the guard's actionable message, not a bare set -e abort"
  assert_contains "$out" "network request" "npm's own stderr diagnostics must be surfaced, not swallowed"
  assert_eq "$marker_before" "$(hash_of "$marker")" "marker must be untouched when npm view fails"
  assert_eq "$bundle_before" "$(hash_of "$bundle")" "bundle must be untouched when npm view fails"
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

# With openssl missing from $PATH (but every earlier prereq present) the script
# must hard-error at the openssl require and name it — the provenance gate's
# SHA-512 SRI can't be computed without it (bin/revendor.sh:75,167). Parallels
# test_prereq_missing_npm_errors for the prereq the provenance gate (#5) added.
test_prereq_missing_openssl_errors() {
  local sb noopenssl out rc t
  sb="$(make_sandbox)"
  noopenssl="$sb/noopenssl"
  mkdir -p "$noopenssl"
  # Stub every prereq the script checks BEFORE openssl (node, npm, jq, shasum, tar)
  # so the require chain reaches — and dies at — the openssl check. They are never
  # executed: the script exits at `require openssl` before using any of them.
  for t in node npm jq shasum tar; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$noopenssl/$t"
    chmod +x "$noopenssl/$t"
  done

  set +e
  out="$(env PATH="$noopenssl" "$BASH_BIN" "$sb/bin/revendor.sh" 2>&1)"
  rc=$?
  set -e

  assert_eq 1 "$rc" "missing openssl should exit non-zero"
  assert_contains "$out" "openssl" "error must name the missing prerequisite"
  rm -rf "$sb"
}

# Provenance gate (GAP-2 / #5): a registry dist.integrity that disagrees with the
# downloaded tarball's computed SHA-512 SRI must abort BEFORE extraction — the
# bundle and marker stay untouched. MOCK_REG_INTEGRITY forces the mismatch.
test_integrity_sri_mismatch_aborts_before_extraction() {
  local sb mockbin marker bundle marker_before bundle_before out rc
  sb="$(make_sandbox)"
  mockbin="$(make_mockbin "$sb")"
  marker="$sb/vendor/ynab-mcp/vendored.json"
  bundle="$sb/vendor/ynab-mcp/index.cjs"
  marker_before="$(hash_of "$marker")"
  bundle_before="$(hash_of "$bundle")"

  set +e
  out="$(env PATH="$mockbin:$PATH" MOCK_BUNDLE_SRC="$bundle" \
    MOCK_REG_INTEGRITY="sha512-TAMPEREDtamperedTAMPEREDtamperedTAMPEREDtamperedTAMPEREDtamperedTAMPEREDtampered==" \
    "$BASH_BIN" "$sb/bin/revendor.sh" 2>&1)"
  rc=$?
  set -e

  assert_eq 1 "$rc" "an SRI that disagrees with the registry must hard-error"
  assert_contains "$out" "SHA-512 SRI mismatch" "error must name the SRI mismatch"
  assert_contains "$out" "refusing to extract" "error must state extraction was refused"
  assert_eq "$marker_before" "$(hash_of "$marker")" "marker must be untouched on an integrity abort"
  assert_eq "$bundle_before" "$(hash_of "$bundle")" "bundle must be untouched on an integrity abort"
  # ORDERING pin: "aborts BEFORE extraction" must mean tar never extracted —
  # moving the integrity gate after `tar -xzf` leaves the tracked files
  # untouched (the extract dir is a temp) yet must still go red here.
  if grep -q -- '-xzf' "$mockbin/state/tar.log" 2>/dev/null; then
    fail "tar extraction ran despite the integrity mismatch — the gate must fire BEFORE extraction"
  fi
  rm -rf "$sb"
}

# The SHA-1 half of the integrity gate: a dist.shasum that disagrees with the
# downloaded tarball must abort the same way (before extraction, nothing written).
test_integrity_shasum_mismatch_aborts_before_extraction() {
  local sb mockbin marker bundle marker_before bundle_before out rc
  sb="$(make_sandbox)"
  mockbin="$(make_mockbin "$sb")"
  marker="$sb/vendor/ynab-mcp/vendored.json"
  bundle="$sb/vendor/ynab-mcp/index.cjs"
  marker_before="$(hash_of "$marker")"
  bundle_before="$(hash_of "$bundle")"

  set +e
  out="$(env PATH="$mockbin:$PATH" MOCK_BUNDLE_SRC="$bundle" \
    MOCK_REG_SHASUM="0000000000000000000000000000000000000000" \
    "$BASH_BIN" "$sb/bin/revendor.sh" 2>&1)"
  rc=$?
  set -e

  assert_eq 1 "$rc" "a shasum that disagrees with the registry must hard-error"
  assert_contains "$out" "SHA-1 shasum mismatch" "error must name the shasum mismatch"
  assert_contains "$out" "refusing to extract" "error must state extraction was refused (before-extraction semantic, proven by message)"
  assert_eq "$marker_before" "$(hash_of "$marker")" "marker must be untouched on a shasum abort"
  assert_eq "$bundle_before" "$(hash_of "$bundle")" "bundle must be untouched on a shasum abort"
  # Same ORDERING pin as the SRI test: a mismatch must abort before any tar
  # extraction is even attempted, not merely leave the tracked files untouched.
  if grep -q -- '-xzf' "$mockbin/state/tar.log" 2>/dev/null; then
    fail "tar extraction ran despite the shasum mismatch — the gate must fire BEFORE extraction"
  fi
  rm -rf "$sb"
}

# A MISSING registry signature is recorded as a residual supply-chain risk, never
# skipped silently: the write still happens, with signature_status=unavailable and
# a non-empty signature_note in the marker.
test_signature_missing_records_residual_risk() {
  local sb mockbin marker bundle newsrc name new_version out rc
  sb="$(make_sandbox)"
  mockbin="$(make_mockbin "$sb")"
  marker="$sb/vendor/ynab-mcp/vendored.json"
  bundle="$sb/vendor/ynab-mcp/index.cjs"
  name="$(jq -r '.name' "$marker")"
  new_version="9.9.9-nosig"
  newsrc="$sb/new-index.cjs"
  printf 'missing-sig-bytes %s\n' "$(date +%s)-$RANDOM" > "$newsrc"

  set +e
  out="$(env PATH="$mockbin:$PATH" MOCK_BUNDLE_SRC="$newsrc" EXPECTED_SPEC="$name@$new_version" \
    MOCK_PKG_NAME="$name" MOCK_SIG_STATUS="missing" \
    "$BASH_BIN" "$sb/bin/revendor.sh" "$new_version" 2>/dev/null)"
  rc=$?
  set -e

  assert_eq 0 "$rc" "a missing signature must NOT abort — it is a recorded risk"
  assert_eq "unavailable" "$(jq -r '.signature_status' "$marker")" "signature_status must be 'unavailable'"
  assert_eq false "$([ -z "$(jq -r '.signature_note // ""' "$marker")" ] && echo true || echo false)" \
    "a residual-risk note must be recorded when the signature is unavailable"
  rm -rf "$sb"
}

# An INVALID registry signature is a hard stop (possible tampering) — and it must
# fire BEFORE the bundle is written, so index.cjs and the marker stay untouched.
test_signature_invalid_aborts_before_write() {
  local sb mockbin marker bundle newsrc name new_version marker_before bundle_before out rc
  sb="$(make_sandbox)"
  mockbin="$(make_mockbin "$sb")"
  marker="$sb/vendor/ynab-mcp/vendored.json"
  bundle="$sb/vendor/ynab-mcp/index.cjs"
  name="$(jq -r '.name' "$marker")"
  new_version="9.9.9-badsig"
  newsrc="$sb/new-index.cjs"
  printf 'invalid-sig-bytes %s\n' "$(date +%s)-$RANDOM" > "$newsrc"
  marker_before="$(hash_of "$marker")"
  bundle_before="$(hash_of "$bundle")"

  set +e
  out="$(env PATH="$mockbin:$PATH" MOCK_BUNDLE_SRC="$newsrc" EXPECTED_SPEC="$name@$new_version" \
    MOCK_PKG_NAME="$name" MOCK_SIG_STATUS="invalid" \
    "$BASH_BIN" "$sb/bin/revendor.sh" "$new_version" 2>&1)"
  rc=$?
  set -e

  assert_eq 1 "$rc" "an invalid registry signature must hard-error"
  assert_contains "$out" "INVALID" "error must flag the invalid signature"
  assert_eq "$marker_before" "$(hash_of "$marker")" "marker must be untouched on an invalid-signature abort"
  assert_eq "$bundle_before" "$(hash_of "$bundle")" "bundle must be untouched on an invalid-signature abort"
  rm -rf "$sb"
}

# Fail-closed signature gate: the gate must NEVER stamp "verified" on an audit
# shape it doesn't fully recognize. Shared driver — runs the write path (new
# version + new bytes, so the signature gate is actually reached) with a given
# malformed MOCK_SIG_STATUS and asserts the script aborts (rc 1) having written
# NOTHING: index.cjs and the marker stay byte-identical to before. Helpers aren't
# named test_* so run_tests won't pick this up directly.
assert_sig_shape_aborts() {
  local mock_status="$1" sb mockbin marker bundle newsrc name new_version marker_before bundle_before out rc
  sb="$(make_sandbox)"
  mockbin="$(make_mockbin "$sb")"
  marker="$sb/vendor/ynab-mcp/vendored.json"
  bundle="$sb/vendor/ynab-mcp/index.cjs"
  name="$(jq -r '.name' "$marker")"
  new_version="9.9.9-$mock_status"
  newsrc="$sb/new-index.cjs"
  printf '%s-bytes %s\n' "$mock_status" "$(date +%s)-$RANDOM" > "$newsrc"
  marker_before="$(hash_of "$marker")"
  bundle_before="$(hash_of "$bundle")"

  set +e
  out="$(env PATH="$mockbin:$PATH" MOCK_BUNDLE_SRC="$newsrc" EXPECTED_SPEC="$name@$new_version" \
    MOCK_PKG_NAME="$name" MOCK_SIG_STATUS="$mock_status" \
    "$BASH_BIN" "$sb/bin/revendor.sh" "$new_version" 2>&1)"
  rc=$?
  set -e

  assert_eq 1 "$rc" "MOCK_SIG_STATUS=$mock_status: an unrecognized audit shape must hard-error"
  assert_contains "$out" "signature verification did not run" "must abort via the fail-closed guard, not stamp a status"
  assert_eq "$marker_before" "$(hash_of "$marker")" "marker must be untouched when the audit shape is rejected"
  assert_eq "$bundle_before" "$(hash_of "$bundle")" "bundle must be untouched when the audit shape is rejected"
  rm -rf "$sb"
}

# Non-JSON audit output → the gate's parse-guard aborts, writing nothing.
test_signature_non_json_aborts_before_write() { assert_sig_shape_aborts notjson; }

# {"invalid":null,"missing":null} cleared the OLD has()-only pre-check yet both
# length probes returned 0 → a FALSE "verified". The array-type guard must reject
# it. (Regression test for the fail-open fix.)
test_signature_null_shape_aborts_before_write() { assert_sig_shape_aborts nullshape; }

# A NEW failure category (e.g. "revoked") listing our package must NOT fall
# through to "verified" — the unknown-key guard fails closed. (Regression test
# for the fail-open fix.)
test_signature_unknown_category_aborts_before_write() { assert_sig_shape_aborts newcategory; }

# --- Node floor policy (issue #3, decided on PR #205) ------------------------
# The floor is a POLICY value — the latest Node LTS major at (re)vendor time,
# pinned in vendor/ynab-mcp/NODE_VERSION and bumped by a HUMAN. An earlier
# revision derived it here from the incoming package's engines.node; the
# shell semver parser kept sprouting operator corner cases (three review
# rounds' worth), so the derivation was removed in favor of the policy. This
# test pins both halves of that contract: the script never touches the floor
# file, and the summary + next steps carry the reminder that replaced the
# automation.
test_floor_never_modified_by_revendor() {
  local sb mockbin marker name newsrc floor_before out rc
  sb="$(make_sandbox)"
  mockbin="$(make_mockbin "$sb")"
  marker="$sb/vendor/ynab-mcp/vendored.json"
  name="$(jq -r '.name' "$marker")"
  newsrc="$sb/new-index.cjs"
  printf 'changed-bundle-bytes %s\n' "$(date +%s)-$RANDOM" > "$newsrc"
  floor_before="$(cat "$sb/vendor/ynab-mcp/NODE_VERSION")"

  set +e
  out="$(env PATH="$mockbin:$PATH" MOCK_BUNDLE_SRC="$newsrc" \
    EXPECTED_SPEC="$name@9.9.9-test" MOCK_PKG_NAME="$name" \
    "$BASH_BIN" "$sb/bin/revendor.sh" "9.9.9-test" 2>/dev/null)"
  rc=$?
  set -e

  assert_eq 0 "$rc" "changed-bundle re-vendor should exit 0"
  # The write path ran (new bytes adopted) yet the floor file is byte-identical:
  # no derivation, no auto-raise, regardless of upstream metadata.
  assert_eq "$floor_before" "$(cat "$sb/vendor/ynab-mcp/NODE_VERSION")" \
    "NODE_VERSION must be byte-identical after a re-vendor (the floor is policy, not derived)"
  assert_contains "$out" "node floor:" \
    "the summary must still report the pinned floor"
  assert_contains "$out" "latest Node LTS" \
    "the summary must name the latest-LTS policy"
  assert_contains "$out" "update vendor/ynab-mcp/NODE_VERSION" \
    "the next steps must carry the manual-bump reminder that replaced the automation"
  rm -rf "$sb"
}

# Signature-audit BINDING: the audited install's lockfile-recorded integrity
# must equal the packed tarball's computed SRI, or the run dies without writing
# — a signature verdict earned by a divergent second fetch must never be
# stamped onto the committed bytes. MOCK_LOCK_INTEGRITY simulates the registry
# serving different bytes to the audit install than to `npm pack`; removing the
# binding check lets this run complete (the mock audit says verified), so the
# rc-1 assertion kills that mutation.
test_signature_audit_bound_to_packed_tarball() {
  local sb mockbin marker bundle newsrc name new_version marker_before bundle_before out rc
  sb="$(make_sandbox)"
  mockbin="$(make_mockbin "$sb")"
  marker="$sb/vendor/ynab-mcp/vendored.json"
  bundle="$sb/vendor/ynab-mcp/index.cjs"
  name="$(jq -r '.name' "$marker")"
  new_version="9.9.9-unbound"
  newsrc="$sb/new-index.cjs"
  printf 'divergent-audit-bytes %s\n' "$(date +%s)-$RANDOM" > "$newsrc"
  marker_before="$(hash_of "$marker")"
  bundle_before="$(hash_of "$bundle")"

  set +e
  out="$(env PATH="$mockbin:$PATH" MOCK_BUNDLE_SRC="$newsrc" EXPECTED_SPEC="$name@$new_version" \
    MOCK_PKG_NAME="$name" \
    MOCK_LOCK_INTEGRITY="sha512-DIVERGENTsecondFETCHdivergentSECONDfetchDIVERGENTsecondFETCHdivergentSECONDfe==" \
    "$BASH_BIN" "$sb/bin/revendor.sh" "$new_version" 2>&1)"
  rc=$?
  set -e

  assert_eq 1 "$rc" "an audit install that is not the packed tarball must hard-error"
  assert_contains "$out" "not the packed tarball" "error must name the binding failure"
  assert_eq "$marker_before" "$(hash_of "$marker")" "marker must be untouched on a binding abort"
  assert_eq "$bundle_before" "$(hash_of "$bundle")" "bundle must be untouched on a binding abort"
  rm -rf "$sb"
}

run_tests
