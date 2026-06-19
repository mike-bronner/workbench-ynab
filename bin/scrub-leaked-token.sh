#!/usr/bin/env bash
#
# scrub-leaked-token.sh — remediate a leaked YNAB personal access token.
#
# A token that has touched a plaintext config or a log is PERMANENTLY
# compromised. The full remediation is two steps:
#   1. ROTATE  — revoke the old token and mint a new one (see
#                docs/token-rotation.md). This script does NOT rotate; rotation
#                is a manual ceremony you perform at app.ynab.com.
#   2. SCRUB   — redact the on-disk copies of the old token. That is what this
#                script does.
#
# Modes:
#   (no flag)   Redact every occurrence of the token across the known on-disk
#               leak surfaces, in place. Prints a per-surface summary.
#   --verify    Re-scan the leak surfaces *and* the git-tracked repo tree and
#               report any remaining matches. Exits non-zero if any are found.
#   --detect    Warn (exit non-zero) if a plaintext YNAB token is present in the
#               Claude Desktop config. This is the hook the migration command
#               (#77) invokes before offering to remove the legacy connector.
#   --help      Show usage.
#
# SECRET HYGIENE — the whole point of this tool:
#   * The token is ALWAYS read interactively via `read -rs` (or piped on stdin
#     for tests). It is NEVER accepted as a CLI argument, an environment
#     variable, or a hard-coded literal.
#   * The token is NEVER printed to stdout or stderr.
#   * The token is handed to `perl` via a child-process environment variable
#     rather than as an argv string, so it never appears in the process argv
#     listing (`ps aux`), and it is never written to a temporary file on disk.
#     (An environment variable is still readable by the SAME user via `ps eww`
#     or /proc/<pid>/environ — env-over-argv narrows the exposure to same-user
#     introspection during the brief perl invocation; it does not eliminate it.)
#
# FAIL CLOSED — a remediation tool that cannot read a file must never report it
# clean. Every count distinguishes a genuine zero-match from a file it could not
# read or scan; an unscannable file is surfaced and forces a non-zero exit so a
# leaked-token copy can never hide behind a swallowed error.
#
set -euo pipefail

readonly REDACTION_MARKER='[YNAB-TOKEN-REDACTED]'

# Resolve the repo root from this script's location (bin/ -> repo root). Used by
# --verify to scan the git-tracked tree. The YNAB_SCRUB_REPO_ROOT override (like
# the surface overrides below) lets the test harness point the repo surface at a
# sandbox to exercise the enumeration-failure path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${YNAB_SCRUB_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Leak-surface roots. Defaults are the real on-disk paths from the incident;
# the YNAB_SCRUB_* overrides exist so the test harness can point at a sandbox.
SESSIONS_ROOT="${YNAB_SCRUB_SESSIONS_ROOT:-$HOME/Documents/Claude/Memory/sessions}"
PROJECTS_ROOT="${YNAB_SCRUB_PROJECTS_ROOT:-$HOME/.claude/projects}"
DESKTOP_CONFIG="${YNAB_SCRUB_DESKTOP_CONFIG:-$HOME/Library/Application Support/Claude/claude_desktop_config.json}"

# The token, once read. Module-scoped so the perl helpers can reach it via env.
TOKEN=""

# Enumeration accumulators (filled by enumerate/_collect; subshell-local under
# the process substitution that drives each surface loop).
_ENUM_FILES=()
_ENUM_STATUS=OK

die() { printf '%s\n' "$*" >&2; exit 1; }

# Read the token without echoing it. Works interactively (a TTY) and when the
# value is piped on stdin (the test harness). The prompt goes to stderr so it
# never pollutes captured stdout.
read_token() {
  local prompt="$1" tok=""
  printf '%s' "$prompt" >&2
  # -s silences the echo; -r keeps backslashes literal. EOF on a piped stdin
  # returns non-zero with the value still captured, so tolerate it.
  IFS= read -rs tok || true
  printf '\n' >&2
  [ -n "$tok" ] || die "No token provided — aborting."
  TOKEN="$tok"
}

# Count occurrences of the token in one file. Prints the integer match count and
# returns 0 on success. Returns non-zero (printing nothing) when the file cannot
# be read or perl cannot scan it — this is FAIL CLOSED: a scan failure is NOT a
# zero-match, and the caller must treat it as unresolved rather than clean. The
# token is passed to perl via the environment (never argv) and matched literally
# via quotemeta.
count_in_file() {
  local file="$1" out rc
  # An unreadable file is a scan failure, not a clean file.
  [ -r "$file" ] || return 2
  if out="$(YNAB_SCRUB_TOK="$TOKEN" perl -0777 -ne '
      my $t = quotemeta($ENV{YNAB_SCRUB_TOK});
      my $c = () = /$t/g;
      print $c;
    ' "$file" 2>/dev/null)"; then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -eq 0 ] || return 2
  # perl must have produced a pure integer; anything else means it didn't scan
  # the file cleanly, so fail closed.
  case "$out" in
    ''|*[!0-9]*) return 2 ;;
  esac
  printf '%s' "$out"
}

# Redact every occurrence in one file, in place. No backup file is written and
# no file is deleted (perl -i with an empty suffix).
redact_in_file() {
  YNAB_SCRUB_TOK="$TOKEN" perl -0777 -i -pe '
    my $t = quotemeta($ENV{YNAB_SCRUB_TOK});
    s/$t/[YNAB-TOKEN-REDACTED]/g;
  ' "$1"
}

# Run a NUL-emitting file-list command ("$@"), append its output to _ENUM_FILES,
# and flip _ENUM_STATUS to FAIL if the command exited non-zero (e.g. a `find`
# permission error mid-walk). A FAIL surface is treated as UNSCANNABLE by the
# callers — fail closed — instead of being silently reported clean. Only the
# command's numeric exit code transits the temp file; the token is never
# involved here.
_collect() {
  local rc_file rc f
  rc_file="$(mktemp)"
  while IFS= read -r -d '' f; do _ENUM_FILES+=("$f"); done \
    < <( "$@" 2>/dev/null; printf '%s' "$?" >"$rc_file" )
  rc="$(cat "$rc_file" 2>/dev/null || printf '1')"
  rm -f "$rc_file"
  [ "$rc" = 0 ] || _ENUM_STATUS=FAIL
}

# Enumerate the git-tracked repo tree. Fail closed if REPO_ROOT isn't a readable
# git work tree or `git ls-files` errors — otherwise a git failure would be
# swallowed and the surface would falsely report zero files scanned.
_collect_repo() {
  if [ "$(git -C "$REPO_ROOT" rev-parse --is-inside-work-tree 2>/dev/null)" != true ]; then
    _ENUM_STATUS=FAIL
    return 0
  fi
  local rc_file rc rel
  rc_file="$(mktemp)"
  while IFS= read -r -d '' rel; do _ENUM_FILES+=("$REPO_ROOT/$rel"); done \
    < <( git -C "$REPO_ROOT" ls-files -z 2>/dev/null; printf '%s' "$?" >"$rc_file" )
  rc="$(cat "$rc_file" 2>/dev/null || printf '1')"
  rm -f "$rc_file"
  [ "$rc" = 0 ] || _ENUM_STATUS=FAIL
}

# Emit a NUL-delimited record stream for a named surface: a LEADING status
# record ('OK' or 'FAIL'), then one record per file. A missing root is a
# legitimate empty surface (status OK, zero files). 'FAIL' means an existing
# surface could not be fully enumerated — the caller fails closed.
enumerate() {
  _ENUM_FILES=()
  _ENUM_STATUS=OK
  case "$1" in
    sessions) [ -d "$SESSIONS_ROOT" ] && _collect find "$SESSIONS_ROOT" -type f -name '*.log.md' -print0 ;;
    jsonl)    [ -d "$PROJECTS_ROOT" ] && _collect find "$PROJECTS_ROOT" -type f -name '*.jsonl' -print0 ;;
    toolres)  [ -d "$PROJECTS_ROOT" ] && _collect find "$PROJECTS_ROOT" -type f -path '*/tool-results/*.txt' -print0 ;;
    desktop)  [ -f "$DESKTOP_CONFIG" ] && _ENUM_FILES+=("$DESKTOP_CONFIG") ;;
    repo)     _collect_repo ;;
  esac
  printf '%s\0' "$_ENUM_STATUS"
  # set -u-safe expansion: an empty array must expand to nothing, not error
  # (older bash, incl. macOS 3.2, treats "${arr[@]}" on an empty array as unset).
  local f
  for f in ${_ENUM_FILES[@]+"${_ENUM_FILES[@]}"}; do printf '%s\0' "$f"; done
  return 0
}

do_scrub() {
  read_token 'Enter the OLD (leaked) YNAB token to scrub (input hidden): '
  printf 'Redacting every occurrence with %s\n\n' "$REDACTION_MARKER"
  printf '%-30s %9s %9s %11s\n' 'Surface' 'Scanned' 'Modified' 'Unreadable'
  printf '%-30s %9s %9s %11s\n' '------------------------------' '---------' '---------' '-----------'

  local total_scanned=0 total_modified=0 total_unreadable=0
  local surfaces=(
    "sessions:session logs"
    "jsonl:project transcripts"
    "toolres:tool-result caches"
    "desktop:Desktop config"
  )
  for entry in "${surfaces[@]}"; do
    local key="${entry%%:*}" label="${entry#*:}"
    local scanned=0 modified=0 unreadable=0 first=1 n
    while IFS= read -r -d '' rec; do
      if [ "$first" = 1 ]; then
        first=0
        if [ "$rec" != OK ]; then
          unreadable=$((unreadable + 1))
          printf '  ! surface not fully enumerated (left unscrubbed): %s\n' "$label" >&2
        fi
        continue
      fi
      scanned=$((scanned + 1))
      if n="$(count_in_file "$rec")"; then
        if [ "$n" -gt 0 ]; then
          redact_in_file "$rec"
          modified=$((modified + 1))
        fi
      else
        # Could not read this file — do NOT count it clean; leave it unscrubbed.
        unreadable=$((unreadable + 1))
        printf '  ! could not read (left unscrubbed): %s\n' "$rec" >&2
      fi
    done < <(enumerate "$key")
    printf '%-30s %9d %9d %11d\n' "$label" "$scanned" "$modified" "$unreadable"
    total_scanned=$((total_scanned + scanned))
    total_modified=$((total_modified + modified))
    total_unreadable=$((total_unreadable + unreadable))
  done

  printf '%-30s %9s %9s %11s\n' '------------------------------' '---------' '---------' '-----------'
  printf '%-30s %9d %9d %11d\n\n' 'TOTAL' "$total_scanned" "$total_modified" "$total_unreadable"
  printf 'Done — %d file(s) modified across %d scanned.\n' "$total_modified" "$total_scanned"
  if [ "$total_unreadable" -gt 0 ]; then
    printf '\nWARNING — %d file(s)/surface(s) could not be read and were left\n' "$total_unreadable" >&2
    printf 'UNSCRUBBED; the leaked token may still be present in them. Fix the\n' >&2
    printf 'permissions (or re-run with sufficient privileges), scrub again, and\n' >&2
    printf 'confirm with `%s --verify`.\n' "$(basename "$0")" >&2
    return 1
  fi
  printf 'Now run `%s --verify` to confirm zero remaining matches.\n' "$(basename "$0")"
}

do_verify() {
  read_token 'Enter the OLD (leaked) YNAB token to verify against (input hidden): '
  printf 'Scanning for any remaining occurrences...\n\n'
  printf '%-30s %9s %12s\n' 'Surface' 'Matches' 'Unscannable'
  printf '%-30s %9s %12s\n' '------------------------------' '---------' '------------'

  local total=0 total_unscannable=0
  local surfaces=(
    "sessions:session logs"
    "jsonl:project transcripts"
    "toolres:tool-result caches"
    "desktop:Desktop config"
    "repo:git-tracked repo tree"
  )
  for entry in "${surfaces[@]}"; do
    local key="${entry%%:*}" label="${entry#*:}"
    local matches=0 unscannable=0 first=1 n
    while IFS= read -r -d '' rec; do
      if [ "$first" = 1 ]; then
        first=0
        if [ "$rec" != OK ]; then
          unscannable=$((unscannable + 1))
          printf '  ! surface not fully enumerated: %s\n' "$label" >&2
        fi
        continue
      fi
      if n="$(count_in_file "$rec")"; then
        matches=$((matches + n))
      else
        unscannable=$((unscannable + 1))
        printf '  ! could not scan (treated as UNRESOLVED): %s\n' "$rec" >&2
      fi
    done < <(enumerate "$key")
    printf '%-30s %9d %12d\n' "$label" "$matches" "$unscannable"
    total=$((total + matches))
    total_unscannable=$((total_unscannable + unscannable))
  done

  printf '%-30s %9s %12s\n' '------------------------------' '---------' '------------'
  printf '%-30s %9d %12d\n\n' 'TOTAL' "$total" "$total_unscannable"
  if [ "$total" -gt 0 ] || [ "$total_unscannable" -gt 0 ]; then
    [ "$total" -gt 0 ] && \
      printf 'FAIL — %d remaining match(es). Re-run the scrub.\n' "$total" >&2
    [ "$total_unscannable" -gt 0 ] && \
      printf 'FAIL — %d file(s)/surface(s) could not be scanned; cannot certify them clean. Failing closed.\n' "$total_unscannable" >&2
    return 1
  fi
  printf 'OK — no remaining matches across any surface.\n'
}

do_detect() {
  local cfg="$DESKTOP_CONFIG"
  if [ ! -f "$cfg" ]; then
    printf 'No Claude Desktop config at:\n  %s\nNothing to detect.\n' "$cfg"
    return 0
  fi
  local val
  val="$(jq -r '.mcpServers.ynab.env.YNAB_ACCESS_TOKEN // empty' "$cfg" 2>/dev/null || true)"
  if [ -z "$val" ] || [ "$val" = "$REDACTION_MARKER" ]; then
    printf 'No plaintext YNAB token in the Desktop config (good).\n'
    return 0
  fi
  # A plaintext token is present. Warn loudly — but NEVER echo its value.
  printf '⚠️  PLAINTEXT YNAB TOKEN DETECTED\n' >&2
  printf '    Location: %s\n' "$cfg" >&2
  printf '    Field:    mcpServers.ynab.env.YNAB_ACCESS_TOKEN\n' >&2
  printf '    A token in a plaintext config is compromised. ROTATE it before\n' >&2
  printf '    removing the legacy connector — see docs/token-rotation.md, then\n' >&2
  printf '    run `%s` (no flag) to scrub the on-disk copies.\n' "$(basename "$0")" >&2
  return 1
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [--verify | --detect | --help]

  (no flag)   Redact every occurrence of a leaked YNAB token across the known
              on-disk leak surfaces, in place. Prompts for the token (read -rs).
  --verify    Re-scan the leak surfaces and the git-tracked repo tree; report
              remaining matches per surface and exit non-zero if any are found.
  --detect    Warn (exit non-zero) if a plaintext YNAB token is present in the
              Claude Desktop config. Used by the migration command (#77).
  --help      Show this help.

The token is always read interactively (never a CLI arg, env var, or literal)
and is never printed. Rotate first — see docs/token-rotation.md.
EOF
}

main() {
  case "${1:-}" in
    ''|scrub)  do_scrub ;;
    --verify)  do_verify ;;
    --detect)  do_detect ;;
    -h|--help) usage ;;
    *)         usage >&2; die "Unknown argument: $1" ;;
  esac
}

main "$@"
