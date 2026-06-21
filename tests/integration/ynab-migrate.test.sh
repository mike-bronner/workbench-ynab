#!/usr/bin/env bash
#
# ynab-migrate.test.sh — exercises bin/ynab-migrate.sh, the deterministic file
# operations behind the legacy-migration command (issue #77).
#
# The load-bearing property is IDEMPOTENCY (AC: "running migration twice on a
# fixture state, verifying the second run makes zero mutations"). The connector-
# removal and task-dir-removal subcommands are run a second time against an
# already-migrated sandbox and must make NO changes and report "already done"
# (test_full_migration_is_idempotent). The rest of the file proves the first pass
# is correct (removes the right thing, preserves everything else) and fails closed
# on a malformed config — without which "idempotent" would be a hollow guarantee.
#
# Pure bash, no token values: connector removal deletes the whole mcpServers.ynab
# block, so the fixture never needs (and never embeds) a token-shaped string.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/tests/lib/assert.sh"

MIGRATE="$ROOT/bin/ynab-migrate.sh"

# Build a fresh sandbox and echo its root. The Desktop config carries the legacy
# `ynab` connector AND an unrelated `other` server that must survive removal; the
# Scheduled root holds the two deprecated task dirs plus a `keep-me` dir that must
# survive. Each caller removes the sandbox it makes.
_make_sandbox() {
  local sb desk sched
  sb="$(mktemp -d)"
  desk="$sb/claude_desktop_config.json"
  sched="$sb/Scheduled"
  cat > "$desk" <<'JSON'
{
  "mcpServers": {
    "ynab": {
      "command": "npx",
      "args": ["-y", "@dizzlkheinz/ynab-mcpb@latest"]
    },
    "other": {
      "command": "bash",
      "args": ["other.sh"]
    }
  }
}
JSON
  mkdir -p "$sched/ynab-financial-review" "$sched/ynab-cleanup-remaining" "$sched/keep-me"
  printf 'prototype skill\n' > "$sched/ynab-financial-review/SKILL.md"
  printf '%s\n' "$sb"
}

# Deterministic snapshot of a sandbox: every file's path + checksum, then the
# directory tree. Used to prove a second migration pass mutates nothing. `-exec
# ... +` runs shasum only when files exist, so an empty tree never hangs on stdin.
_snapshot() {
  ( cd "$1" && find . -type f -exec shasum {} + 2>/dev/null | sort; \
    printf -- '--- dirs ---\n'; find . -type d | sort )
}

test_detect_connector_reports_present() {
  local sb out rc=0
  sb="$(_make_sandbox)"
  out="$(YNAB_DESKTOP_CONFIG="$sb/claude_desktop_config.json" bash "$MIGRATE" detect-connector)" || rc=$?
  rm -rf "$sb"
  assert_eq 0 "$rc" "detect-connector should exit 0 when the legacy connector is present"
  assert_contains "$out" "LEGACY CONNECTOR PRESENT"
}

test_detect_connector_absent_when_no_config() {
  local missing out rc=0
  missing="$(mktemp -d)/nope.json"
  out="$(YNAB_DESKTOP_CONFIG="$missing" bash "$MIGRATE" detect-connector)" || rc=$?
  assert_eq 1 "$rc" "detect-connector should exit 1 when there is no Desktop config"
  assert_contains "$out" "No Claude Desktop config"
}

test_detect_connector_ignores_unrelated_ynab_server() {
  local sb desk out rc=0
  sb="$(mktemp -d)"
  desk="$sb/claude_desktop_config.json"
  printf '{"mcpServers":{"ynab":{"command":"bash","args":["my-own.sh"]}}}\n' > "$desk"
  out="$(YNAB_DESKTOP_CONFIG="$desk" bash "$MIGRATE" detect-connector)" || rc=$?
  rm -rf "$sb"
  assert_eq 1 "$rc" "an ynab server not running the legacy package must not be flagged"
  assert_contains "$out" "does NOT run"
}

test_detect_connector_fails_closed_on_malformed_config() {
  local sb desk out rc=0
  sb="$(mktemp -d)"
  desk="$sb/claude_desktop_config.json"
  printf '{"mcpServers": {"ynab": {"args": [\n' > "$desk"   # truncated, unparseable
  out="$(YNAB_DESKTOP_CONFIG="$desk" bash "$MIGRATE" detect-connector 2>&1)" || rc=$?
  rm -rf "$sb"
  assert_eq 2 "$rc" "detect-connector must fail closed (exit 2) on a config jq cannot parse"
  assert_contains "$out" "UNPARSEABLE"
}

test_remove_connector_removes_only_ynab() {
  local sb desk rc=0
  sb="$(_make_sandbox)"
  desk="$sb/claude_desktop_config.json"
  YNAB_DESKTOP_CONFIG="$desk" bash "$MIGRATE" remove-connector >/dev/null || rc=$?
  assert_eq 0 "$rc" "remove-connector should exit 0 on success"
  assert_json_valid "$desk"
  assert_eq false "$(jq -r '(.mcpServers // {}) | has("ynab")' "$desk")" "the ynab block must be gone"
  assert_eq true "$(jq -r '(.mcpServers // {}) | has("other")' "$desk")" "the unrelated server must be preserved"
  rm -rf "$sb"
}

test_remove_connector_is_idempotent() {
  local sb desk before after out rc=0
  sb="$(_make_sandbox)"
  desk="$sb/claude_desktop_config.json"
  YNAB_DESKTOP_CONFIG="$desk" bash "$MIGRATE" remove-connector >/dev/null
  before="$(_snapshot "$sb")"
  out="$(YNAB_DESKTOP_CONFIG="$desk" bash "$MIGRATE" remove-connector)" || rc=$?
  after="$(_snapshot "$sb")"
  rm -rf "$sb"
  assert_eq 0 "$rc" "a second remove-connector must exit 0"
  assert_contains "$out" "already"
  assert_eq "$before" "$after" "a second remove-connector must not mutate the config"
}

test_remove_connector_fails_closed_on_malformed_config() {
  local sb desk before after rc=0
  sb="$(mktemp -d)"
  desk="$sb/claude_desktop_config.json"
  printf '{"mcpServers": {"ynab": {\n' > "$desk"   # unparseable
  before="$(_snapshot "$sb")"
  YNAB_DESKTOP_CONFIG="$desk" bash "$MIGRATE" remove-connector >/dev/null 2>&1 || rc=$?
  after="$(_snapshot "$sb")"
  rm -rf "$sb"
  assert_eq 2 "$rc" "remove-connector must refuse (exit 2) to edit a config it cannot parse"
  assert_eq "$before" "$after" "a malformed config must be left byte-for-byte untouched"
}

test_detect_task_dirs_reports_presence() {
  local sb out rc=0
  sb="$(_make_sandbox)"
  out="$(YNAB_SCHEDULED_ROOT="$sb/Scheduled" bash "$MIGRATE" detect-task-dirs)" || rc=$?
  rm -rf "$sb"
  assert_eq 0 "$rc" "detect-task-dirs should exit 0 when deprecated dirs exist"
  assert_contains "$out" "present: ynab-financial-review"
  assert_contains "$out" "present: ynab-cleanup-remaining"
}

test_detect_task_dirs_exit_1_when_none() {
  local empty out rc=0
  empty="$(mktemp -d)"
  out="$(YNAB_SCHEDULED_ROOT="$empty" bash "$MIGRATE" detect-task-dirs)" || rc=$?
  rm -rf "$empty"
  assert_eq 1 "$rc" "detect-task-dirs should exit 1 when no deprecated dir exists"
  assert_contains "$out" "absent:  ynab-financial-review"
}

test_remove_task_dir_removes_named_and_preserves_rest() {
  local sb sched rc=0
  sb="$(_make_sandbox)"
  sched="$sb/Scheduled"
  YNAB_SCHEDULED_ROOT="$sched" bash "$MIGRATE" remove-task-dir ynab-financial-review >/dev/null || rc=$?
  assert_eq 0 "$rc" "remove-task-dir should exit 0 on success"
  [ ! -e "$sched/ynab-financial-review" ] || fail "named dir should be removed"
  assert_dir_exists "$sched/ynab-cleanup-remaining"
  assert_dir_exists "$sched/keep-me"
  rm -rf "$sb"
}

test_remove_task_dir_is_idempotent() {
  local sb sched out rc=0
  sb="$(_make_sandbox)"
  sched="$sb/Scheduled"
  YNAB_SCHEDULED_ROOT="$sched" bash "$MIGRATE" remove-task-dir ynab-financial-review >/dev/null
  out="$(YNAB_SCHEDULED_ROOT="$sched" bash "$MIGRATE" remove-task-dir ynab-financial-review)" || rc=$?
  rm -rf "$sb"
  assert_eq 0 "$rc" "a second remove-task-dir must exit 0"
  assert_contains "$out" "already"
}

test_remove_task_dir_rejects_unknown_name() {
  local sb sched out rc=0
  sb="$(_make_sandbox)"
  sched="$sb/Scheduled"
  out="$(YNAB_SCHEDULED_ROOT="$sched" bash "$MIGRATE" remove-task-dir keep-me 2>&1)" || rc=$?
  assert_eq 2 "$rc" "remove-task-dir must reject a name outside the deprecated whitelist"
  assert_contains "$out" "Refusing to remove"
  assert_dir_exists "$sched/keep-me"   # an unknown name removes nothing
  rm -rf "$sb"
}

# The headline AC: run the full migration once, then again — the second pass must
# make zero mutations and announce each step as already done.
test_full_migration_is_idempotent() {
  local sb desk sched before after out1 out2 out3
  sb="$(_make_sandbox)"
  desk="$sb/claude_desktop_config.json"
  sched="$sb/Scheduled"

  # First pass — the real migration.
  YNAB_DESKTOP_CONFIG="$desk" bash "$MIGRATE" remove-connector >/dev/null
  YNAB_SCHEDULED_ROOT="$sched" bash "$MIGRATE" remove-task-dir ynab-financial-review >/dev/null
  YNAB_SCHEDULED_ROOT="$sched" bash "$MIGRATE" remove-task-dir ynab-cleanup-remaining >/dev/null

  before="$(_snapshot "$sb")"

  # Second pass — must be a pure no-op and say so.
  out1="$(YNAB_DESKTOP_CONFIG="$desk" bash "$MIGRATE" remove-connector)"
  out2="$(YNAB_SCHEDULED_ROOT="$sched" bash "$MIGRATE" remove-task-dir ynab-financial-review)"
  out3="$(YNAB_SCHEDULED_ROOT="$sched" bash "$MIGRATE" remove-task-dir ynab-cleanup-remaining)"

  after="$(_snapshot "$sb")"
  rm -rf "$sb"

  assert_eq "$before" "$after" "the second migration pass must not mutate the sandbox"
  assert_contains "$out1" "already"
  assert_contains "$out2" "already"
  assert_contains "$out3" "already"
}

run_tests
