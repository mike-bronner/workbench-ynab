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
# WHAT IT EXCLUDES, and why:
#   * vendor/ — the frozen YNAB MCP bundle and its provenance marker
#     (vendored.json) legitimately carry 64-char-hex SHA-256 digests. vendor/
#     has its OWN, stronger integrity control: vendor/ynab-mcp/verify-bundle.sh
#     pins the bundle's exact SHA-256, so a credential cannot be smuggled into
#     the bundle without failing that check. Scanning it here would only produce
#     false positives on legitimate digests.
#   * .git/ and node_modules/ — VCS internals and (never-committed) deps.
#
# A 64-char-hex YNAB token and a SHA-256 digest are byte-for-byte indistinguish-
# able by shape; the vendor/ exclusion is what keeps the hex rule from flagging
# the repo's own legitimate digests. Keep new hash digests out of the scanned
# tree (or inside vendor/) so this guard stays signal, not noise.
#
# Exit 0 = clean. Exit 1 = at least one likely credential found.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Common grep flags: recurse, show line numbers, extended regex, skip binaries,
# and prune the directories that legitimately hold digests / are never committed.
GREP_OPTS=(-rInE --binary-files=without-match
  --exclude-dir=.git --exclude-dir=vendor --exclude-dir=node_modules)

# 1. Standalone 64-char lowercase-hex run (the YNAB PAT shape). The surrounding
#    [^0-9a-f] / anchors stop a longer hex blob from matching a 64-char window.
PAT_HEX='(^|[^0-9a-f])[0-9a-f]{64}([^0-9a-f]|$)'

# 2. YNAB_ACCESS_TOKEN= with a literal value. The value must START with a token
#    char (optionally quoted); this is what excludes "$VAR" / $VAR references.
PAT_ENV='YNAB_ACCESS_TOKEN=("|'"'"')?[A-Za-z0-9]'

# 3. PEM / private-key header, any key type (RSA, EC, OPENSSH, generic).
PAT_PEM='-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----'

hits=""
for pat in "$PAT_HEX" "$PAT_ENV" "$PAT_PEM"; do
  # -e "$pat" is required: the PEM pattern starts with '-', which grep would
  # otherwise parse as option flags rather than as the search pattern.
  found="$(grep "${GREP_OPTS[@]}" -e "$pat" . 2>/dev/null | sed 's#^\./##' || true)"
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
