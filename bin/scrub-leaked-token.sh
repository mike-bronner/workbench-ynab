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
#     rather than as an argv string, so it never appears in `ps` output, and it
#     is never written to a temporary file on disk.
#
set -euo pipefail

readonly REDACTION_MARKER='[YNAB-TOKEN-REDACTED]'

# Resolve the repo root from this script's location (bin/ -> repo root). Used by
# --verify to scan the git-tracked tree.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Leak-surface roots. Defaults are the real on-disk paths from the incident;
# the YNAB_SCRUB_* overrides exist so the test harness can point at a sandbox.
SESSIONS_ROOT="${YNAB_SCRUB_SESSIONS_ROOT:-$HOME/Documents/Claude/Memory/sessions}"
PROJECTS_ROOT="${YNAB_SCRUB_PROJECTS_ROOT:-$HOME/.claude/projects}"
DESKTOP_CONFIG="${YNAB_SCRUB_DESKTOP_CONFIG:-$HOME/Library/Application Support/Claude/claude_desktop_config.json}"

# The token, once read. Module-scoped so the perl helpers can reach it via env.
TOKEN=""

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

# Count occurrences of the token in one file. The token is passed to perl via
# the environment (never argv), and matched literally via quotemeta.
count_in_file() {
  YNAB_SCRUB_TOK="$TOKEN" perl -0777 -ne '
    my $t = quotemeta($ENV{YNAB_SCRUB_TOK});
    my $c = () = /$t/g;
    print $c;
  ' "$1" 2>/dev/null || printf '0'
}

# Redact every occurrence in one file, in place. No backup file is written and
# no file is deleted (perl -i with an empty suffix).
redact_in_file() {
  YNAB_SCRUB_TOK="$TOKEN" perl -0777 -i -pe '
    my $t = quotemeta($ENV{YNAB_SCRUB_TOK});
    s/$t/[YNAB-TOKEN-REDACTED]/g;
  ' "$1"
}

# Emit the NUL-delimited list of files for a named surface. Missing roots emit
# nothing (and the surface simply reports zero scanned).
enumerate() {
  case "$1" in
    sessions) [ -d "$SESSIONS_ROOT" ] && find "$SESSIONS_ROOT" -type f -name '*.log.md' -print0 2>/dev/null ;;
    jsonl)    [ -d "$PROJECTS_ROOT" ] && find "$PROJECTS_ROOT" -type f -name '*.jsonl' -print0 2>/dev/null ;;
    toolres)  [ -d "$PROJECTS_ROOT" ] && find "$PROJECTS_ROOT" -type f -path '*/tool-results/*.txt' -print0 2>/dev/null ;;
    desktop)  [ -f "$DESKTOP_CONFIG" ] && printf '%s\0' "$DESKTOP_CONFIG" ;;
    repo)     ( cd "$REPO_ROOT" && git ls-files -z 2>/dev/null ) \
                | while IFS= read -r -d '' rel; do printf '%s\0' "$REPO_ROOT/$rel"; done ;;
  esac
  return 0
}

do_scrub() {
  read_token 'Enter the OLD (leaked) YNAB token to scrub (input hidden): '
  printf 'Redacting every occurrence with %s\n\n' "$REDACTION_MARKER"
  printf '%-30s %9s %9s\n' 'Surface' 'Scanned' 'Modified'
  printf '%-30s %9s %9s\n' '------------------------------' '---------' '---------'

  local total_scanned=0 total_modified=0
  local surfaces=(
    "sessions:session logs"
    "jsonl:project transcripts"
    "toolres:tool-result caches"
    "desktop:Desktop config"
  )
  for entry in "${surfaces[@]}"; do
    local key="${entry%%:*}" label="${entry#*:}"
    local scanned=0 modified=0 n
    while IFS= read -r -d '' file; do
      scanned=$((scanned + 1))
      n="$(count_in_file "$file")"
      if [ "${n:-0}" -gt 0 ]; then
        redact_in_file "$file"
        modified=$((modified + 1))
      fi
    done < <(enumerate "$key")
    printf '%-30s %9d %9d\n' "$label" "$scanned" "$modified"
    total_scanned=$((total_scanned + scanned))
    total_modified=$((total_modified + modified))
  done

  printf '%-30s %9s %9s\n' '------------------------------' '---------' '---------'
  printf '%-30s %9d %9d\n\n' 'TOTAL' "$total_scanned" "$total_modified"
  printf 'Done — %d file(s) modified across %d scanned.\n' "$total_modified" "$total_scanned"
  printf 'Now run `%s --verify` to confirm zero remaining matches.\n' "$(basename "$0")"
}

do_verify() {
  read_token 'Enter the OLD (leaked) YNAB token to verify against (input hidden): '
  printf 'Scanning for any remaining occurrences...\n\n'
  printf '%-30s %9s\n' 'Surface' 'Matches'
  printf '%-30s %9s\n' '------------------------------' '---------'

  local total=0
  local surfaces=(
    "sessions:session logs"
    "jsonl:project transcripts"
    "toolres:tool-result caches"
    "desktop:Desktop config"
    "repo:git-tracked repo tree"
  )
  for entry in "${surfaces[@]}"; do
    local key="${entry%%:*}" label="${entry#*:}"
    local matches=0 n
    while IFS= read -r -d '' file; do
      n="$(count_in_file "$file")"
      matches=$((matches + ${n:-0}))
    done < <(enumerate "$key")
    printf '%-30s %9d\n' "$label" "$matches"
    total=$((total + matches))
  done

  printf '%-30s %9s\n' '------------------------------' '---------'
  printf '%-30s %9d\n\n' 'TOTAL' "$total"
  if [ "$total" -gt 0 ]; then
    printf 'FAIL — %d remaining match(es). Re-run the scrub.\n' "$total" >&2
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
