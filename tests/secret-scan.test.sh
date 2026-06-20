#!/usr/bin/env bash
#
# secret-scan.test.sh — self-test for the committed-secret guard (issue #72).
#
# Self-contained: no test framework required. Run directly:
#   bash tests/secret-scan.test.sh
# Exits 0 if all assertions pass, 1 otherwise. Slots into the repo-wide
# entrypoint (scripts/test.sh) like the sibling check-tool-name-sources.test.sh.
#
# The guard (bin/secret-scan.sh) is the repo-level backstop that fails the build
# when a credential is committed. This file is the test for that guard, and it
# IS the AC6 "negative test": it proves a synthetic, token-SHAPED string (never a
# real credential) makes the scan exit non-zero — verified in a throwaway
# sandbox, so no token-shaped string is ever committed to main.
#
# Every synthetic secret is ASSEMBLED AT RUNTIME from harmless fragments, so this
# test file contains no literal 64-char-hex token, no cleartext YNAB_ACCESS_TOKEN
# assignment, and no full PEM header — it stays clean when the guard scans tests/.

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/../bin/secret-scan.sh"

# Build the matchable shapes without ever writing one literally here.
HEX16='deadbeefcafef00d'                       # 16 lowercase-hex chars
SYNTH_HEX="${HEX16}${HEX16}${HEX16}${HEX16}"   # 64 hex chars — the PAT shape
ENV_NAME='YNAB_ACCESS_TOKEN'                    # the env var (bare name is safe)
BEGIN_FRAG='-----BEGIN'                         # PEM fragments — neither alone
KEY_FRAG='PRIVATE KEY-----'                     #   matches the full header

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0
fail=0

# Lay down a minimal sandbox tree with the guard installed under bin/.
reset_sandbox() {
  rm -rf "$SANDBOX"
  mkdir -p "$SANDBOX/bin" "$SANDBOX/src" "$SANDBOX/vendor"
  cp "$GUARD" "$SANDBOX/bin/secret-scan.sh"
  chmod +x "$SANDBOX/bin/secret-scan.sh"
}

# run_case "<description>" <expected-exit> <file-relative-to-sandbox> "<content>"
run_case() {
  local desc="$1" expected="$2" file="$3" content="$4"
  reset_sandbox
  if [ -n "$file" ]; then
    mkdir -p "$SANDBOX/$(dirname "$file")"
    printf '%s\n' "$content" > "$SANDBOX/$file"
  fi
  local actual=0
  ( cd "$SANDBOX" && bash bin/secret-scan.sh ) >/dev/null 2>&1 || actual=$?
  if [ "$actual" -eq "$expected" ]; then
    echo "  ✓ $desc (exit $actual)"
    pass=$((pass + 1))
  else
    echo "  ✖ $desc — expected exit $expected, got $actual"
    fail=$((fail + 1))
  fi
}

echo "Self-test: guard catches committed-secret shapes (exit 1)"
run_case "64-char-hex YNAB PAT shape is caught"        1 "src/leak.txt"   "token: $SYNTH_HEX"
run_case "bare cleartext token assignment is caught"   1 "src/run.sh"     "${ENV_NAME}=${SYNTH_HEX}"
run_case "quoted cleartext token assignment is caught" 1 "src/run.sh"     "${ENV_NAME}=\"${SYNTH_HEX}\""
run_case "PEM private-key header is caught"            1 "src/id_rsa"     "${BEGIN_FRAG} RSA ${KEY_FRAG}"

echo "Self-test: legitimate, non-secret content passes (exit 0)"
run_case "clean tree passes"                           0 ""              ""
# The launcher's real line — a \$VAR reference is not a leak and must NOT trip.
run_case "variable-reference export is not a leak"     0 "src/run.sh"    "export ${ENV_NAME}=\"\$TOKEN\""
run_case "bare env-var name mention is not a leak"     0 "docs/note.md"  "the launcher exports ${ENV_NAME}"
run_case "short hex string (< 64) is not a leak"       0 "src/hash.txt"  "abc123 ${HEX16}"
# vendor/ carries legitimate SHA-256 digests and has its own integrity gate
# (verify-bundle.sh), so it is excluded from this scan by design.
run_case "64-hex digest under vendor/ is ignored"      0 "vendor/x.json" "\"sha256\": \"$SYNTH_HEX\""

echo
echo "Passed: $pass   Failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "✓ Secret-scan guard self-test green."
