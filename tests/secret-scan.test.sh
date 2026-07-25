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
# Holds the guard's captured report for the output-sanitization case below. It
# must live OUTSIDE the sandbox — the guard scans its own working tree, so a
# report file containing a synthetic secret would otherwise be scanned as tree
# content and confuse the very run it is recording.
REPORT=""
trap 'rm -rf "$SANDBOX" ${REPORT:+"$REPORT"}' EXIT

pass=0
fail=0

# Lay down a minimal sandbox tree with the guard installed under bin/.
reset_sandbox() {
  rm -rf "$SANDBOX"
  mkdir -p "$SANDBOX/bin" "$SANDBOX/src" "$SANDBOX/vendor"
  cp "$GUARD" "$SANDBOX/bin/secret-scan.sh"
  chmod +x "$SANDBOX/bin/secret-scan.sh"
}

# run_nul_case "<desc>" <expected-exit> <file> "<printf-fmt>" "<fmt-arg>"
#
# Same contract as run_case, except the file content is written from a printf
# FORMAT so it can embed a literal NUL via \000. run_case cannot carry this
# payload: a bash string silently drops NUL bytes, so routing it through a
# variable would plant a NUL-free file and the case would pass vacuously.
run_nul_case() {
  local desc="$1" expected="$2" file="$3" fmt="$4" arg="$5"
  reset_sandbox
  mkdir -p "$SANDBOX/$(dirname "$file")"
  # shellcheck disable=SC2059  # fmt is a trusted literal format carrying \000.
  printf "$fmt" "$arg" > "$SANDBOX/$file"
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

# A single NUL byte anywhere in a file used to make grep classify the WHOLE file
# as binary and skip it, hiding any credential in it from EVERY rule below — and
# this guard is the repo's only content-scanning CI gate (issue #255). The guard
# now scans with --binary-files=text and no -I; these cases pin that. Reverting
# the flag to --binary-files=without-match turns all three red (verified).
# Re-adding a bare -I does NOT, and should not be expected to: grep resolves
# binary handling last-flag-wins, so the later --binary-files=text still governs
# (measured on BSD grep). -I is dropped in the guard because depending on that
# ordering is fragile, not because it currently breaks anything — so there is no
# behavioral difference here for a test to pin.
# Each plants the NUL on the SAME line as the secret — the worst case,
# since the NUL must not break the match itself, only the binary classification.
echo "Self-test: a NUL byte cannot hide a secret from any rule"
run_nul_case "hex PAT shape beside a NUL is caught"       1 "src/leak.txt" 'lead\000ing token: %s\n' "$SYNTH_HEX"
run_nul_case "cleartext token beside a NUL is caught"     1 "src/run.sh"   "lead\\000ing ${ENV_NAME}=%s\\n"  "$SYNTH_HEX"
run_nul_case "PEM header beside a NUL is caught"          1 "src/id_rsa"   "lead\\000ing ${BEGIN_FRAG} RSA %s\\n" "$KEY_FRAG"

# The vendor/ scoping is orthogonal to the binary-classification fix, and must
# survive it: scanning as text must not start flagging the bundle's legitimate
# hex digests, nor stop catching a real token smuggled there behind a NUL.
echo "Self-test: NUL handling leaves the vendor/ hex scoping intact"
run_nul_case "64-hex digest beside a NUL under vendor/ stays ignored" 0 "vendor/x.json" '{"sha256": "\000%s"}\n' "$SYNTH_HEX"
run_nul_case "cleartext token beside a NUL under vendor/ IS caught"   1 "vendor/run.sh" "lead\\000ing ${ENV_NAME}=%s\\n" "$SYNTH_HEX"

# Scanning as text means grep prints the matched line verbatim, so a NUL sitting
# on that line reaches stdout raw unless the guard sanitizes it (it does, via
# sanitize_hits). Assert on BYTES, and never through a bash variable — command
# substitution drops NULs, so a variable-based check would report "clean" even
# with sanitization removed, i.e. pass vacuously. Deleting the sanitize_hits call
# from bin/secret-scan.sh turns this red.
echo "Self-test: a NUL-carrying hit is reported as text, never raw bytes"
reset_sandbox
REPORT="$(mktemp)"
mkdir -p "$SANDBOX/src"
printf "lead\\000ing ${ENV_NAME}=%s tail\\n" "$SYNTH_HEX" > "$SANDBOX/src/nul-report.sh"
report_rc=0
( cd "$SANDBOX" && bash bin/secret-scan.sh ) > "$REPORT" 2>&1 || report_rc=$?
# Delete tab, newline, printable ASCII, and every high byte (the guard's own
# UTF-8 message glyphs, which are legitimate and NOT sanitized). What survives is
# exactly the C0 control set plus DEL — i.e. raw bytes leaked out of a scanned
# file. Any count above zero is the leak this case exists to catch.
raw_bytes="$(LC_ALL=C tr -d '\11\12\40-\176\200-\377' < "$REPORT" | wc -c | tr -d ' ')"
# The NUL must be RENDERED, not merely dropped: the hit has to stay readable and
# actionable. Pin the substituted form, so replacing sanitize_hits with something
# that silently deletes the byte (or the whole line) also fails here.
if [ "$report_rc" -eq 1 ] && [ "$raw_bytes" -eq 0 ] && grep -q 'lead?ing' "$REPORT"; then
  echo "  ✓ hit reported (exit 1), NUL rendered as '?', 0 raw control bytes"
  pass=$((pass + 1))
else
  echo "  ✖ expected exit 1, a 'lead?ing' hit, and 0 raw control bytes —" \
       "got exit $report_rc, $raw_bytes control byte(s)"
  fail=$((fail + 1))
fi

# NUL is not the only byte scanning-as-text can push into a log, and it is the
# LEAST dangerous: bash command substitution happens to drop NULs on its own, so
# the case above leans on the rendered-'?' assertion. Terminal escapes do NOT get
# dropped — an ESC sequence reaching a CI log is escape-injection, and a bare CR
# can rewrite the reported line. This case pins the sanitizer's actual load:
# without it, the two bytes below arrive in the report verbatim (measured).
echo "Self-test: terminal-escape bytes in a hit never reach the report"
reset_sandbox
mkdir -p "$SANDBOX/src"
printf "lead\\033[31m\\015ing ${ENV_NAME}=%s\\n" "$SYNTH_HEX" > "$SANDBOX/src/esc-report.sh"
esc_rc=0
( cd "$SANDBOX" && bash bin/secret-scan.sh ) > "$REPORT" 2>&1 || esc_rc=$?
esc_bytes="$(LC_ALL=C tr -d '\11\12\40-\176\200-\377' < "$REPORT" | wc -c | tr -d ' ')"
if [ "$esc_rc" -eq 1 ] && [ "$esc_bytes" -eq 0 ]; then
  echo "  ✓ hit reported (exit 1) with 0 escape/control bytes in the report"
  pass=$((pass + 1))
else
  echo "  ✖ expected exit 1 with 0 escape/control bytes —" \
       "got exit $esc_rc, $esc_bytes control byte(s)"
  fail=$((fail + 1))
fi

# Scanning every file as text is what makes the guard NUL-proof, but it also
# means a genuinely binary file is now read as text — and there, "lines" end
# wherever a 0x0a happens to fall, so one match could print most of the file into
# the CI log. That volume hazard is introduced BY the flag change, so the cap
# belongs to this fix. The report's hit lines carry a 4-space indent, hence the
# +4 allowance. Removing the `cut` from sanitize_hits turns this red.
echo "Self-test: an over-long hit line is capped, not dumped whole"
reset_sandbox
mkdir -p "$SANDBOX/src"
{ printf 'x%.0s' $(seq 1 5000); printf " ${ENV_NAME}=%s\\n" "$SYNTH_HEX"; } > "$SANDBOX/src/huge.bin"
huge_rc=0
( cd "$SANDBOX" && bash bin/secret-scan.sh ) > "$REPORT" 2>&1 || huge_rc=$?
longest="$(awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$REPORT")"
if [ "$huge_rc" -eq 1 ] && [ "$longest" -le 204 ]; then
  echo "  ✓ over-long hit capped (longest report line: $longest chars)"
  pass=$((pass + 1))
else
  echo "  ✖ expected exit 1 and every line <= 204 chars —" \
       "got exit $huge_rc, longest line $longest"
  fail=$((fail + 1))
fi

echo
echo "Passed: $pass   Failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "✓ Secret-scan guard self-test green."
