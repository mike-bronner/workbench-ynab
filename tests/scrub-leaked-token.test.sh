#!/usr/bin/env bash
#
# Test harness for bin/scrub-leaked-token.sh — pure bash, zero dependencies
# (perl, jq, find, git are already required by the script and the repo).
#
# Run:  tests/scrub-leaked-token.test.sh
# Exit: 0 if every assertion passes, non-zero otherwise.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRUB="$REPO_ROOT/bin/scrub-leaked-token.sh"

# A clearly-synthetic token, built at RUNTIME so the literal never appears in
# any git-tracked file — which would otherwise trip --verify's repo-tree scan.
SYNTH_TOKEN="$(printf 'a%.0s' $(seq 1 64))"
MARKER='[YNAB-TOKEN-REDACTED]'

pass=0
fail=0
ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
assert() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

# ---------------------------------------------------------------------------
# Sandbox: a fake set of all four leak surfaces seeded with the synthetic token.
# ---------------------------------------------------------------------------
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

SESS="$SANDBOX/sessions"
PROJ="$SANDBOX/projects"
DESK="$SANDBOX/claude_desktop_config.json"
mkdir -p "$SESS/2026-06-12" "$PROJ/-Users-mike-foo/tool-results"

# Surface 1 — session log (two occurrences across two lines).
printf 'leaked %s here\nand again %s there\n' "$SYNTH_TOKEN" "$SYNTH_TOKEN" \
  > "$SESS/2026-06-12/a.log.md"
# Surface 2 — project transcript.
printf '{"env":{"YNAB_ACCESS_TOKEN":"%s"}}\n' "$SYNTH_TOKEN" \
  > "$PROJ/-Users-mike-foo/t.jsonl"
# Surface 3 — tool-result cache.
printf 'cached %s value\n' "$SYNTH_TOKEN" \
  > "$PROJ/-Users-mike-foo/tool-results/r.txt"
# Surface 4 — Desktop config (structure must survive; token value only).
cat > "$DESK" <<EOF
{
  "mcpServers": {
    "ynab": {
      "command": "bash",
      "env": { "YNAB_ACCESS_TOKEN": "$SYNTH_TOKEN" }
    }
  }
}
EOF
# A control file with no token — must be left untouched.
printf 'nothing secret here\n' > "$SESS/2026-06-12/control.log.md"

# Run the scrubber with the surface roots pointed at the sandbox and the token
# fed on stdin (simulating `read -rs`). Combined stdout+stderr is captured.
run() {
  printf '%s\n' "$SYNTH_TOKEN" \
    | YNAB_SCRUB_SESSIONS_ROOT="$SESS" \
      YNAB_SCRUB_PROJECTS_ROOT="$PROJ" \
      YNAB_SCRUB_DESKTOP_CONFIG="$DESK" \
      bash "$SCRUB" ${1:+"$1"} 2>&1
}

contains_token() { printf '%s' "$1" | grep -qF -- "$SYNTH_TOKEN"; }

# ---------------------------------------------------------------------------
echo "== --detect with a plaintext token present =="
out="$(run --detect)"; rc=$?
assert "exits non-zero when a plaintext token is present" "[ $rc -ne 0 ]"
assert "warns that a plaintext token was detected" \
  "printf '%s' \"\$out\" | grep -qF 'PLAINTEXT YNAB TOKEN DETECTED'"
assert "links to the rotation doc" \
  "printf '%s' \"\$out\" | grep -qF 'docs/token-rotation.md'"
assert "never prints the token value" "! contains_token \"\$out\""

# ---------------------------------------------------------------------------
echo "== --verify BEFORE scrub (token still on disk) =="
out="$(run --verify)"; rc=$?
assert "exits non-zero while matches remain" "[ $rc -ne 0 ]"
assert "reports a non-zero TOTAL" \
  "printf '%s' \"\$out\" | grep -E 'TOTAL +[1-9]' >/dev/null"
assert "never prints the token value" "! contains_token \"\$out\""

# ---------------------------------------------------------------------------
echo "== scrub (default mode) =="
before="$(find "$SANDBOX" -type f | sort)"
out="$(run '')"; rc=$?
after="$(find "$SANDBOX" -type f | sort)"
assert "exits 0 on a successful scrub" "[ $rc -eq 0 ]"
assert "prints a per-surface summary (Scanned/Modified)" \
  "printf '%s' \"\$out\" | grep -qF 'Scanned' && printf '%s' \"\$out\" | grep -qF 'Modified'"
assert "never prints the token value" "! contains_token \"\$out\""
assert "writes no backup file and deletes nothing (file set unchanged)" \
  "[ \"\$before\" = \"\$after\" ]"

# Every surface file no longer holds the token, and now holds the marker.
for f in \
  "$SESS/2026-06-12/a.log.md" \
  "$PROJ/-Users-mike-foo/t.jsonl" \
  "$PROJ/-Users-mike-foo/tool-results/r.txt" \
  "$DESK"; do
  assert "token redacted from ${f#$SANDBOX/}" "! grep -qF -- \"\$SYNTH_TOKEN\" \"$f\""
  assert "marker present in ${f#$SANDBOX/}" "grep -qF -- \"\$MARKER\" \"$f\""
done

assert "control file left untouched" \
  "[ \"\$(cat \"$SESS/2026-06-12/control.log.md\")\" = 'nothing secret here' ]"
assert "Desktop config remains valid JSON with structure preserved" \
  "jq -e '.mcpServers.ynab.command == \"bash\"' \"$DESK\" >/dev/null"
assert "Desktop token field now equals the marker" \
  "[ \"\$(jq -r '.mcpServers.ynab.env.YNAB_ACCESS_TOKEN' \"$DESK\")\" = \"\$MARKER\" ]"

# ---------------------------------------------------------------------------
echo "== --verify AFTER scrub (clean) =="
out="$(run --verify)"; rc=$?
assert "exits 0 when no matches remain" "[ $rc -eq 0 ]"
assert "reports a zero TOTAL" \
  "printf '%s' \"\$out\" | grep -E 'TOTAL +0' >/dev/null"
# Per-surface 0 assertions — a TOTAL of 0 alone would still pass if a future
# change silently dropped a surface; assert each surface individually reports 0.
for surface_label in \
  'session logs' \
  'project transcripts' \
  'tool-result caches' \
  'Desktop config' \
  'git-tracked repo tree'; do
  assert "per-surface: '$surface_label' reports 0 matches" \
    "printf '%s' \"\$out\" | grep -E '$surface_label +0' >/dev/null"
done

# ---------------------------------------------------------------------------
echo "== --detect AFTER scrub (marker, not a plaintext token) =="
out="$(run --detect)"; rc=$?
assert "exits 0 once the token is redacted to the marker" "[ $rc -eq 0 ]"

# ---------------------------------------------------------------------------
echo "== scrub is idempotent =="
out="$(run '')"; rc=$?
assert "second scrub exits 0 with zero modified" \
  "[ $rc -eq 0 ] && printf '%s' \"\$out\" | grep -E 'TOTAL +[0-9]+ +0' >/dev/null"
assert "marker is still present after the idempotent second pass" \
  "grep -qF -- \"\$MARKER\" \"$SESS/2026-06-12/a.log.md\""

# ---------------------------------------------------------------------------
echo "== --detect on a config with no YNAB token =="
CLEAN_DESK="$SANDBOX/clean_config.json"
printf '{"mcpServers":{"other":{"command":"bash"}}}\n' > "$CLEAN_DESK"
out="$(printf '%s\n' x \
  | YNAB_SCRUB_DESKTOP_CONFIG="$CLEAN_DESK" bash "$SCRUB" --detect 2>&1)"; rc=$?
assert "exits 0 when no YNAB token field is present" "[ $rc -eq 0 ]"

# ---------------------------------------------------------------------------
echo "== --detect with a missing config (nothing to detect) =="
# The migration hook (#77) may run before a Desktop config exists at all. An
# absent config is a legitimate clean result, NOT a fail-closed case: there is
# no file to misread, so the [ ! -f "$cfg" ] branch must report "nothing to
# detect" and exit 0.
MISSING_DESK="$SANDBOX/does-not-exist.json"
out="$(printf '%s\n' x \
  | YNAB_SCRUB_DESKTOP_CONFIG="$MISSING_DESK" bash "$SCRUB" --detect 2>&1)"; rc=$?
assert "exits 0 when the Desktop config is absent" "[ $rc -eq 0 ]"
assert "reports there is nothing to detect" \
  "printf '%s' \"\$out\" | grep -qF 'Nothing to detect'"

# ---------------------------------------------------------------------------
echo "== --detect FAILS CLOSED on an unparseable config =="
# A config that exists but is malformed JSON must NOT be reported clean — jq's
# failure has to surface as a non-zero exit, not be swallowed into a false
# "no token (good)". This is the gate #77 invokes before removing the connector.
BAD_DESK="$SANDBOX/malformed_config.json"
printf '{"mcpServers": {"ynab": {"env": {"YNAB_ACCESS_TOKEN": "%s"\n' "$SYNTH_TOKEN" \
  > "$BAD_DESK"   # truncated/unbalanced JSON — jq cannot parse it
out="$(printf '%s\n' x \
  | YNAB_SCRUB_DESKTOP_CONFIG="$BAD_DESK" bash "$SCRUB" --detect 2>&1)"; rc=$?
assert "exits non-zero on a malformed config (fails closed)" "[ $rc -ne 0 ]"
assert "does NOT falsely report the config clean" \
  "! printf '%s' \"\$out\" | grep -qF 'No plaintext YNAB token'"
assert "warns the config could not be parsed" \
  "printf '%s' \"\$out\" | grep -qiE 'unparseable|could not parse|cannot certify'"
assert "never prints the token value on the parse failure" "! contains_token \"\$out\""

# ---------------------------------------------------------------------------
# FAIL-CLOSED behaviour: a file/surface the tool cannot read or enumerate must
# never be reported clean — it forces a non-zero exit so a leaked-token copy
# can't hide behind a swallowed error. (chmod 000 is meaningless under root, so
# the unreadable-file cases are skipped there.)
# ---------------------------------------------------------------------------
echo "== --verify FAILS CLOSED on an unreadable file =="
if [ "$(id -u)" -eq 0 ]; then
  echo "  (skipped: running as root — chmod 000 wouldn't block reads)"
else
  UNREAD="$SESS/2026-06-12/unreadable.log.md"
  printf 'leaked %s here\n' "$SYNTH_TOKEN" > "$UNREAD"
  chmod 000 "$UNREAD"
  out="$(run --verify)"; rc=$?
  assert "verify exits non-zero when a file can't be read" "[ $rc -ne 0 ]"
  assert "verify flags it unscannable (fails closed, not reported clean)" \
    "printf '%s' \"\$out\" | grep -qiE 'unscannable|could not scan|UNRESOLVED'"
  assert "verify still never prints the token value on failure" "! contains_token \"\$out\""
  chmod 644 "$UNREAD"
  rm -f "$UNREAD"
fi

# ---------------------------------------------------------------------------
echo "== scrub FAILS CLOSED on an unreadable file =="
if [ "$(id -u)" -eq 0 ]; then
  echo "  (skipped: running as root — chmod 000 wouldn't block reads)"
else
  UNREAD="$SESS/2026-06-12/unreadable.log.md"
  printf 'leaked %s here\n' "$SYNTH_TOKEN" > "$UNREAD"
  chmod 000 "$UNREAD"
  out="$(run '')"; rc=$?
  assert "scrub exits non-zero when a file can't be read" "[ $rc -ne 0 ]"
  assert "scrub reports a non-zero Unreadable count" \
    "printf '%s' \"\$out\" | grep -qiE 'unreadable|could not read'"
  # Assert the Unreadable column BY VALUE, not just that some warning text exists
  # — one unreadable file under the session-logs surface must show as exactly 1
  # in that surface's row (Surface | Scanned | Modified | Unreadable), mirroring
  # the per-surface integer assertions on the --verify side. A loose substring
  # match would pass even on a miscount.
  assert "scrub Unreadable column for session logs equals 1 (asserted by value)" \
    "printf '%s' \"\$out\" | grep -E 'session logs +[0-9]+ +[0-9]+ +1\$' >/dev/null"
  assert "scrub TOTAL Unreadable equals 1 (asserted by value)" \
    "printf '%s' \"\$out\" | grep -E 'TOTAL +[0-9]+ +[0-9]+ +1\$' >/dev/null"
  assert "scrub never prints the token value even on failure" "! contains_token \"\$out\""
  chmod 644 "$UNREAD"
  assert "the unreadable file still holds the token (NOT silently skipped-clean)" \
    "grep -qF -- \"\$SYNTH_TOKEN\" \"$UNREAD\""
  rm -f "$UNREAD"
fi

# ---------------------------------------------------------------------------
echo "== --verify FAILS CLOSED when the repo tree can't be enumerated =="
NOTGIT="$(mktemp -d)"
out="$(printf '%s\n' "$SYNTH_TOKEN" \
  | YNAB_SCRUB_SESSIONS_ROOT="$SESS" \
    YNAB_SCRUB_PROJECTS_ROOT="$PROJ" \
    YNAB_SCRUB_DESKTOP_CONFIG="$DESK" \
    YNAB_SCRUB_REPO_ROOT="$NOTGIT" \
    bash "$SCRUB" --verify 2>&1)"; rc=$?
assert "verify exits non-zero when the repo surface can't be git-enumerated" "[ $rc -ne 0 ]"
assert "verify flags the repo tree unscannable, not zero-scanned-clean" \
  "printf '%s' \"\$out\" | grep -qiE 'unscannable|not fully enumerated|could not scan'"
assert "verify never prints the token value on the repo-enumeration failure" "! contains_token \"\$out\""
rm -rf "$NOTGIT"

# ---------------------------------------------------------------------------
# FAIL-CLOSED on an ENUMERATION failure of a REAL on-disk surface. The repo test
# above only exercises _collect_repo (git ls-files); the three real surfaces
# (sessions/jsonl/tool-results) walk via _collect + `find`. This drives `find`
# itself to exit non-zero mid-walk — a chmod 000 sub-directory under $SESS it
# can't descend into — so _collect flips _ENUM_STATUS=FAIL. That is distinct from
# an unreadable *file* (count_in_file -> 2, tested above): here the surface can't
# be fully enumerated, so it must be reported "not fully enumerated" and force a
# non-zero exit, never reported clean. (chmod 000 is meaningless under root.)
# ---------------------------------------------------------------------------
echo "== --verify FAILS CLOSED when a real surface can't be fully enumerated =="
if [ "$(id -u)" -eq 0 ]; then
  echo "  (skipped: running as root — chmod 000 wouldn't block find)"
else
  LOCKED="$SESS/2026-06-12/locked"
  mkdir -p "$LOCKED"
  chmod 000 "$LOCKED"
  out="$(run --verify)"; rc=$?
  assert "verify exits non-zero when find can't fully enumerate the surface" "[ $rc -ne 0 ]"
  assert "verify flags the session-logs surface not fully enumerated" \
    "printf '%s' \"\$out\" | grep -qF 'not fully enumerated: session logs'"
  assert "verify counts the un-enumerated surface as Unscannable (value = 1)" \
    "printf '%s' \"\$out\" | grep -E 'session logs +0 +1\$' >/dev/null"
  assert "verify never prints the token value on an enumeration failure" "! contains_token \"\$out\""
  chmod 755 "$LOCKED"
  rmdir "$LOCKED"
fi

# ---------------------------------------------------------------------------
echo "== scrub FAILS CLOSED when a real surface can't be fully enumerated =="
if [ "$(id -u)" -eq 0 ]; then
  echo "  (skipped: running as root — chmod 000 wouldn't block find)"
else
  LOCKED="$SESS/2026-06-12/locked"
  mkdir -p "$LOCKED"
  chmod 000 "$LOCKED"
  out="$(run '')"; rc=$?
  assert "scrub exits non-zero when find can't fully enumerate the surface" "[ $rc -ne 0 ]"
  assert "scrub flags the session-logs surface not fully enumerated (left unscrubbed)" \
    "printf '%s' \"\$out\" | grep -qF 'not fully enumerated (left unscrubbed): session logs'"
  assert "scrub counts the un-enumerated surface as Unreadable (value = 1)" \
    "printf '%s' \"\$out\" | grep -E 'session logs +[0-9]+ +[0-9]+ +1\$' >/dev/null"
  assert "scrub never prints the token value on an enumeration failure" "! contains_token \"\$out\""
  chmod 755 "$LOCKED"
  rmdir "$LOCKED"
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
