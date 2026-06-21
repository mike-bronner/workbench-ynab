#!/usr/bin/env bash
#
# ynab-migrate.sh — deterministic, idempotent file operations behind the
# workbench-ynab legacy-migration command (commands/ynab-migrate.md, issue #77).
#
# WHAT THIS IS
#   `/workbench-ynab:ynab-migrate` is an agent-orchestrated ceremony: it asks the
#   user, calls MCP tools, and reads the macOS Keychain. The few operations that
#   MUTATE FILES on disk — removing the legacy Desktop `ynab` connector block and
#   the deprecated prototype task directories — are not judgement calls. They are
#   mechanical, must be byte-careful (never blind-overwrite the Desktop config),
#   and must be safe to re-run. Those live here as subcommands so they are
#   unit-testable and idempotent by construction — exactly as
#   bin/scrub-leaked-token.sh --detect is the tested hook the same command calls.
#
# SUBCOMMANDS
#   detect-connector      Report whether the legacy Desktop `ynab` connector
#                         (mcpServers.ynab running @dizzlkheinz/ynab-mcpb) is
#                         present. Exit 0 present, 1 absent, 2 unparseable config.
#   remove-connector      Remove ONLY the mcpServers.ynab block via jq, preserving
#                         every other server. Idempotent — a no-op when already
#                         absent. Exit 0 ok, 2 on a config it cannot parse/rewrite.
#   detect-task-dirs      Report which deprecated prototype task directories exist
#                         under the Scheduled root. Exit 0 if any exist, 1 if none.
#   remove-task-dir NAME  Remove ONE deprecated prototype task directory. NAME must
#                         be a known deprecated name — never an arbitrary path — so
#                         a bad argument can never rm -rf the wrong thing.
#                         Idempotent. Exit 0 ok, 2 on a rejected name.
#
# PATH OVERRIDES (defaults are the real on-disk locations; the overrides let the
# test harness point every surface at a sandbox):
#   YNAB_DESKTOP_CONFIG   Claude Desktop config JSON.
#   YNAB_SCHEDULED_ROOT   Root holding the prototype scheduled-task directories.
#
# FAIL CLOSED: a Desktop config that exists but cannot be parsed is NEVER treated
# as "no connector" — the connector subcommands exit non-zero so a malformed or
# half-written config can't silently slip past the migration.
#
# ORDER ENFORCEMENT is the COMMAND's job, not this helper's: the command confirms
# token rotation (issue #73) and verifies the vendored plugin works before it ever
# calls remove-connector. These subcommands are pure mechanism.
#
set -euo pipefail

DESKTOP_CONFIG="${YNAB_DESKTOP_CONFIG:-$HOME/Library/Application Support/Claude/claude_desktop_config.json}"
SCHEDULED_ROOT="${YNAB_SCHEDULED_ROOT:-$HOME/Documents/Claude/Scheduled}"

# The npx package the legacy standalone connector runs. Used to tell the legacy
# `ynab` connector apart from any unrelated server a user might have named "ynab".
readonly LEGACY_PKG='@dizzlkheinz/ynab-mcpb'

# The deprecated prototype task directories this migration retires. remove-task-dir
# accepts ONLY these names so a bad argument can never rm -rf an arbitrary path.
readonly DEPRECATED_DIRS=(ynab-financial-review ynab-cleanup-remaining)

die() { printf '%s\n' "$*" >&2; exit 1; }

# Probe the Desktop config. Returns: 0 = present and valid JSON; 1 = missing
# (nothing there); 2 = present but jq cannot parse it (fail closed). Prints
# nothing — callers decide what to say.
_probe_config() {
  [ -f "$DESKTOP_CONFIG" ] || return 1
  jq -e . "$DESKTOP_CONFIG" >/dev/null 2>&1 || return 2
  return 0
}

do_detect_connector() {
  local rc=0
  _probe_config || rc=$?
  if [ "$rc" -eq 1 ]; then
    printf 'No Claude Desktop config at:\n  %s\nNo legacy connector to migrate.\n' "$DESKTOP_CONFIG"
    return 1
  fi
  if [ "$rc" -eq 2 ]; then
    printf '⚠️  UNPARSEABLE DESKTOP CONFIG — cannot certify it connector-free\n' >&2
    printf '    Location: %s\n' "$DESKTOP_CONFIG" >&2
    printf '    jq could not parse the config (malformed JSON, or jq is missing).\n' >&2
    printf '    Inspect it by hand before migrating.\n' >&2
    return 2
  fi
  local has_ynab pkg_match
  has_ynab="$(jq -r '(.mcpServers // {}) | has("ynab")' "$DESKTOP_CONFIG")"
  if [ "$has_ynab" != true ]; then
    printf 'No legacy "ynab" connector in the Desktop config (good — nothing to remove).\n'
    return 1
  fi
  pkg_match="$(jq -r --arg pkg "$LEGACY_PKG" '
    [ (.mcpServers.ynab.args // [])[] | select(type == "string") | select(contains($pkg)) ] | length > 0
  ' "$DESKTOP_CONFIG")"
  if [ "$pkg_match" = true ]; then
    printf 'LEGACY CONNECTOR PRESENT — mcpServers.ynab runs %s\n' "$LEGACY_PKG"
    printf '  Config: %s\n' "$DESKTOP_CONFIG"
    return 0
  fi
  printf 'An "ynab" connector exists but does NOT run %s — leaving it untouched.\n' "$LEGACY_PKG"
  return 1
}

do_remove_connector() {
  local rc=0
  _probe_config || rc=$?
  if [ "$rc" -eq 1 ]; then
    printf 'No Claude Desktop config — nothing to remove (already done).\n'
    return 0
  fi
  if [ "$rc" -eq 2 ]; then
    printf '⚠️  UNPARSEABLE DESKTOP CONFIG — refusing to edit it\n' >&2
    printf '    Location: %s\n' "$DESKTOP_CONFIG" >&2
    printf '    Fix the JSON by hand, then re-run — see docs/token-rotation.md.\n' >&2
    return 2
  fi
  local has_ynab
  has_ynab="$(jq -r '(.mcpServers // {}) | has("ynab")' "$DESKTOP_CONFIG")"
  if [ "$has_ynab" != true ]; then
    printf 'mcpServers.ynab already absent — nothing to remove (already done).\n'
    return 0
  fi
  # Remove ONLY the ynab key; every other server is preserved. Write to a temp
  # file and validate it is JSON before replacing the original, so a jq failure
  # can never leave a half-written Desktop config behind.
  local tmp
  tmp="$(mktemp)"
  if jq 'del(.mcpServers.ynab)' "$DESKTOP_CONFIG" > "$tmp" && jq -e . "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$DESKTOP_CONFIG"
    printf 'Removed mcpServers.ynab from the Desktop config (other servers preserved).\n'
    return 0
  fi
  rm -f "$tmp"
  die "Failed to rewrite the Desktop config — left unchanged: $DESKTOP_CONFIG"
}

do_detect_task_dirs() {
  local found=0 d
  printf 'Scanning for deprecated prototype task directories under:\n  %s\n' "$SCHEDULED_ROOT"
  for d in "${DEPRECATED_DIRS[@]}"; do
    if [ -d "$SCHEDULED_ROOT/$d" ]; then
      printf '  • present: %s\n' "$d"
      found=$((found + 1))
    else
      printf '  • absent:  %s\n' "$d"
    fi
  done
  [ "$found" -gt 0 ]
}

do_remove_task_dir() {
  local name="${1:-}" allowed=0 d
  [ -n "$name" ] || die "remove-task-dir requires a directory name"
  for d in "${DEPRECATED_DIRS[@]}"; do
    [ "$name" = "$d" ] && allowed=1
  done
  if [ "$allowed" -ne 1 ]; then
    printf '✖ Refusing to remove %q — not a known deprecated task directory.\n' "$name" >&2
    printf '  Allowed: %s\n' "${DEPRECATED_DIRS[*]}" >&2
    return 2
  fi
  local target="$SCHEDULED_ROOT/$name"
  if [ ! -e "$target" ]; then
    printf '%s already absent — nothing to remove (already done).\n' "$name"
    return 0
  fi
  rm -rf "$target"
  printf 'Removed deprecated task directory: %s\n' "$target"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <subcommand> [args]

  detect-connector      Report whether the legacy Desktop \`ynab\` connector
                        (running $LEGACY_PKG) is present.
                        Exit 0 present, 1 absent, 2 unparseable config.
  remove-connector      Remove ONLY the mcpServers.ynab block (jq, never a blind
                        overwrite); preserves every other server. Idempotent.
  detect-task-dirs      Report which deprecated prototype task directories exist
                        under the Scheduled root. Exit 0 if any exist, else 1.
  remove-task-dir NAME  Remove one known deprecated task directory. Idempotent.
  -h, --help            Show this help.

Path overrides: YNAB_DESKTOP_CONFIG, YNAB_SCHEDULED_ROOT (see the header).
EOF
}

main() {
  case "${1:-}" in
    detect-connector)  do_detect_connector ;;
    remove-connector)  do_remove_connector ;;
    detect-task-dirs)  do_detect_task_dirs ;;
    remove-task-dir)   shift; do_remove_task_dir "${1:-}" ;;
    -h | --help | '')  usage ;;
    *)                 usage >&2; die "Unknown subcommand: $1" ;;
  esac
}

main "$@"
