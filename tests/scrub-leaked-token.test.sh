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

# ---------------------------------------------------------------------------
echo "== --detect AFTER scrub (marker, not a plaintext token) =="
out="$(run --detect)"; rc=$?
assert "exits 0 once the token is redacted to the marker" "[ $rc -eq 0 ]"

# ---------------------------------------------------------------------------
echo "== scrub is idempotent =="
out="$(run '')"; rc=$?
assert "second scrub exits 0 with zero modified" \
  "[ $rc -eq 0 ] && printf '%s' \"\$out\" | grep -E 'TOTAL +[0-9]+ +0' >/dev/null"

# ---------------------------------------------------------------------------
echo "== --detect on a config with no YNAB token =="
CLEAN_DESK="$SANDBOX/clean_config.json"
printf '{"mcpServers":{"other":{"command":"bash"}}}\n' > "$CLEAN_DESK"
out="$(printf '%s\n' x \
  | YNAB_SCRUB_DESKTOP_CONFIG="$CLEAN_DESK" bash "$SCRUB" --detect 2>&1)"; rc=$?
assert "exits 0 when no YNAB token field is present" "[ $rc -eq 0 ]"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
