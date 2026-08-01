#!/usr/bin/env bash
#
# tests/unit/privacy-posture.test.sh — pins the documentation half of the
# generated-artifacts privacy posture (issue #65, GAP-21), so a future edit can't
# silently drop the user-facing warnings and the artifact inventory.
#
# Follows the repo harness convention (tests/lib/assert.sh): raw bash with
# `set -euo pipefail`, sources tests/lib/assert.sh, defines `test_*` functions,
# ends with `run_tests`. scripts/test.sh auto-discovers it via `*.test.sh`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"

# SECURITY.md carries the "Generated Artifacts" section: the unencrypted-plaintext
# statement, the no-sync/iCloud warning, and the retention/prune pointer (AC #5).
test_security_md_has_generated_artifacts_section() {
  local sec; sec="$(cat "$REPO_ROOT/SECURITY.md")"
  assert_contains "$sec" "## Generated Artifacts" "SECURITY.md has a Generated Artifacts section"
  assert_contains "$sec" "unencrypted" "SECURITY.md states the artifacts are unencrypted"
  assert_contains "$sec" "iCloud" "SECURITY.md warns about the iCloud sync risk"
  assert_contains "$sec" "ynab-prune.sh" "SECURITY.md points at the prune tool"
}

# The inventory enumerates every financial artifact by path, so the user (and the
# uninstall flow) can find them, and references the uninstall issue #67 (AC #8/#9).
test_security_md_inventory_enumerates_artifacts_and_references_67() {
  local sec; sec="$(cat "$REPO_ROOT/SECURITY.md")"
  assert_contains "$sec" "### Artifact inventory" "SECURITY.md has an artifact inventory"
  assert_contains "$sec" "YNAB-<Tier>-Review-<YYYY-MM-DD>.html" "inventory lists the report path pattern"
  assert_contains "$sec" "audit-<YYYY-MM>.jsonl" "inventory lists the audit log"
  assert_contains "$sec" "monitor-state.json"    "inventory lists the monitor state file"
  assert_contains "$sec" "tax-tracker.json"      "inventory lists the estimated-tax tracker"
  assert_contains "$sec" "issues/67" "inventory references the uninstall issue #67"
}

# The privacy posture covers PROPOSALS too — the issue title is "reports,
# proposals, and audit files." No proposal writer exists yet (M4-10), but the
# committed change-set design specifies separate proposals/ JSON files, so the
# inventory must acknowledge that future artifact class and state it needs 0600 +
# a retention story when M4-10 lands — not imply proposals don't exist (AC #1/#3/#8).
test_security_md_inventory_acknowledges_future_proposals() {
  local sec; sec="$(cat "$REPO_ROOT/SECURITY.md")"
  assert_contains "$sec" "proposals/changeset-<stamp>.json" "inventory lists the future proposals path"
  assert_contains "$sec" "M4-10" "inventory attributes the proposal writer to M4-10"
}

# README's privacy section mentions the generated artifacts, their location, and
# the iCloud sync risk (AC #7).
test_readme_privacy_covers_artifacts_and_icloud() {
  local rd; rd="$(cat "$REPO_ROOT/README.md")"
  assert_contains "$rd" "unencrypted" "README privacy section flags unencrypted artifacts"
  assert_contains "$rd" "iCloud" "README privacy section warns about iCloud sync"
  assert_contains "$rd" "ynab-prune.sh" "README privacy section points at the prune tool"
}

# Setup's end-of-run summary prints the privacy notice: report + data dirs,
# unencrypted, and the iCloud warning (AC #6).
test_setup_summary_prints_privacy_notice() {
  local su; su="$(cat "$REPO_ROOT/commands/setup.md")"
  assert_contains "$su" "🔒 Privacy" "setup summary includes a privacy notice"
  assert_contains "$su" "UNENCRYPTED" "setup notice states the records are unencrypted"
  assert_contains "$su" "iCloud Drive" "setup notice warns about iCloud sync"
  # The `~/…` here is a LITERAL doc string to find in setup.md, not a path to
  # expand — SC2088 is a false positive.
  # shellcheck disable=SC2088
  assert_contains "$su" "~/Documents/Claude/Reports" "setup notice names the report directory"
}

# Setup hardens the data dir AND config.json to owner-only at creation (AC #1/#2,
# blocker: they were world-accessible on the primary install path). Setup is the
# FIRST creator of the data dir, so a bare `mkdir -p` here left it 0755 and later
# writers never widened it back. Pin the three hardening commands so a future edit
# can't silently drop them and re-open the world-readable hole SECURITY.md then
# claims is closed. `umask 077` gives a fresh dir no world-readable window; the
# explicit chmods tighten an existing loose dir/config (setup is idempotent).
test_setup_hardens_data_dir_and_config_at_creation() {
  local su; su="$(cat "$REPO_ROOT/commands/setup.md")"
  # The single-quoted needles are LITERAL setup.md text to find (the `$CONFIG_DIR`
  # / `$CONFIG_FILE` inside them are documented shell, not expansions here) — so
  # SC2016 is a false positive on all three.
  # shellcheck disable=SC2016
  assert_contains "$su" 'umask 077; mkdir -p "$CONFIG_DIR"' \
    "setup creates the data dir under umask 077 (0700, no world-readable window)"
  # shellcheck disable=SC2016
  assert_contains "$su" 'chmod 700 "$CONFIG_DIR"' \
    "setup tightens an existing data dir to 0700"
  # shellcheck disable=SC2016
  assert_contains "$su" 'chmod 600 "$CONFIG_FILE.tmp"' \
    "setup restricts config.json to 0600 before publishing it"
}

# The retention constant is documented in the config schema (AC #3).
test_config_schema_documents_retention_days() {
  local cs; cs="$(cat "$REPO_ROOT/docs/config-schema.md")"
  assert_contains "$cs" "retention_days" "config schema documents .report.retention_days"
  assert_contains "$cs" "30 days" "config schema states the 30-day default"
}

# The prune command surface exists and documents the dry-run-by-default contract
# (AC #4).
test_prune_command_and_script_exist() {
  assert_file_exists "$REPO_ROOT/bin/ynab-prune.sh"
  assert_file_exists "$REPO_ROOT/commands/ynab-prune.md"
  local cmd; cmd="$(cat "$REPO_ROOT/commands/ynab-prune.md")"
  assert_contains "$cmd" "--apply" "prune command documents the --apply gate"
  assert_contains "$cmd" "dry-run" "prune command documents dry-run-by-default"
}

run_tests
