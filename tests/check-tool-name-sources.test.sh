#!/usr/bin/env bash
#
# check-tool-name-sources.test.sh — self-test for the swap-ready guard (issue #87).
#
# Self-contained: no test framework required. Run directly:
#   bash tests/check-tool-name-sources.test.sh
# Exits 0 if all assertions pass, 1 otherwise. Slots into the repo-wide test
# entrypoint from issue #4 (tests/unit/ + scripts/test.sh) once it lands.
#
# The guard (bin/check-tool-name-sources.sh) is the *test* for issue #87's
# central invariant (no concrete YNAB tool name outside the allowlist). This
# file is the test for the test: it proves the guard catches a planted name on
# every scanned surface, honours the allowlist, ignores the bare prefix / family
# glob, passes on a clean tree — and (issue #131) that the REAL tree is clean,
# so a hard-coded name anywhere in the repo fails the suite, not just the
# sandbox drills.
#
# The mechanics cases run the guard against a throwaway sandbox repo, so they
# never mutate the real tree; the final case runs it read-only from the repo
# root. The forbidden token is assembled at runtime from two harmless
# fragments — the bare prefix (never matched by the guard) and an operation
# suffix — so THIS file contains no literal concrete name and stays clean when
# the guard scans tests/.

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/../bin/check-tool-name-sources.sh"

# Assemble a concrete tool name without ever writing one literally in this file.
PREFIX='mcp__plugin_workbench-ynab_ynab__'          # bare prefix — never matched
CONCRETE="${PREFIX}ynab_list_budgets"               # a real, matchable name
GLOB="${PREFIX}ynab_*"                              # family glob — never matched

SANDBOX="$(mktemp -d)"
# Set when the NUL positive control plants its sentinel inside the real repo
# root (see below); cleaned up on every exit path, including a failed assertion.
SENTINEL_DIR=""
trap 'rm -rf "$SANDBOX" ${SENTINEL_DIR:+"$SENTINEL_DIR"}' EXIT

pass=0
fail=0

# Lay down a minimal sandbox repo with the guard and the allowlisted files.
reset_sandbox() {
  rm -rf "$SANDBOX"
  mkdir -p "$SANDBOX/bin" "$SANDBOX/skills/protocol" "$SANDBOX/docs" \
           "$SANDBOX/agents" "$SANDBOX/hooks" "$SANDBOX/assets" \
           "$SANDBOX/commands" "$SANDBOX/vendor"
  cp "$GUARD" "$SANDBOX/bin/check-tool-name-sources.sh"
  chmod +x "$SANDBOX/bin/check-tool-name-sources.sh"
  # Allowlisted files exist but start clean.
  : > "$SANDBOX/skills/protocol/ynab-tools.md"
  : > "$SANDBOX/docs/mcp-capability-map.md"
  : > "$SANDBOX/agents/ynab-orchestrator.md"
  : > "$SANDBOX/README.md"
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
  ( cd "$SANDBOX" && bash bin/check-tool-name-sources.sh ) >/dev/null 2>&1 || actual=$?
  if [ "$actual" -eq "$expected" ]; then
    echo "  ✓ $desc (exit $actual)"
    pass=$((pass + 1))
  else
    echo "  ✖ $desc — expected exit $expected, got $actual"
    fail=$((fail + 1))
  fi
}

echo "Self-test: guard catches violations on every scanned surface"
run_case "concrete name in a skill is caught"        1 "skills/review.md"   "uses $CONCRETE"
run_case "concrete name in a hook is caught"         1 "hooks/probe.sh"     "TOOL=$CONCRETE"
run_case "concrete name in a bin script is caught"   1 "bin/probe.sh"       "TOOL=$CONCRETE"
run_case "concrete name in a test is caught"         1 "tests/probe.sh"     "TOOL=$CONCRETE"
run_case "concrete name in README is caught"         1 "README.md"          "see $CONCRETE"
run_case "concrete name in JSON config is caught"    1 "config.json"        "{\"tool\": \"$CONCRETE\"}"
run_case "concrete name in an asset is caught"       1 "assets/contract.md" "apply via $CONCRETE"
run_case "concrete name in a command is caught"      1 "commands/run.md"    "calls $CONCRETE"
# Agent and doc both carry an allowlist exception (one specific file each), so a
# name in a NON-allowlisted sibling is exactly where a real scatter would hide —
# prove the guard still catches it.
run_case "concrete name in a non-allowlisted agent is caught" 1 "agents/other.md"  "tools: $CONCRETE"
run_case "concrete name in a non-allowlisted doc is caught"   1 "docs/other.md"    "see $CONCRETE"

echo "Self-test: allowlist and derivation-rule exemptions pass"
run_case "concrete name in the SSoT is permitted"        0 "skills/protocol/ynab-tools.md" "$CONCRETE"
run_case "concrete name in the capability map permitted" 0 "docs/mcp-capability-map.md"    "$CONCRETE"
run_case "concrete name in the orchestrator permitted"   0 "agents/ynab-orchestrator.md"   "tools: $CONCRETE"
run_case "bare prefix alone is not flagged"              0 "skills/review.md"              "prefix is $PREFIX"
run_case "family glob alone is not flagged"              0 "skills/review.md"              "glob is $GLOB"
run_case "concrete name inside vendor/ is ignored"       0 "vendor/index.cjs"             "$CONCRETE"
run_case "concrete name inside .git/ is ignored"         0 ".git/probe.md"                "$CONCRETE"
run_case "concrete name inside node_modules/ is ignored" 0 "node_modules/pkg/index.js"    "$CONCRETE"
run_case "clean tree passes"                             0 ""                              ""

# A NUL byte used to make grep classify a file as binary and skip it whole, so a
# concrete name inside it was invisible to the guard (issue #216 — exactly how
# assets/allocate-handler.js hid an unhardened resolution site). The guard now
# greps --binary-files=text; pin that, because reverting the flag turns this case
# green-to-red. run_case can't carry the payload — a shell string cannot hold a
# NUL — so the file is written directly here.
echo "Self-test: a NUL byte cannot hide a concrete name from the guard"
reset_sandbox
printf 'const k = "%s\000month"; // %s\n' 'budget' "$CONCRETE" > "$SANDBOX/assets/nul-probe.js"
nul_guard_rc=0
( cd "$SANDBOX" && bash bin/check-tool-name-sources.sh ) >/dev/null 2>&1 || nul_guard_rc=$?
if [ "$nul_guard_rc" -eq 1 ]; then
  echo "  ✓ concrete name inside a NUL-carrying file is caught (exit 1)"
  pass=$((pass + 1))
else
  echo "  ✖ concrete name inside a NUL-carrying file is NOT caught — expected exit 1, got $nul_guard_rc"
  fail=$((fail + 1))
fi

# The sandbox cases prove the guard's MECHANICS; this case proves the INVARIANT
# itself — the real repository tree is clean (issue #131: the guard failed on
# main and no CI job noticed, because this self-test only ever exercised a
# sandbox). Because this file is a tests/**/*.test.sh, scripts/test.sh discovers
# it and CI runs it — so a new hard-coded name now fails the build here too.
echo "Self-test: the real repository tree is clean"
real_out=""
real_rc=0
real_out="$( (cd "$SELF_DIR/.." && bash bin/check-tool-name-sources.sh) 2>&1 )" || real_rc=$?
if [ "$real_rc" -eq 0 ]; then
  echo "  ✓ real tree passes the guard (exit 0)"
  pass=$((pass + 1))
else
  echo "  ✖ real tree FAILS the guard (exit $real_rc):"
  printf '%s\n' "$real_out" | sed 's/^/    /'
  fail=$((fail + 1))
fi

# The guard now greps --binary-files=text, so a NUL byte no longer hides a file
# from IT (pinned by the sandbox case above). But every OTHER tree-wide sweep —
# plain `grep -rn`, an editor search, a reviewer's ripgrep — still classifies a
# NUL-carrying file as binary and skips it silently. That is not hypothetical:
# assets/allocate-handler.js carried a raw NUL as a cache-key separator, which hid
# an unhardened write-tool resolution site from three separate `ALLOWED_TOOLS.find(`
# sweeps (issue #216). The byte is now written as a backslash-u-0000 escape — same
# string at runtime, plain text on disk. So this assertion is braces to the guard
# flag's belt, and it pins the broader property the flag cannot: repo-authored
# source must stay greppable by ANY tool, or every sweep over it is a fiction.
#
# The detector below is shared by the positive control and the real assertion, so
# the control certifies the EXACT pipeline the assertion relies on. It emits one
# "CNT<TAB>n" line per perl batch and one "NUL<TAB>path" line per offending file,
# and it fails LOUDLY: pipefail plus an explicit cd guard mean a missing perl, a
# broken xargs or a bad scan root return non-zero instead of an empty stdout that
# reads identically to "the tree is clean". Diagnostics go to stderr, not
# /dev/null. An assertion that cannot tell "scanned nothing" from "found nothing"
# is the same fail-open shape issue #216 exists to eliminate.
#
# $ARGV/$c are perl's, not the shell's — single quotes are deliberate.
# shellcheck disable=SC2016
nul_scan() {
  (
    set -o pipefail
    cd "$SELF_DIR/.." || exit 3
    find . -type f \
      -not -path './.git/*'         -not -path '*/.git/*' \
      -not -path './vendor/*'       -not -path '*/vendor/*' \
      -not -path './node_modules/*' -not -path '*/node_modules/*' \
      -print0 \
    | xargs -0 perl -0777 -ne \
        'BEGIN { $c = 0 } $c++; print "NUL\t$ARGV\n" if /\x00/; END { print "CNT\t$c\n" }'
  )
}
# Files examined across every perl batch, and the offenders found.
scan_count() { printf '%s\n' "$1" | awk -F'\t' '$1 == "CNT" { n += $2 } END { print n + 0 }'; }
scan_hits()  { printf '%s\n' "$1" | awk -F'\t' '$1 == "NUL" { print $2 }'; }
# A count is only usable when it is a plain non-negative integer. These helpers run
# OUTSIDE nul_scan's pipefail subshell, so a broken awk yields empty output with no
# non-zero status to notice — and `[ "" -eq 0 ]` does not evaluate false, it ERRORS
# (status 2). That skips every failure branch below and lands on the ✓, certifying a
# clean tree while having inspected nothing: the exact fail-open shape this file
# exists to eliminate. Validate the shape before any integer test.
is_count()   { case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Positive control FIRST: prove the detector actually detects before letting it
# certify the tree. A known-NUL sentinel is planted inside the real scan root, so
# this exercises the traversal, the exclude list and the perl match together — the
# failure modes that previously all collapsed into a silent ✓. The sentinel is
# removed immediately and is also on the EXIT trap.
#
# The control certifies BOTH readers of the scan output — scan_hits (a planted NUL
# must be reported) and scan_count (the tally must be a sane positive integer) — so
# neither helper is left as an unvalidated seam feeding the verdict below.
echo "Self-test: the NUL detector detects (positive control)"
SENTINEL_DIR="$SELF_DIR/../.nul-selftest-sentinel.$$"
mkdir -p "$SENTINEL_DIR"
printf 'plain\000text\n' > "$SENTINEL_DIR/sentinel.bin"
ctl_rc=0
ctl_out="$(nul_scan)" || ctl_rc=$?
ctl_count="$(scan_count "$ctl_out")"
ctl_hits="$(scan_hits "$ctl_out")"
rm -rf "$SENTINEL_DIR"
SENTINEL_DIR=""
if [ "$ctl_rc" -ne 0 ]; then
  echo "  ✖ detector pipeline FAILED (exit $ctl_rc) — its clean verdict means nothing"
  fail=$((fail + 1))
elif ! is_count "$ctl_count"; then
  echo "  ✖ the file counter returned \"$ctl_count\", not a number — the count path is"
  echo "    broken, so the tree verdict below could not tell 'clean' from 'never ran'."
  fail=$((fail + 1))
elif [ "$ctl_count" -eq 0 ]; then
  echo "  ✖ the file counter reported 0 files with a sentinel planted — the count path"
  echo "    is broken, so the tree verdict below could not be trusted."
  fail=$((fail + 1))
elif printf '%s\n' "$ctl_hits" | grep -q 'sentinel\.bin$'; then
  echo "  ✓ planted NUL sentinel was found across $ctl_count counted files (the detector works)"
  pass=$((pass + 1))
else
  echo "  ✖ planted NUL sentinel was NOT found — the detector is blind, so its"
  echo "    'no NUL bytes' verdict below would be worthless. Files flagged:"
  printf '%s\n' "${ctl_hits:-<none>}" | sed 's/^/    /'
  fail=$((fail + 1))
fi

# Negative control: the exclude list must skip a NESTED .git directory, not just a
# root-level one. The guard this scan mirrors (bin/check-tool-name-sources.sh) uses
# `grep --exclude-dir=.git`, which excludes at ANY depth by construction; a
# root-anchored `-not -path './.git/*'` alone does not. A submodule, a vendored repo
# copy or a CI checkout artifact puts a .git directory below the root, and git's own
# internals (pack files, HEAD, index) routinely carry NUL bytes — so without the
# `*/.git/*` arm this scan fails the build over git plumbing, for a reason that has
# nothing to do with the invariant it exists to check.
#
# This case is discriminating: drop `-not -path '*/.git/*'` from nul_scan and the
# planted HEAD is reported as an offender, turning this assertion red. The same
# fail-closed rc/count checks as the real assertion run first, so a broken pipeline
# cannot pass this by reporting nothing.
echo "Self-test: a NESTED .git directory is excluded from the NUL scan"
SENTINEL_DIR="$SELF_DIR/../.nul-selftest-nested.$$"
mkdir -p "$SENTINEL_DIR/.git"
printf 'ref: refs/heads/\000main\n' > "$SENTINEL_DIR/.git/HEAD"
nested_rc=0
nested_out="$(nul_scan)" || nested_rc=$?
nested_count="$(scan_count "$nested_out")"
nested_hits="$(scan_hits "$nested_out")"
rm -rf "$SENTINEL_DIR"
SENTINEL_DIR=""
if [ "$nested_rc" -ne 0 ]; then
  echo "  ✖ detector pipeline FAILED (exit $nested_rc) — cannot tell an excluded"
  echo "    nested .git from a scan that never ran."
  fail=$((fail + 1))
elif ! is_count "$nested_count"; then
  echo "  ✖ the file counter returned \"$nested_count\", not a number — the count path"
  echo "    is broken, so this exclusion verdict proves nothing."
  fail=$((fail + 1))
elif [ "$nested_count" -eq 0 ]; then
  echo "  ✖ the file counter reported 0 files — the scan root is broken, so an empty"
  echo "    offender list proves nothing."
  fail=$((fail + 1))
elif printf '%s\n' "$nested_hits" | grep -q '/\.git/HEAD$'; then
  echo "  ✖ a NUL byte inside a NESTED .git directory was reported as an offender —"
  echo "    the exclude list only skips .git at the repo root. Files flagged:"
  printf '%s\n' "$nested_hits" | sed 's/^/    /'
  fail=$((fail + 1))
else
  echo "  ✓ nested .git internals are excluded across $nested_count counted files"
  pass=$((pass + 1))
fi

echo "Self-test: no repo-authored file carries a NUL byte (which would make the guard skip it)"
nul_rc=0
nul_out="$(nul_scan)" || nul_rc=$?
nul_count="$(scan_count "$nul_out")"
nul_files="$(scan_hits "$nul_out")"
if [ "$nul_rc" -ne 0 ]; then
  echo "  ✖ NUL scan FAILED to run (exit $nul_rc) — failing closed rather than"
  echo "    reporting a clean tree the scan never actually inspected."
  fail=$((fail + 1))
elif ! is_count "$nul_count"; then
  echo "  ✖ NUL scan file counter returned \"$nul_count\", not a number — the count"
  echo "    pipeline is broken, so this run cannot tell 'inspected the tree and found"
  echo "    nothing' from 'inspected nothing'. Failing closed."
  fail=$((fail + 1))
elif [ "$nul_count" -eq 0 ]; then
  echo "  ✖ NUL scan examined 0 files — the scan root or exclude list is broken,"
  echo "    so an empty result proves nothing. Failing closed."
  fail=$((fail + 1))
elif [ -n "$nul_files" ]; then
  echo "  ✖ file(s) contain a NUL byte and are INVISIBLE to the guard:"
  printf '%s\n' "$nul_files" | sed 's/^/    /'
  printf '    Write the byte as an escape sequence instead of embedding it literally.\n'
  fail=$((fail + 1))
else
  echo "  ✓ all $nul_count scanned files are plain text (the guard sees all of them)"
  pass=$((pass + 1))
fi

echo
echo "Passed: $pass   Failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "✓ Guard self-test green."
