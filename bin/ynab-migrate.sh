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
#   seed-config CONFIG    Create CONFIG from the shipped example on FIRST RUN,
#                         with the example's placeholder `budgets` array and
#                         `default_budget` stripped so Step 5's migrate-config
#                         calls can land the user's REAL budget (issue #84 —
#                         a placeholder budgets array is not "blank", so seeding
#                         it verbatim would lock the factory placeholders in).
#                         No-op when CONFIG already exists. Writes via
#                         temp-file→validate→mv at mode 0600. Exit 0 ok,
#                         2 on a missing/unparseable example or a failed write.
#   migrate-config CONFIG PATH VALUE
#                         Set ONE config.json field to VALUE only when it is
#                         currently blank (absent, null, "", [], {}, or a
#                         <PLACEHOLDER> string) — an existing real value is NEVER
#                         overwritten. PATH is a JSON array (e.g. ["budgets"])
#                         and VALUE a JSON literal. Writes via temp-file→validate→mv,
#                         so a jq failure can't leave a half-written config. Idempotent.
#                         Exit 0 ok (wrote or already-set), 2 on a config it cannot
#                         parse/rewrite or a malformed PATH/VALUE argument.
#
# PATH OVERRIDES (defaults are the real on-disk locations; the overrides let the
# test harness point every surface at a sandbox):
#   YNAB_DESKTOP_CONFIG   Claude Desktop config JSON.
#   YNAB_SCHEDULED_ROOT   Root holding the prototype scheduled-task directories.
#   YNAB_CONFIG_EXAMPLE   The shipped config example seed-config copies from.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DESKTOP_CONFIG="${YNAB_DESKTOP_CONFIG:-$HOME/Library/Application Support/Claude/claude_desktop_config.json}"
SCHEDULED_ROOT="${YNAB_SCHEDULED_ROOT:-$HOME/Documents/Claude/Scheduled}"
CONFIG_EXAMPLE="${YNAB_CONFIG_EXAMPLE:-$SCRIPT_DIR/../assets/config.example.json}"

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
  has_ynab="$(jq -r '(.mcpServers // {}) | has("ynab")' "$DESKTOP_CONFIG")" || return 2
  if [ "$has_ynab" != true ]; then
    printf 'No legacy "ynab" connector in the Desktop config (good — nothing to remove).\n'
    return 1
  fi
  pkg_match="$(jq -r --arg pkg "$LEGACY_PKG" '
    [ (.mcpServers.ynab.args // [])[] | select(type == "string") | select(contains($pkg)) ] | length > 0
  ' "$DESKTOP_CONFIG")" || return 2
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
  has_ynab="$(jq -r '(.mcpServers // {}) | has("ynab")' "$DESKTOP_CONFIG")" || return 2
  if [ "$has_ynab" != true ]; then
    printf 'mcpServers.ynab already absent — nothing to remove (already done).\n'
    return 0
  fi
  # Remove ONLY the ynab key; every other server is preserved. Write to a temp
  # file, validate it is JSON, and only then mv over the original — so a failure
  # at ANY step (jq del, validation, or the mv itself) leaves the config
  # untouched. The mv lives inside the if-condition so its failure can't slip
  # past `set -e`; every rewrite failure falls through to the documented exit 2.
  local tmp
  tmp="$(mktemp)" || return 2
  # Clean the temp copy on EVERY exit from here — including a SIGINT mid-rewrite,
  # which would otherwise strand a copy of the Desktop config (legacy plaintext
  # token and all) on disk. The trap clears itself so it never re-fires for a
  # caller frame (where $tmp is out of scope and `set -u` would abort).
  trap 'rm -f "$tmp"; trap - RETURN' RETURN
  if jq 'del(.mcpServers.ynab)' "$DESKTOP_CONFIG" > "$tmp" \
    && jq -e . "$tmp" >/dev/null 2>&1 \
    && mv "$tmp" "$DESKTOP_CONFIG"; then
    printf 'Removed mcpServers.ynab from the Desktop config (other servers preserved).\n'
    return 0
  fi
  printf '⚠️  Failed to rewrite the Desktop config — left unchanged.\n' >&2
  printf '    Location: %s\n' "$DESKTOP_CONFIG" >&2
  return 2
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

# Create CONFIG from the shipped example on FIRST RUN — with the example's
# placeholder `budgets` array and `default_budget` stripped. The example ships
# a two-budget placeholder array to document the v2 shape (issue #84), but
# seeding it verbatim breaks the migration: migrate-config fills only BLANK
# fields, and an array of placeholder OBJECTS is not blank, so the factory
# placeholders would win over the user's real migrated budget forever (and the
# legacy ["budget","name"] patch would strand the real name in a key the v2
# loader never reads — bin/config.sh's `has("budgets")` gate sees the
# placeholders and skips the legacy synthesis). With the array absent, Step 5's
# `migrate-config CONFIG '["budgets"]' …` lands the real entry and the emitted
# file validates against assets/config.schema.json. Idempotent: an existing
# CONFIG is never touched. Written at mode 0600 — the file will hold the user's
# budget/business/tax data. Exit 0 ok (seeded or already present), 2 on a
# missing/unparseable example or a failed write.
do_seed_config() {
  local config="${1:-}" tmp
  [ -n "$config" ] || die "seed-config requires a CONFIG path"
  if [ -f "$config" ]; then
    printf 'Config already present — not seeding (already done): %s\n' "$config"
    return 0
  fi
  if [ ! -f "$CONFIG_EXAMPLE" ]; then
    printf '⚠️  Shipped example not found — cannot seed: %s\n' "$CONFIG_EXAMPLE" >&2
    return 2
  fi
  jq -e . "$CONFIG_EXAMPLE" >/dev/null 2>&1 || { printf '⚠️  Unparseable example — refusing to seed from it: %s\n' "$CONFIG_EXAMPLE" >&2; return 2; }
  mkdir -p "$(dirname "$config")" || return 2
  tmp="$(mktemp)" || return 2
  # Clean the temp copy on EVERY exit, mirroring the other writers, so a failure
  # can never strand a half-built seed (or leave an empty config that a re-run
  # would then mistake for "already present").
  trap 'rm -f "$tmp"; trap - RETURN' RETURN
  if jq 'del(.budgets, .default_budget)' "$CONFIG_EXAMPLE" > "$tmp" \
    && jq -e . "$tmp" >/dev/null 2>&1 \
    && chmod 600 "$tmp" \
    && mv "$tmp" "$config"; then
    printf 'Seeded %s from the shipped example (placeholder budgets stripped — Step 5 fills the real one).\n' "$config"
    return 0
  fi
  printf '⚠️  Failed to seed config — nothing written: %s\n' "$config" >&2
  return 2
}

# Set ONE config.json field, but ONLY when it is currently blank — never
# blind-overwrite a real value. "Blank" = absent, null, "", [], {}, or a
# <PLACEHOLDER>-shaped string. PATH is a JSON array (e.g. ["business","name"]);
# VALUE is a JSON literal (a string is "\"x\"", an array "[…]", an object "{…}").
# Both go through jq via --argjson, so a config value can never be interpreted as
# a jq program. Writes through a temp file validated before mv, mirroring
# remove-connector. Exit 0 (wrote or already-set), 2 on parse/rewrite failure or
# a malformed PATH/VALUE.
do_migrate_config() {
  local config="${1:-}" path="${2:-}" value="${3:-}" dotted blank tmp
  if [ -z "$config" ] || [ "$#" -lt 3 ]; then die "migrate-config requires CONFIG PATH VALUE"; fi
  if [ ! -f "$config" ]; then
    printf '⚠️  No config to migrate into: %s\n' "$config" >&2
    return 2
  fi
  jq -e . "$config" >/dev/null 2>&1 || { printf '⚠️  Unparseable config — refusing to edit: %s\n' "$config" >&2; return 2; }
  # Reject a malformed PATH/VALUE before touching the config. PATH must be a JSON
  # ARRAY (asserted directly, so the message fires where it claims to — a non-array
  # would otherwise only blow up later at join(".")). VALUE must merely PARSE as
  # JSON — `jq empty` checks parse-validity without `-e`'s truthiness test, so the
  # JSON literals `false` and `null` are accepted (they are valid literals).
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$path"  || { printf '⚠️  migrate-config PATH must be a JSON array: %s\n' "$path" >&2; return 2; }
  jq empty                >/dev/null 2>&1 <<<"$value" || { printf '⚠️  migrate-config VALUE must be a JSON literal: %s\n' "$value" >&2; return 2; }
  dotted="$(jq -rn --argjson p "$path" '$p | join(".")')" || return 2
  blank="$(jq -r --argjson path "$path" '
    def is_blank: . == null or . == "" or . == [] or . == {}
      or (type == "string" and test("^<.*>$"));
    getpath($path) | is_blank
  ' "$config")" || return 2
  if [ "$blank" != true ]; then
    printf '%s already set — leaving it (already done).\n' "$dotted"
    return 0
  fi
  tmp="$(mktemp)" || return 2
  # Clean the temp copy on EVERY exit, signals included (it holds the user's
  # budget/business/tax data). Self-clearing so it never re-fires for a caller.
  trap 'rm -f "$tmp"; trap - RETURN' RETURN
  if jq --argjson path "$path" --argjson v "$value" 'setpath($path; $v)' "$config" > "$tmp" \
    && jq -e . "$tmp" >/dev/null 2>&1 \
    && mv "$tmp" "$config"; then
    printf 'Set %s from the migrated prototype config.\n' "$dotted"
    return 0
  fi
  printf '⚠️  Failed to write config — left unchanged: %s\n' "$config" >&2
  return 2
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
  seed-config CONFIG    Create CONFIG from the shipped example on first run, with
                        the placeholder budgets array and default_budget stripped
                        so migrate-config can land the real budget. No-op when
                        CONFIG exists. Exit 0 ok, 2 on a missing/unparseable
                        example or a failed write.
  migrate-config CONFIG PATH VALUE
                        Set one config.json field (PATH = JSON array, VALUE = JSON
                        literal) only when it is currently blank — never a blind
                        overwrite. Idempotent. Exit 0 ok, 2 on parse/rewrite failure.
  -h, --help            Show this help.

Path overrides: YNAB_DESKTOP_CONFIG, YNAB_SCHEDULED_ROOT, YNAB_CONFIG_EXAMPLE
(see the header).
EOF
}

main() {
  case "${1:-}" in
    detect-connector)  do_detect_connector ;;
    remove-connector)  do_remove_connector ;;
    detect-task-dirs)  do_detect_task_dirs ;;
    remove-task-dir)   shift; do_remove_task_dir "${1:-}" ;;
    seed-config)       shift; do_seed_config "${1:-}" ;;
    migrate-config)    shift; do_migrate_config "$@" ;;
    -h | --help | '')  usage ;;
    *)                 usage >&2; die "Unknown subcommand: $1" ;;
  esac
}

main "$@"
