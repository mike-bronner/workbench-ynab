#!/usr/bin/env bash
#
# secret-scan.sh — fail the build if a credential is committed to this repo.
#
# This repo handles a YNAB Personal Access Token (write access to a live
# financial budget), so a leaked credential is a high-severity event. This guard
# is the repo-level backstop required by issue #72: it scans the working tree for
# the credential shapes that must never land in version control and exits
# non-zero on the first match. It is wired into CI by .github/workflows/
# secret-scan.yml and exercised by tests/secret-scan.test.sh.
#
# WHAT IT MATCHES (see SECURITY.md "Secret-hygiene enforcement"):
#   1. YNAB PAT shape — a standalone 64-character lowercase-hex string. YNAB
#      personal access tokens are hex-like; this is their on-the-wire shape.
#   2. Cleartext token assignment — YNAB_ACCESS_TOKEN= followed by a literal
#      value. A `$VAR` reference (e.g. the launcher's export
#      YNAB_ACCESS_TOKEN="$TOKEN") is NOT a leak and is intentionally not matched.
#   3. PEM / private-key headers — any "-----BEGIN ... PRIVATE KEY-----" block.
#
# WHAT IT EXCLUDES, and why — the exclusion is scoped PER RULE, not blanket:
#   * The hex rule (rule 1) — and ONLY the hex rule — skips the REPO-ROOT vendor/.
#     The bundle marker vendor/ynab-mcp/vendored.json legitimately carries
#     64-char-hex SHA-256 digests that are byte-for-byte indistinguishable from a
#     YNAB PAT, so scanning vendor/ with the hex rule would only flag the repo's
#     own digests. The skip is anchored to that one root directory: a nested
#     directory that merely happens to be NAMED vendor (src/vendor/, a/vendor/…)
#     is still scanned by the hex rule (issue #276 — the old --exclude-dir=vendor
#     matched the basename at every depth). The cleartext-token rule (2) and PEM
#     rule (3) DO scan vendor/ at every depth:
#     their shapes never legitimately appear there, so the ~1.46 MB bundle — the
#     repo's highest-risk supply-chain surface — is covered for the unambiguous
#     secret shapes, with no false positives.
#   * .git/ and node_modules/ — VCS internals and (never-committed) deps — are
#     skipped by every rule.
#
# Note: vendor/ynab-mcp/verify-bundle.sh is a COMPLEMENTARY control, not a
# substitute for scanning — it pins the bundle's SHA-256 to detect drift, but it
# never inspects vendor/ files for secret CONTENT. That is why the cleartext and
# PEM rules must reach into vendor/ here. Keep new hash digests out of the
# scanned tree (or inside vendor/, where only the hex rule is relaxed) so this
# guard stays signal, not noise.
#
# Exit 0 = clean. Exit 1 = at least one likely credential found. Exit 2 = the
# scan did not complete (a stage failed to run) — see abort_scan below. 2 is
# deliberately its own code: "the guard broke" is not "the tree is clean", and
# collapsing the two is the fail-open this script must never have (issue #265).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Exit status for "the scan could not be completed". Distinct from 0 (clean) and
# 1 (secret found) so neither verdict can be inferred from a broken toolchain.
SCAN_ABORT_EXIT=2

# The scanning greps send stderr HERE rather than to /dev/null. Discarding it is
# what made a failing stage invisible: the tool's own diagnostic — the one thing
# that explains WHY the scan broke — went to the bit bucket alongside the noise
# the redirect exists to suppress. Capturing it keeps an ordinary run just as
# quiet (the file is only ever read on the abort path) while making a failure
# diagnosable. It lives under $TMPDIR, never inside the scanned tree.
SCAN_ERR="$(mktemp)"
trap 'rm -f "$SCAN_ERR"' EXIT

# Abort: a stage of the scan failed to run, so the tree was NOT fully scanned.
#
# A pipeline whose stages are not all healthy has proved nothing about the tree,
# so the only honest report is "the scan did not complete" — never the clean
# message at the bottom of this file. The wording and the ⚠ marker are picked to
# be unmistakable against both the ✓ clean line and the ✖ secret-found block.
#
# Built from shell BUILTINS only (echo, while read, printf-free). The entire
# premise of this path is that an external tool just failed to execute, so
# formatting the diagnostic with sed/cat could fail for the same reason and
# swallow the very message that explains the abort.
abort_scan() {
  local line
  echo "⚠ secret-scan ABORTED — the scan did not complete: $1" >&2
  if [ -s "$SCAN_ERR" ]; then
    echo "  Captured stderr from the most recent scanning grep:" >&2
    # `|| [ -n "$line" ]` keeps a final unterminated line: a tool that dies
    # mid-write can leave one, and that fragment is exactly the diagnostic this
    # path exists to surface.
    while IFS= read -r line || [ -n "$line" ]; do
      echo "    $line" >&2
    done <"$SCAN_ERR"
  fi
  echo "  This is NOT a clean result. The tree was not fully scanned, so a" >&2
  echo "  committed secret may be present and unreported. Fix the broken tool" >&2
  echo "  or environment and re-run — do not merge on this outcome." >&2
  exit "$SCAN_ABORT_EXIT"
}

# check_stages <label> "<stage names>" <status>...
#
# Statuses arrive in pipeline order, one per named stage, and every one must be
# 0. Reports the FIRST failing stage by name on stderr and returns 1; returns 0
# when the whole pipeline is healthy. It never exits, so it is safe to call from
# inside a pipeline element (where `exit` would only kill that element's
# subshell) — the caller turns the non-zero return into abort_scan.
#
# grep's benign "no match" (exit 1) is the ONE non-zero this guard tolerates, and
# it is handled at grep's own call site before it ever reaches here.
check_stages() {
  local label="$1" names="$2"
  shift 2
  local -a stage_names
  # shellcheck disable=SC2206  # Deliberate word split: names is a literal list.
  stage_names=($names)
  local i=0 st
  for st in "$@"; do
    if [ "$st" -ne 0 ]; then
      echo "secret-scan: $label — stage '${stage_names[i]:-#$((i + 1))}' exited $st" >&2
      return 1
    fi
    i=$((i + 1))
  done
}

# Common grep flags: recurse, show line numbers, extended regex, scan every file
# as text, report ONLY the matched text, and prune the directories that are never
# committed. vendor/ is NOT pruned here — the hex rule alone skips it, and it does
# so through its scan-path list rather than a --exclude-dir glob (see
# hex_scan_roots below), so the cleartext-token and PEM rules still reach into the
# bundle. Note the asymmetry is deliberate: .git/ and node_modules/ SHOULD be
# pruned wherever they appear, which is exactly what --exclude-dir's
# match-the-basename-at-any-depth behaviour gives; the vendor/ carve-out wants the
# opposite (one root directory only), which is why it cannot live on this list.
#
# --binary-files=text, and NO -I: a single NUL byte anywhere in a file makes grep
# classify the WHOLE file as binary and skip it, so a credential in that file is
# invisible to all three rules below — this guard is the repo's only
# content-scanning CI gate, and one stray byte silently shrinks it to nothing
# (issue #255). Note -I is the short form of --binary-files=without-match and was
# baked into the old -rInE cluster, so it is DROPPED rather than overridden here:
# relying on grep's last-flag-wins ordering to cancel an earlier -I would make
# this guard's coverage depend on an implementation detail. With no -I present
# there is nothing to override, on GNU and BSD grep alike.
#
# -o reports the MATCHED TEXT instead of the whole line, and it is what keeps a
# finding actionable now that binary files are scanned. Without it grep prints
# the entire physical line, which in a minified bundle is the entire file:
# vendor/ynab-mcp/index.cjs is one 523,669-character line, so any cap applied to
# that line keeps its first N characters — unrelated minified code — and silently
# discards the secret that actually tripped the rule. The result was a correct
# exit 1 with correct path:line and zero indication of WHAT matched. With -o the
# matched shape is the report, so it can never be the part that gets truncated
# away, regardless of where on the line it sits. Detection and exit status are
# unaffected: -o changes only what is printed (verified on GNU grep 3.12 and BSD
# grep 2.6.0-FreeBSD).
GREP_BASE=(-rnoE --binary-files=text
  --exclude-dir=.git --exclude-dir=node_modules)

# Cap on the matched text of a single reported hit. -o bounds most matches to
# their pattern's shape, but PAT_PEM's [A-Z0-9 ]* is unbounded, so a crafted
# header still matches arbitrarily far (measured: 5,043 bytes). The cap is what
# stops one hit dumping that into the CI log.
MAX_HIT_LEN=200

# Render raw grep output safe to print. Scanning as text means grep emits bytes
# straight out of the scanned file, and -o does not make that safe on its own:
# PAT_HEX's [^0-9a-f] boundary class matches ANY non-hex byte, so a NUL or an ESC
# sitting directly against a 64-hex run lands inside the match itself (verified,
# not theoretical) — and a terminal escape reaching a CI log is its own hazard.
#
# Three stages: map every byte outside printable ASCII + tab to '?', strip grep's
# leading "./", then split off the "path:line:" locator and cap only the text
# after it, so an ordinary long path cannot truncate the locator away.
#
# That split is a HEURISTIC, not a guarantee, and the cap is what makes up the
# difference. match() takes the LEFTMOST ":<digits>:" in the record, and the path
# always sits to the left of grep's own "path:line:" delimiter — so a path that
# itself contains ":<digits>:" (git will happily track one; none exist in this
# tree) hijacks the split every time. The locator then ends up a path fragment
# and the "matched text" is rest-of-path + the real ":<line>:" + the match.
#
# Hence the cap keeps the HEAD *and* the TAIL of that text rather than a prefix.
# Under -o the match is always the record's SUFFIX, so keeping the tail is what
# makes the report's guarantee unconditional: the end of the matched shape
# survives no matter where the split landed or how long the path is. A prefix-only
# cap re-opened exactly the redaction defect -o was added to close — on a
# mis-anchored split the prefix is all path and the secret falls off the end
# (correct exit 1, zero indication of WHAT matched). Keeping the head as well
# preserves the readable start of PAT_PEM's unbounded match ("-----BEGIN AAA...").
#
# Because the tr stage has already reduced everything to ASCII, awk's
# substr/length are byte- and character-identical here, so this cannot split a
# multi-byte sequence the way a raw byte-slice would. The truncation marker is
# ASCII "..." rather than a "…" glyph for the same reason: re-introducing a
# multi-byte sequence would contradict the C-locale guarantee the tr stage exists
# to provide.
#
# The three stages are status-checked, not trusted. `if` is what makes that safe
# under `set -e`: it suppresses errexit for the pipeline, so a non-zero stage
# reaches the check below instead of killing the shell, and it leaves PIPESTATUS
# untouched for the branch body. Both branches capture the SAME thing on purpose
# — which branch runs is decided by the collapsed pipefail scalar, and that
# scalar is precisely what this function refuses to draw a conclusion from.
sanitize_hits() {
  local -a st
  if LC_ALL=C tr -c '\11\12\40-\176' '?' \
    | LC_ALL=C sed 's#^\./##' \
    | LC_ALL=C awk -v max="$MAX_HIT_LEN" '
        {
          if (match($0, /:[0-9]+:/)) {
            loc = substr($0, 1, RSTART + RLENGTH - 1)
            txt = substr($0, RSTART + RLENGTH)
          } else {
            # No "path:line:" in this record. Reachable: a NEWLINE in a filename
            # splits the grep output mid-record, so the first half arrives as a
            # bare path fragment. awk variables persist across records, so these
            # two assignments are load-bearing — without them the orphan would be
            # printed carrying the locator of the PREVIOUS hit, pointing at the
            # wrong file. Capping the whole record also keeps it bounded.
            loc = ""
            txt = $0
          }
          # Head-and-tail: int() because an odd max would otherwise hand substr a
          # fractional length. Bounded at max + 3 ("..."), same as a prefix cap.
          if (length(txt) > max) {
            half = int(max / 2)
            txt = substr(txt, 1, half) "..." substr(txt, length(txt) - half + 1)
          }
          print loc txt
        }'; then
    st=("${PIPESTATUS[@]}")
  else
    st=("${PIPESTATUS[@]}")
  fi
  # Returns non-zero rather than aborting: this function runs as a pipeline
  # element, where `exit` would kill only its own subshell. The scanning call
  # site turns this status into the abort.
  check_stages 'output sanitizer' 'tr sed awk' "${st[@]}"
}

# Run ONE scanning rule end to end and write its sanitized hits to stdout.
# "$1" labels the rule in any diagnostic; the remaining arguments are appended to
# GREP_BASE — the rule's pattern, then the paths it scans.
#
# The scan paths are the CALLER's to choose rather than a hardcoded ".", and that
# is what carries rule 1's vendor/ carve-out (issue #276): rules 2-3 pass "." to
# sweep the whole tree, while rule 1 passes an explicit top-level root list with
# the repo-root vendor/ removed. See hex_scan_roots below for why the prune has
# to happen here, in the path list, rather than in a --exclude-dir glob.
#
# Same `if`-wrapped PIPESTATUS capture as sanitize_hits, for the same reason: the
# collapsed pipefail scalar cannot tell grep's routine "no match" apart from a
# stage that failed to execute, and treating those two alike is the whole defect.
scan_rule() {
  local label="$1"
  shift
  local -a st
  : >"$SCAN_ERR"
  if LC_ALL=C grep "${GREP_BASE[@]}" "$@" 2>"$SCAN_ERR" | sanitize_hits; then
    st=("${PIPESTATUS[@]}")
  else
    st=("${PIPESTATUS[@]}")
  fi
  # grep: 0 = matched, 1 = matched nothing, anything else = it failed to run.
  # Exit 1 is the normal, overwhelmingly common case — an empty rule result on a
  # clean tree — and is the only non-zero this guard accepts anywhere.
  [ "${st[0]}" -le 1 ] || abort_scan "$label: 'grep' exited ${st[0]}"
  # sanitize_hits has already named its own failing stage on stderr.
  [ "${st[1]}" -eq 0 ] || abort_scan "$label: the output sanitizer failed"
}

# Assemble the collected hits: drop blank lines, then dedupe. Held to the same
# standard as the scans — a broken stage here would silently shrink or empty the
# report, turning a real finding into a clean run just as effectively.
assemble_hits() {
  local -a st
  if printf '%s' "$1" | sed '/^[[:space:]]*$/d' | sort -u; then
    st=("${PIPESTATUS[@]}")
  else
    st=("${PIPESTATUS[@]}")
  fi
  check_stages 'hit assembly' 'printf sed sort' "${st[@]}" \
    || abort_scan 'hit assembly failed'
}

# 1. Standalone 64-char lowercase-hex run (the YNAB PAT shape). The surrounding
#    [^0-9a-f] / anchors stop a longer hex blob from matching a 64-char window.
PAT_HEX='(^|[^0-9a-f])[0-9a-f]{64}([^0-9a-f]|$)'

# 2. YNAB_ACCESS_TOKEN= with a literal value. The value must START with a token
#    char (optionally quoted); this is what excludes "$VAR" / $VAR references.
PAT_ENV='YNAB_ACCESS_TOKEN=("|'"'"')?[A-Za-z0-9]'

# 3. PEM / private-key header, any key type (RSA, EC, OPENSSH, generic).
PAT_PEM='-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----'

hits=""

# EVERY SCANNING GREP IS PINNED TO LC_ALL=C, and that pin is load-bearing for
# exactly the same reason --binary-files=text is. Under a UTF-8 locale grep
# decodes input as UTF-8, and a byte that is not valid UTF-8 — a lone
# continuation byte like 0x80, or 0xFF — makes it silently fail to match on that
# line: no error, no warning, just a credential the gate reports as absent.
# Measured on GNU grep 3.12 and BSD grep 2.6.0-FreeBSD alike: a 64-hex PAT shape
# with one trailing 0x80 is MISSED under C.UTF-8 and en_US.UTF-8, and caught
# under C. ubuntu-latest sets LANG=C.UTF-8 and secret-scan.yml overrides no
# locale, so the merge-gating job ran in an affected locale.
#
# This is the NUL blind spot's twin — one stray byte, secret invisible, guard
# reports clean — through the locale door rather than the binary-classification
# door, so it is closed here alongside it. sanitize_hits already pins LC_ALL=C on
# all three of its stages; the stage that decides whether a credential is found
# at all now gets the same treatment.

# Rule 1 (hex) excludes the REPO-ROOT vendor/: vendored.json carries legitimate
# 64-char-hex SHA-256 digests indistinguishable from a YNAB PAT. The exclusion is
# scoped to THIS rule alone, and — since issue #276 — to that ONE directory.
#
# THE MECHANISM, and why it is not --exclude-dir. grep matches --exclude-dir
# against a directory's BASENAME at EVERY depth, so `--exclude-dir=vendor` pruned
# any directory literally named vendor anywhere in the tree: a hex secret under
# e.g. src/vendor/nested/ was invisible to rule 1, at any nesting depth. The
# obvious patch does not work either, and is not portable — measured with
# `--exclude-dir=./vendor`, BSD grep 2.6.0-FreeBSD prunes the root vendor/ (right
# answer, by accident) while GNU grep 3.12 prunes NOTHING, which would put
# vendored.json's legitimate digests straight back into the report.
#
# So the prune is anchored by CONSTRUCTION instead: rule 1 is handed an explicit
# list of the repo's top-level entries with ./vendor removed. "vendor" is matched
# once, as a root path, by shell string comparison — no glob semantics to differ
# between greps — and every deeper directory of that name is scanned normally.
#
# .git/ and node_modules/ stay on GREP_BASE's --exclude-dir: those ARE meant to
# be pruned at every depth, by every rule. Measured on both greps above:
# --exclude-dir still applies to a directory named on the command line, so ./.git
# arriving as its own root is skipped exactly as it was under a single "." root.
#
# Symlinked top-level entries are skipped, and that PRESERVES the old coverage
# rather than narrowing it. `grep -r` follows a symlink NAMED ON THE COMMAND LINE
# but never one it merely encounters while recursing, so under the previous "."
# root a top-level symlink was never followed. Promoting it to its own root would
# start following it (measured: GNU grep 3.12 reads through it into an out-of-tree
# directory; BSD grep does not) — a divergence in both coverage and portability
# that this repo never asked for. Skipping keeps rule 1 reading exactly the same
# bytes as before, on both greps.
hex_scan_roots=()
shopt -s dotglob nullglob
for entry in ./*; do
  if [ "$entry" != ./vendor ] && [ ! -L "$entry" ]; then
    hex_scan_roots+=("$entry")
  fi
done
shopt -u dotglob nullglob

# Fail closed on an empty root list — reachable, since a tree whose only real
# top-level entry is vendor/ (everything else symlinked) produces one.
#
# Without this check the outcome depends on the bash running the guard, and
# neither branch is acceptable: on 4.4+ the empty expansion leaves grep with no
# path operand, so it reads STDIN — hanging on a terminal, or "passing" on an
# empty pipe and printing the CLEAN message; on 3.2 the same expansion is an
# unbound-variable error under `set -u`, which at least fails, but as a bare
# exit 1 indistinguishable from "a secret was found". This file's whole premise
# is that "the guard broke" is its own verdict, so say so explicitly: exit 2.
[ "${#hex_scan_roots[@]}" -gt 0 ] \
  || abort_scan 'rule 1 (64-hex PAT shape): no scannable top-level entries'

# `|| exit $?` re-raises an abort out of the command substitution: abort_scan's
# `exit` fires inside that subshell, not this one. Under the `set -e` at the top
# of this file errexit already propagates it, so this is redundant TODAY — it is
# kept because it is what keeps the guard failing closed if errexit is ever
# relaxed, and it is load-bearing in exactly that case. Measured: with `set -e`
# dropped and all three re-raises removed, all 8 broken-stage cases in
# tests/secret-scan.test.sh go red — the abort block still reaches stderr from
# inside the subshell, and the guard then prints the clean message and exits 0
# anyway. Removing the re-raises alone, with `set -e` in place, reddens nothing.
found="$(scan_rule 'rule 1 (64-hex PAT shape)' -e "$PAT_HEX" "${hex_scan_roots[@]}")" || exit $?
[ -n "$found" ] && hits="${hits}${found}"$'\n'

# Rules 2 (cleartext token) and 3 (PEM) scan the WHOLE tree, vendor/ included —
# their shapes never legitimately appear in the bundle, so a token or key
# smuggled under vendor/ is caught. -e "$pat" is required: the PEM pattern starts
# with '-', which grep would otherwise parse as an option flag.
for pat in "$PAT_ENV" "$PAT_PEM"; do
  found="$(scan_rule 'rules 2-3 (cleartext token / PEM header)' -e "$pat" .)" || exit $?
  [ -n "$found" ] && hits="${hits}${found}"$'\n'
done
hits="$(assemble_hits "$hits")" || exit $?

# The indent pipeline below is deliberately NOT given the stage-status treatment
# above. It is a REPORTING stage, not a scanning one: it runs only after a hit is
# already in hand, on the `exit 1` path. If its sed fails, `set -e` and pipefail
# stop the script right there with sed's own non-zero status, so the build still
# fails — the outcome is a degraded report, never a false "clean".
if [ -n "$hits" ]; then
  {
    echo "✖ Possible committed secret(s) found:"
    printf '%s\n' "$hits" | sed 's/^/    /'
    echo
    echo "  Credentials must NEVER be committed. The YNAB token lives in the"
    echo "  macOS Keychain only (service ynab-mcp). See SECURITY.md."
    echo "  If this is a legitimate non-secret (e.g. a hash digest), move it"
    echo "  under vendor/ or rework it so it does not match these shapes."
  } >&2
  exit 1
fi

echo "✓ No committed secrets found (YNAB PAT shape, cleartext token, or PEM key)."
