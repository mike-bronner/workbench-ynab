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
# The guard's report is captured to a file, NOT a command substitution: bash
# silently drops NUL bytes from "$(...)", which would launder away the exact leak
# the sanitizer assertion below exists to detect. Kept outside $SANDBOX so it is
# never itself part of the scanned tree.
REPORT="$(mktemp)"
trap 'rm -rf "$SANDBOX" "$REPORT"' EXIT

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

# run_nul_case "<description>" <file-relative-to-sandbox> "<printf-format>" [args...]
# Like run_case, but the payload is a printf FORMAT string so it can carry a raw
# NUL via \000. run_case cannot: a bash variable cannot hold a NUL byte. Always
# asserts exit 1 — every one of these plants a real secret shape.
run_nul_case() {
  local desc="$1" file="$2" fmt="$3"
  shift 3
  reset_sandbox
  mkdir -p "$SANDBOX/$(dirname "$file")"
  # shellcheck disable=SC2059  # the format string IS the payload under test.
  printf "$fmt" "$@" > "$SANDBOX/$file"
  local actual=0
  ( cd "$SANDBOX" && bash bin/secret-scan.sh ) >/dev/null 2>&1 || actual=$?
  if [ "$actual" -eq 1 ]; then
    echo "  ✓ $desc (exit 1)"
    pass=$((pass + 1))
  else
    echo "  ✖ $desc — expected exit 1, got $actual"
    fail=$((fail + 1))
  fi
}

echo "Self-test: guard catches committed-secret shapes (exit 1)"
run_case "64-char-hex YNAB PAT shape is caught"         1 "src/leak.txt"  "token: $SYNTH_HEX"
run_case "bare cleartext token assignment is caught"    1 "src/run.sh"    "${ENV_NAME}=${SYNTH_HEX}"
run_case "double-quoted cleartext token is caught"      1 "src/run.sh"    "${ENV_NAME}=\"${SYNTH_HEX}\""
run_case "single-quoted cleartext token is caught"      1 "src/run.sh"    "${ENV_NAME}='${SYNTH_HEX}'"
run_case "PEM private-key header is caught"             1 "src/id_rsa"    "${BEGIN_FRAG} RSA ${KEY_FRAG}"

echo "Self-test: legitimate, non-secret content passes (exit 0)"
run_case "clean tree passes"                           0 ""              ""
# The launcher's real line — a \$VAR reference is not a leak and must NOT trip.
run_case "variable-reference export is not a leak"     0 "src/run.sh"    "export ${ENV_NAME}=\"\$TOKEN\""
run_case "bare env-var name mention is not a leak"     0 "docs/note.md"  "the launcher exports ${ENV_NAME}"
run_case "short hex string (< 64) is not a leak"       0 "src/hash.txt"  "abc123 ${HEX16}"

# vendor/ is relaxed for the HEX rule ONLY (vendored.json carries legitimate
# 64-char-hex SHA-256 digests). The cleartext-token and PEM rules still reach
# into vendor/ — the bundle is the repo's highest-risk supply-chain surface, so
# a token or key smuggled there must NOT escape the scan.
echo "Self-test: vendor/ exclusion is scoped to the hex rule only"
run_case "64-hex digest under vendor/ is ignored"      0 "vendor/x.json"  "\"sha256\": \"$SYNTH_HEX\""
run_case "cleartext token under vendor/ IS caught"     1 "vendor/run.sh"  "${ENV_NAME}=${SYNTH_HEX}"
run_case "PEM header under vendor/ IS caught"          1 "vendor/id_ec"   "${BEGIN_FRAG} EC ${KEY_FRAG}"

# A NUL byte anywhere in a file used to make grep classify the whole file as
# binary and skip it, so a credential inside it was invisible to this guard — the
# repo's only content-scanning CI gate (issue #255). It was not hypothetical:
# assets/allocate-handler.js carries a raw NUL as a cache-key separator, and the
# scanner was blind to every byte of it. The guard now greps --binary-files=text
# with no -I; these cases pin that, because restoring either flag turns all three
# red. The NUL sits on a DIFFERENT line from the secret on purpose — the skip was
# file-wide, so that is the realistic shape (and the shape allocate-handler.js
# has), not a NUL adjacent to the credential.
echo "Self-test: a NUL byte cannot hide a secret from the guard (any rule)"
run_nul_case "64-char-hex PAT shape in a NUL-carrying file is caught" \
  "src/nul-hex.js"  'const sep = "a\000b";\ntoken: %s\n' "$SYNTH_HEX"
run_nul_case "cleartext token in a NUL-carrying file is caught" \
  "src/nul-env.sh"  'sep="a\000b"\n%s=%s\n' "$ENV_NAME" "$SYNTH_HEX"
run_nul_case "PEM header in a NUL-carrying file is caught" \
  "src/nul-key.pem" 'sep = "a\000b"\n%s RSA %s\n' "$BEGIN_FRAG" "$KEY_FRAG"

# Scanning as text means grep prints the matched line VERBATIM, so a hit on a
# line carrying raw control bytes would spray them straight into stdout and CI
# logs. The guard renders every hit through a sanitizer; pin that the report
# stays printable text. Deliberately puts the control bytes on the SAME line as
# the secret — that is the only way they reach the printed hit.
echo "Self-test: a hit on a control-byte line is reported as printable text"
reset_sandbox
printf 'x\000\001\002\037 %s=%s\n' "$ENV_NAME" "$SYNTH_HEX" > "$SANDBOX/src/ctl-probe.sh"
ctl_rc=0
( cd "$SANDBOX" && bash bin/secret-scan.sh ) > "$REPORT" 2>&1 || ctl_rc=$?
# Delete everything the report is ALLOWED to contain — tab, newline, printable
# ASCII, and bytes >= 0x80 (the guard's own ✓/✖ emoji, and UTF-8 inside a real
# finding, which the sanitizer deliberately preserves). Whatever survives is a
# raw control byte that leaked. Counting bytes with tr/wc rather than matching
# with grep is deliberate: a NUL cannot be expressed in a bash-supplied pattern,
# so a grep-based check could never detect the very byte at issue here.
leaked=$(LC_ALL=C tr -d '\011\012\040-\176\200-\377' < "$REPORT" | wc -c | tr -d '[:space:]')
if [ "$ctl_rc" -ne 1 ]; then
  echo "  ✖ control-byte-carrying secret was not caught — expected exit 1, got $ctl_rc"
  fail=$((fail + 1))
elif [ "$leaked" -ne 0 ]; then
  echo "  ✖ report leaked $leaked raw control byte(s) to stdout/CI logs:"
  sed 's/^/    /' "$REPORT" | cat -v | head -5
  fail=$((fail + 1))
else
  echo "  ✓ secret is caught and the report contains only printable text"
  pass=$((pass + 1))
fi

echo
echo "Passed: $pass   Failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "✓ Secret-scan guard self-test green."
