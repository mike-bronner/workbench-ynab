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
# These three isolate rule 2 (the cleartext-token rule), so their value must NOT
# be the 64-hex shape: with $SYNTH_HEX the file trips rule 1 as well, on a
# SEPARATE grep call site, and all three report exit 1 even if rule 2 is gone
# entirely. Measured — dropping PAT_ENV from the scanning loop left all three
# green with the hex value, and reddens all three with the value below.
ENV_VALUE='s3cretvalue'
run_case "bare cleartext token assignment is caught"    1 "src/run.sh"    "${ENV_NAME}=${ENV_VALUE}"
run_case "double-quoted cleartext token is caught"      1 "src/run.sh"    "${ENV_NAME}=\"${ENV_VALUE}\""
run_case "single-quoted cleartext token is caught"      1 "src/run.sh"    "${ENV_NAME}='${ENV_VALUE}'"
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
#
# The cleartext fixture's value is deliberately NOT the 64-hex shape its
# neighbours use, for the same reason the invalid-UTF-8 section's cleartext case
# avoids it. Rules 2 and 3 run on their OWN grep call site (the loop at
# bin/secret-scan.sh:181), separate from rule 1's (:173) — so a hex-shaped value
# makes the file trip rule 1 as well, and the case reports exit 1 whether or not
# the loop's own NUL-handling works. Measured: with the hex value, appending
# --binary-files=without-match to the LOOP's grep alone left this case green
# while its PEM and vendor-scoped siblings correctly reddened.
echo "Self-test: a NUL byte cannot hide a secret from any rule"
run_nul_case "hex PAT shape beside a NUL is caught"       1 "src/leak.txt" 'lead\000ing token: %s\n' "$SYNTH_HEX"
run_nul_case "cleartext token beside a NUL is caught"     1 "src/run.sh"   "lead\\000ing ${ENV_NAME}=%s\\n"  "$ENV_VALUE"
run_nul_case "PEM header beside a NUL is caught"          1 "src/id_rsa"   "lead\\000ing ${BEGIN_FRAG} RSA %s\\n" "$KEY_FRAG"

# The vendor/ scoping is orthogonal to the binary-classification fix, and must
# survive it: scanning as text must not start flagging the bundle's legitimate
# hex digests, nor stop catching a real token smuggled there behind a NUL.
echo "Self-test: NUL handling leaves the vendor/ hex scoping intact"
run_nul_case "64-hex digest beside a NUL under vendor/ stays ignored" 0 "vendor/x.json" '{"sha256": "\000%s"}\n' "$SYNTH_HEX"
run_nul_case "cleartext token beside a NUL under vendor/ IS caught"   1 "vendor/run.sh" "lead\\000ing ${ENV_NAME}=%s\\n" "$SYNTH_HEX"

# The NUL blind spot has a twin that arrives through the LOCALE door. Under a
# UTF-8 locale grep decodes input as UTF-8, and a byte that is not valid UTF-8 (a
# lone continuation byte such as \200) makes it silently fail to match on that
# line — no error, no warning, the credential simply reports as absent. Same
# thesis as issue #255: one stray byte, secret invisible, guard says clean. The
# guard now pins LC_ALL=C on every scanning grep; these cases pin that pin.
#
# The locale is FORCED rather than inherited. CI (ubuntu-latest) runs under
# LANG=C.UTF-8 and secret-scan.yml sets no override, so the affected locale is
# the real one — but a developer running under LC_ALL=C would otherwise pass
# these cases vacuously, and they would not redden when the pin is removed.
UTF8_LOCALE=C.UTF-8

# run_utf8_case "<desc>" <expected-exit> <file> "<printf-fmt>" "<fmt-arg>"
#
# Same contract as run_nul_case — the payload must come from a printf FORMAT,
# since routing \200 through a bash variable is not what is being tested — except
# the guard runs under a forced UTF-8 locale.
run_utf8_case() {
  local desc="$1" expected="$2" file="$3" fmt="$4" arg="$5"
  reset_sandbox
  mkdir -p "$SANDBOX/$(dirname "$file")"
  # shellcheck disable=SC2059  # fmt is a trusted literal format carrying \200.
  printf "$fmt" "$arg" > "$SANDBOX/$file"
  local actual=0
  ( cd "$SANDBOX" && LC_ALL="$UTF8_LOCALE" LANG="$UTF8_LOCALE" bash bin/secret-scan.sh ) \
    >/dev/null 2>&1 || actual=$?
  if [ "$actual" -eq "$expected" ]; then
    echo "  ✓ $desc (exit $actual)"
    pass=$((pass + 1))
  else
    echo "  ✖ $desc — expected exit $expected, got $actual"
    fail=$((fail + 1))
  fi
}

echo "Self-test: an invalid UTF-8 byte cannot hide a secret from the guard"
# Vacuity control FIRST, and it deliberately does NOT go through the guard: prove
# that on THIS runner an unpinned grep really does miss the shape under
# $UTF8_LOCALE. If it still matches, the locale is not UTF-8-effective here, the
# case below would pass without exercising the pin at all, and removing the pin
# would not redden it — so that outcome is a failure, not a silent pass.
#
# The probe must use the guard's OWN rule-1 pattern, not a bare [0-9a-f]{64}.
# That distinction is the whole mechanism on GNU grep: it is the trailing
# [^0-9a-f] boundary class having to CONSUME the invalid byte that fails under a
# UTF-8 locale. A pattern without the boundary class matches straight through the
# bad byte and would certify the locale as ineffective when it is not.
UTF8_PROBE_PAT='(^|[^0-9a-f])[0-9a-f]{64}([^0-9a-f]|$)'
if printf 'lead %s\200\n' "$SYNTH_HEX" \
     | LC_ALL="$UTF8_LOCALE" LANG="$UTF8_LOCALE" grep -qE "$UTF8_PROBE_PAT"; then
  echo "  ✖ $UTF8_LOCALE is not UTF-8-effective on this runner — the case below"
  echo "    cannot discriminate, so this is a failure, not a pass."
  fail=$((fail + 1))
else
  echo "  ✓ $UTF8_LOCALE makes an unpinned grep miss the shape (the case below discriminates)"
  pass=$((pass + 1))
fi

# The byte sits DIRECTLY against the 64-hex run, which is load-bearing on GNU
# grep — measured on 3.12, the version CI runs. There the miss is caused by the
# pattern's [^0-9a-f] boundary class being unable to consume an invalid byte, so
# the same byte parked at the start of the line still matches and would make this
# case vacuous. (BSD grep 2.6.0-FreeBSD is blunter: an invalid byte ANYWHERE on
# the line kills the match for every rule. Adjacency satisfies both.)
run_utf8_case "hex PAT shape beside an invalid UTF-8 byte is caught" 1 "src/leak.txt" 'lead token: %s\200\n' "$SYNTH_HEX"

# The cleartext and PEM rules share the OTHER scanning call site (the loop), and
# the pin is on both. These two cases assert that site keeps catching a secret
# beside an invalid byte — but be precise about what they discriminate, because
# the two greps differ and a comment claiming more than it delivers is the defect
# this file exists to avoid:
#
#   * BSD-family grep rejects the whole line, so both rules miss without the pin
#     and both cases go red — measured on 2.6.0-FreeBSD.
#   * GNU grep 3.12 still matches these two, pin or no pin: neither PAT_ENV nor
#     PAT_PEM has a boundary class that must consume the invalid byte, so there
#     is nothing for the locale to break. On CI's grep these two cases pass
#     either way; the hex case above is what pins the pin there.
#
# They are kept because the pin protects this call site too, and on a BSD grep
# they are the only thing that proves it.
#
# The cleartext fixture's value is deliberately NOT the 64-hex shape the other
# cases use. With a hex value the file trips rule 1 as well, so the case reports
# exit 1 whether or not the loop's own grep found anything — it would pass on the
# strength of a rule it is not testing. Measured: with the hex value, dropping
# the pin on the loop alone left this case green on BSD grep.
echo "Self-test: the cleartext/PEM call site is pinned too (discriminates on BSD grep)"
run_utf8_case "cleartext token beside an invalid UTF-8 byte is caught" 1 "src/run.sh"   "x\\200${ENV_NAME}=%s\\n" "$ENV_VALUE"
run_utf8_case "PEM header beside an invalid UTF-8 byte is caught"      1 "src/id_rsa"   "x\\200${BEGIN_FRAG} RSA %s\\n" "$KEY_FRAG"

# The guard reports with grep -o, so only bytes INSIDE the match can reach the
# report — but that does not make the report safe on its own. PAT_HEX's
# [^0-9a-f] boundary class matches ANY non-hex byte, so a NUL placed directly
# against the 64-hex run lands inside the matched text itself and reaches stdout
# raw unless sanitize_hits renders it (measured: 1 raw byte survives with the
# sanitizer removed, 0 with it in place). The byte must therefore be adjacent to
# the run, not merely on the same line — a NUL elsewhere on the line is outside
# the match and never printed at all.
#
# Assert on BYTES read back from a FILE. The file capture is not about NUL
# laundering — bin/secret-scan.sh already funnels every hit through its own
# found="$(...)" command substitution, so no raw NUL survives to the guard's
# stdout regardless of how this harness captures it. It is simply the honest way
# to count raw bytes: `wc -c` over a file measures what a CI log would actually
# receive, with no shell layer in between to quietly reshape it.
echo "Self-test: a NUL inside the matched text is rendered, never emitted raw"
reset_sandbox
REPORT="$(mktemp)"
mkdir -p "$SANDBOX/src"
printf 'x\000%s\n' "$SYNTH_HEX" > "$SANDBOX/src/nul-report.txt"
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
if [ "$report_rc" -eq 1 ] && [ "$raw_bytes" -eq 0 ] && grep -q "?${SYNTH_HEX}" "$REPORT"; then
  echo "  ✓ hit reported (exit 1), NUL rendered as '?', 0 raw control bytes"
  pass=$((pass + 1))
else
  echo "  ✖ expected exit 1, a '?<hex>' hit, and 0 raw control bytes —" \
       "got exit $report_rc, $raw_bytes control byte(s)"
  fail=$((fail + 1))
fi

# NUL is not the only byte that can ride inside a match, and it is the least
# dangerous: an ESC reaching a CI log is escape-injection, and a bare CR can
# rewrite the reported line. Same adjacency requirement as above — the ESC is the
# [^0-9a-f] boundary character, so it is part of the matched text (measured: 1
# raw byte survives with sanitize_hits removed).
echo "Self-test: an escape byte inside the matched text never reaches the report"
reset_sandbox
mkdir -p "$SANDBOX/src"
printf 'y\033%s\n' "$SYNTH_HEX" > "$SANDBOX/src/esc-report.txt"
esc_rc=0
( cd "$SANDBOX" && bash bin/secret-scan.sh ) > "$REPORT" 2>&1 || esc_rc=$?
esc_bytes="$(LC_ALL=C tr -d '\11\12\40-\176\200-\377' < "$REPORT" | wc -c | tr -d ' ')"
# Pin the RENDERED form too, mirroring the NUL sibling: 0 control bytes alone
# would still pass if the sanitizer deleted the byte instead of substituting it.
# The NUL case already discriminates that mutation, so this is symmetry rather
# than new coverage — but it costs one condition and makes each case honest
# standalone.
if [ "$esc_rc" -eq 1 ] && [ "$esc_bytes" -eq 0 ] && grep -q "?${SYNTH_HEX}" "$REPORT"; then
  echo "  ✓ hit reported (exit 1), ESC rendered as '?', 0 escape/control bytes"
  pass=$((pass + 1))
else
  echo "  ✖ expected exit 1, a '?<hex>' hit, and 0 escape/control bytes —" \
       "got exit $esc_rc, $esc_bytes control byte(s)"
  fail=$((fail + 1))
fi

# -o bounds the hex and cleartext-token matches to their pattern shapes, but
# PAT_PEM's [A-Z0-9 ]* is UNBOUNDED — a crafted header matches arbitrarily far,
# so one hit could still dump kilobytes into the CI log. That is what MAX_HIT_LEN
# stops. The report's hit lines carry a 4-space indent, and the cap appends a
# 3-char "..." marker, hence the allowance below. Removing the cap from
# sanitize_hits turns this red.
echo "Self-test: an over-long match is capped, not dumped whole"
reset_sandbox
mkdir -p "$SANDBOX/src"
{ printf '%s ' "$BEGIN_FRAG"; printf 'A%.0s' $(seq 1 5000); printf ' %s\n' "$KEY_FRAG"; } > "$SANDBOX/src/huge.bin"
huge_rc=0
( cd "$SANDBOX" && bash bin/secret-scan.sh ) > "$REPORT" 2>&1 || huge_rc=$?
longest="$(awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$REPORT")"
if [ "$huge_rc" -eq 1 ] && [ "$longest" -le 300 ]; then
  echo "  ✓ over-long match capped (longest report line: $longest chars)"
  pass=$((pass + 1))
else
  echo "  ✖ expected exit 1 and every line <= 300 chars —" \
       "got exit $huge_rc, longest line $longest"
  fail=$((fail + 1))
fi

# THE REGRESSION THIS CASE EXISTS FOR: a secret sitting far past the cap on a
# single enormous line. Scanning as text means a minified bundle is one physical
# line — vendor/ynab-mcp/index.cjs is 523,669 characters — so a guard that
# reports the LINE and then keeps its first MAX_HIT_LEN characters emits
# unrelated code and silently redacts the secret that tripped the rule: correct
# exit 1, correct path:line, zero indication of what matched. Reporting the match
# itself (grep -o) makes that structurally impossible. Reverting GREP_BASE from
# -rnoE to -rnE turns this red.
#
# The secret sits in the MIDDLE of the line, with junk on BOTH sides, and that
# placement is load-bearing. It used to sit at the end, which stopped
# discriminating once the cap became head-and-tail: keeping the tail preserves a
# line-final match even with -o gone, so the case passed under its own mutation
# (measured — it stayed green). Junk on both sides puts the match where neither
# the kept head nor the kept tail reaches it, so only -o can surface it.
echo "Self-test: a secret far past the cap is still shown in the report"
reset_sandbox
mkdir -p "$SANDBOX/src"
{ printf 'var a=1;junk%.0s' $(seq 1 200); printf '%s RSA %s' "$BEGIN_FRAG" "$KEY_FRAG"; printf 'var b=2;junk%.0s' $(seq 1 200); printf '\n'; } > "$SANDBOX/src/minified.js"
far_rc=0
( cd "$SANDBOX" && bash bin/secret-scan.sh ) > "$REPORT" 2>&1 || far_rc=$?
if [ "$far_rc" -eq 1 ] && grep -qF -e "${BEGIN_FRAG} RSA ${KEY_FRAG}" "$REPORT"; then
  echo "  ✓ match past char 2400 still visible in the report"
  pass=$((pass + 1))
else
  echo "  ✖ expected exit 1 and the matched PEM header present in the report —" \
       "got exit $far_rc"
  fail=$((fail + 1))
fi

# The locator is capped SEPARATELY from the matched text, so no path length can
# truncate away path:line. A guard that capped the whole "path:line:match" record
# as one string would report a hit whose locator had itself been sliced off —
# bounded, but unlocatable, and therefore just as unactionable as the redaction
# the case above pins.
#
# This needs a DEEP path to discriminate: with a short path the locator sits well
# inside the first MAX_HIT_LEN characters, so whole-record capping preserves it by
# accident and the case would pass against the very defect it exists to catch
# (confirmed by mutation — it did exactly that before the path was lengthened).
# The path below is >200 characters, so record-capping would cut mid-locator.
# Longest real path in this repo is 76 characters, so this is a synthetic
# boundary probe, not a scenario the tree reaches today.
echo "Self-test: a long path never truncates away the path:line locator"
reset_sandbox
LONG_DIR="src/$(printf 'd%.0s' $(seq 1 120))/$(printf 'e%.0s' $(seq 1 90))"
mkdir -p "$SANDBOX/$LONG_DIR"
printf '%s RSA %s\n' "$BEGIN_FRAG" "$KEY_FRAG" > "$SANDBOX/$LONG_DIR/k.pem"
loc_rc=0
( cd "$SANDBOX" && bash bin/secret-scan.sh ) > "$REPORT" 2>&1 || loc_rc=$?
if [ "$loc_rc" -eq 1 ] && grep -q "$LONG_DIR/k.pem:1:" "$REPORT"; then
  echo "  ✓ path:line locator survives a >200-char path (${#LONG_DIR} chars)"
  pass=$((pass + 1))
else
  echo "  ✖ expected exit 1 and the full '$LONG_DIR/k.pem:1:' locator in the" \
       "report — got exit $loc_rc"
  fail=$((fail + 1))
fi

# ...but the locator split is a HEURISTIC and can mis-anchor, and when it does a
# PREFIX-ONLY cap re-opens the very redaction defect -o exists to close.
# match() takes the LEFTMOST ":<digits>:" in the record, and the path always sits
# to the left of grep's own "path:line:" delimiter — so a path containing
# ":<digits>:" hijacks the split every time, with no craftedness threshold. The
# locator then holds a path fragment and the "matched text" is rest-of-path + the
# real ":<line>:" + the match, so capping its first MAX_HIT_LEN characters emits
# pure path and slices the secret off the end: correct exit 1, correct-looking
# report, zero indication of WHAT matched.
#
# The head-and-tail cap defeats this structurally: under -o the match is always
# the record's SUFFIX, so keeping the tail guarantees it survives wherever the
# split landed. Replacing the cap with `substr(txt, 1, max) "..."` turns this red.
#
# The long-path case above CANNOT catch this — its path has no colon to
# mis-anchor on, so its split is correct and its match never approaches the cap.
# The path here must also be long enough that the mis-split text exceeds
# MAX_HIT_LEN (281 chars), or the cap never fires and the case passes vacuously.
# No colon-bearing path is tracked in this repo today (`git ls-files | grep -F ':'`
# is empty), so this is a latent boundary probe, not a live scenario — but git
# tracks such paths happily, so the guard must not depend on their absence.
echo "Self-test: a colon-bearing path cannot redact the match from the report"
reset_sandbox
COLON_DIR="src/weird:12:$(printf 'd%.0s' $(seq 1 120))/$(printf 'e%.0s' $(seq 1 120))"
mkdir -p "$SANDBOX/$COLON_DIR"
printf '%s RSA %s\n' "$BEGIN_FRAG" "$KEY_FRAG" > "$SANDBOX/$COLON_DIR/k.pem"
colon_rc=0
( cd "$SANDBOX" && bash bin/secret-scan.sh ) > "$REPORT" 2>&1 || colon_rc=$?
if [ "$colon_rc" -eq 1 ] && grep -qF -e "${BEGIN_FRAG} RSA ${KEY_FRAG}" "$REPORT"; then
  echo "  ✓ match survives a mis-anchored split on a colon-bearing path"
  pass=$((pass + 1))
else
  echo "  ✖ expected exit 1 and the matched PEM header present in the report —" \
       "got exit $colon_rc"
  fail=$((fail + 1))
fi

# The locator split has a fallback for a record carrying no "path:line:" prefix,
# and that fallback is reachable: a NEWLINE in a filename splits grep's output
# mid-record, so the first half arrives as a bare path fragment with no locator.
# awk variables persist across records, so without the fallback explicitly
# resetting them, that orphan record would be printed carrying the PREVIOUS hit's
# locator — a report line that points at the wrong file.
#
# THE FIXTURE MUST FORCE THE ORDER, and this is the whole design of the case.
# A stale locator can only leak into an orphan that is PRECEDED by a
# locator-bearing record, so the guarantee is order-dependent — and grep's
# traversal order across separate files is not something this test controls. A
# two-file fixture that happens to emit the orphan first passes even with the
# `loc = ""` reset deleted, because there is no preceding locator to go stale.
#
# So both records come from the SAME file, on consecutive lines, where grep's
# order IS guaranteed. One file with the shape on two lines emits:
#
#     ./src/we            <- orphan 1 (no locator; loc is still "" here anyway)
#     ird.txt:1:<match>   <- sets loc
#     ./src/we            <- orphan 2: THIS is the one a stale loc leaks into
#     ird.txt:2:<match>
#
# Hence the assertion is a PAIR. The bare line alone is not discriminating —
# orphan 1 emits it whether or not the reset exists — so the case also asserts
# the stale-prefixed form is absent. Deleting the `else` branch, or just the
# `loc = ""` line inside it, turns this red on the second assertion.
echo "Self-test: a record with no locator is emitted intact, not stale-prefixed"
reset_sandbox
mkdir -p "$SANDBOX/src"
printf '%s\n%s\n' "$SYNTH_HEX" "$SYNTH_HEX" > "$SANDBOX/$(printf 'src/we\nird.txt')"
nl_rc=0
( cd "$SANDBOX" && bash bin/secret-scan.sh ) > "$REPORT" 2>&1 || nl_rc=$?
# The orphan half must stand alone on its own line (4-space report indent), with
# no locator from the preceding record glued onto it.
nl_bare=0; nl_stale=0
grep -qx '    src/we' "$REPORT" && nl_bare=1
grep -qE '^    ird\.txt:[0-9]+:src/we$' "$REPORT" && nl_stale=1
if [ "$nl_rc" -eq 1 ] && [ "$nl_bare" -eq 1 ] && [ "$nl_stale" -eq 0 ]; then
  echo "  ✓ locator-less record emitted intact (no stale locator)"
  pass=$((pass + 1))
else
  echo "  ✖ expected exit 1, a bare 'src/we' report line, and no stale-prefixed" \
       "'ird.txt:<n>:src/we' line — got exit $nl_rc, bare=$nl_bare, stale=$nl_stale"
  fail=$((fail + 1))
fi

echo
echo "Passed: $pass   Failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "✓ Secret-scan guard self-test green."
