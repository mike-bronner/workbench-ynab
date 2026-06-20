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
#   * The hex rule (rule 1) — and ONLY the hex rule — skips vendor/. The bundle
#     marker vendor/ynab-mcp/vendored.json legitimately carries 64-char-hex
#     SHA-256 digests that are byte-for-byte indistinguishable from a YNAB PAT,
#     so scanning vendor/ with the hex rule would only flag the repo's own
#     digests. The cleartext-token rule (2) and PEM rule (3) DO scan vendor/:
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
# Exit 0 = clean. Exit 1 = at least one likely credential found.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Common grep flags: recurse, show line numbers, extended regex, skip binaries,
# and prune the directories that are never committed. vendor/ is NOT pruned here
# — it is excluded only for the hex rule below (see the per-rule note above), so
# the cleartext-token and PEM rules still reach into the vendored bundle.
GREP_BASE=(-rInE --binary-files=without-match
  --exclude-dir=.git --exclude-dir=node_modules)

# 1. Standalone 64-char lowercase-hex run (the YNAB PAT shape). The surrounding
#    [^0-9a-f] / anchors stop a longer hex blob from matching a 64-char window.
PAT_HEX='(^|[^0-9a-f])[0-9a-f]{64}([^0-9a-f]|$)'

# 2. YNAB_ACCESS_TOKEN= with a literal value. The value must START with a token
#    char (optionally quoted); this is what excludes "$VAR" / $VAR references.
PAT_ENV='YNAB_ACCESS_TOKEN=("|'"'"')?[A-Za-z0-9]'

# 3. PEM / private-key header, any key type (RSA, EC, OPENSSH, generic).
PAT_PEM='-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----'

hits=""

# Rule 1 (hex) excludes vendor/: vendored.json carries legitimate 64-char-hex
# SHA-256 digests indistinguishable from a YNAB PAT. The exclusion is scoped to
# THIS rule alone.
found="$(grep "${GREP_BASE[@]}" --exclude-dir=vendor -e "$PAT_HEX" . 2>/dev/null | sed 's#^\./##' || true)"
[ -n "$found" ] && hits="${hits}${found}"$'\n'

# Rules 2 (cleartext token) and 3 (PEM) scan the WHOLE tree, vendor/ included —
# their shapes never legitimately appear in the bundle, so a token or key
# smuggled under vendor/ is caught. -e "$pat" is required: the PEM pattern starts
# with '-', which grep would otherwise parse as an option flag.
for pat in "$PAT_ENV" "$PAT_PEM"; do
  found="$(grep "${GREP_BASE[@]}" -e "$pat" . 2>/dev/null | sed 's#^\./##' || true)"
  [ -n "$found" ] && hits="${hits}${found}"$'\n'
done
hits="$(printf '%s' "$hits" | sed '/^[[:space:]]*$/d' | sort -u || true)"

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
