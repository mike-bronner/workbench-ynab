#!/usr/bin/env bash
#
# tests/unit/migrate-data-dir.test.sh — behavioral guards for the data-dir
# hardening preamble in Step 5 of /workbench-ynab:ynab-migrate
# (commands/ynab-migrate.md, issue #65 / GAP-21).
#
# WHY THIS FILE EXISTS. /ynab-migrate seeds config.json WITHOUT requiring /setup
# first, so on the legacy-prototype path it can be the FIRST creator of the
# plugin data dir — the dir that also holds audit/, monitor-state.json, and
# tax-tracker.json. A bare `mkdir -p` left it world-traversable (0755) under a
# loose umask, letting other local users enumerate every financial artifact's
# filename and mtime. The preamble now creates it under `umask 077` and chmods
# it 0700, both failing CLOSED.
#
# The chmod half is NOT redundant with the umask half. `do_seed_config`
# (bin/ynab-migrate.sh) early-returns SUCCESS when config.json already exists,
# without ever touching the directory — so on a pre-privacy install (a 0755 dir
# with a config already inside it) this preamble's chmod is the ONLY code in the
# whole flow that re-tightens the directory. test_pre_existing_loose_data_dir_is_
# retightened pins exactly that scenario.
#
# These tests EXTRACT the real fenced block from ynab-migrate.md and EXECUTE it
# in a sandbox (the tests/unit/setup-config-write.test.sh extract-and-run
# pattern), so they stay coupled to the code the command actually ships rather
# than to a copy that can drift.
#
# Follows the repo harness convention (issue #4, tests/lib/assert.sh): raw bash
# with `set -euo pipefail`, sources tests/lib/assert.sh, defines `test_*`
# functions, ends with `run_tests`. scripts/test.sh auto-discovers it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"

CMD="$REPO_ROOT/commands/ynab-migrate.md"

# Portable octal-perms read: GNU `stat -c '%a'` probed FIRST (on GNU, `stat -f`
# misreads `%Lp`), BSD/macOS `stat -f '%Lp'` as the fallback. Same helper the
# setup-config-write / report-writer / audit-log suites use.
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# Pull the first ```bash fenced block out of the "## Step 5" section — the
# seed-config preamble as shipped. The block is indented 3 spaces (it sits in a
# numbered list item), so strip that indent. Restructuring Step 5 breaks the
# extraction guard test below, which is the signal to update this test.
extract_step5_block() {
  awk '/^## Step 5 /{s=1; next} s && /^## /{exit}
       s && /^ *```bash$/{f=1; next} f && /^ *```$/{exit} f{sub(/^   /, ""); print}' "$CMD"
}

# Run the extracted block with $1 as HOME (the block derives CONFIG_DIR from
# $HOME) and the repo as CLAUDE_PLUGIN_ROOT (it calls bin/ynab-migrate.sh).
# Prints combined stdout+stderr; the block's exit code is the return value.
# `umask 022` is what makes the permission assertions discriminating: under a
# loose umask a regression to a bare `mkdir -p` lands 0755, not 0700.
run_step5() {
  ( umask 022; HOME="$1" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
      bash -c "$(extract_step5_block)" 2>&1 )
}

# The data dir the block derives from $HOME.
data_dir_of() { printf '%s/.claude/plugins/data/workbench-ynab-claude-workbench' "$1"; }

# The extraction still finds the block (and it's the seed preamble, not another).
test_step5_block_extracts() {
  local block; block="$(extract_step5_block)"
  # The needles are literal command source text — never expanded here.
  # shellcheck disable=SC2016
  assert_contains "$block" 'mkdir -p "$CONFIG_DIR"' \
    "the extracted Step 5 block contains the data-dir creation"
  assert_contains "$block" 'seed-config' \
    "the extracted Step 5 block contains the seed-config call"
}

# Happy path — the data dir does not exist yet: the flow ends with it owner-only.
#
# HONEST SCOPE: this pins the end-to-end AC1 outcome, NOT the preamble
# specifically. On the fresh path the preamble and `do_seed_config` are
# belt-and-braces — the helper creates the dir under its own `umask 077` + chmod
# 700 too, so reverting the preamble to a bare `mkdir -p` leaves this test GREEN
# (verified, not assumed). The preamble's unique contribution is the
# already-has-a-config path, which the helper skips entirely; that is what
# test_pre_existing_loose_data_dir_is_retightened pins. Both are kept: this one
# would catch a regression that broke BOTH layers at once.
test_fresh_data_dir_is_owner_only() {
  local sb dir out rc=0
  sb="$(mktemp -d)"; dir="$(data_dir_of "$sb")"
  out="$(run_step5 "$sb")" || rc=$?
  assert_eq 0 "$rc" "the Step 5 preamble should succeed on a fresh install: $out"
  assert_eq "700" "$(mode_of "$dir")" "a freshly created data dir is owner-only (0700)"
  rm -rf "$sb"
}

# The load-bearing case. A PRE-PRIVACY install left the data dir 0755 with a
# config.json already inside it. `do_seed_config` early-returns success on an
# existing config WITHOUT touching the directory, so the preamble's `chmod 700`
# is the only code that can re-tighten it.
#
# Mutation-checked: deleting the `chmod 700 "$CONFIG_DIR"` guard leaves the dir
# at 0755, reddening the mode assertion — the `mkdir -p`/umask half cannot cover
# this case, because `mkdir -p` is a no-op on a directory that already exists.
test_pre_existing_loose_data_dir_is_retightened() {
  local sb dir out rc=0
  sb="$(mktemp -d)"; dir="$(data_dir_of "$sb")"
  mkdir -p "$dir"; chmod 755 "$dir"
  printf '{"schema_version":1}\n' > "$dir/config.json"
  assert_eq "755" "$(mode_of "$dir")" "the data dir pre-exists world-traversable (0755)"

  out="$(run_step5 "$sb")" || rc=$?
  assert_eq 0 "$rc" "the preamble should succeed against a pre-existing config: $out"
  assert_eq "700" "$(mode_of "$dir")" \
    "a pre-existing 0755 data dir is tightened to owner-only (0700)"
  rm -rf "$sb"
}

# The preamble's creation gate fails CLOSED. Force the mkdir failure by planting
# a REGULAR FILE where a parent directory must be — the technique
# tests/unit/setup-config-write.test.sh's `test_data_dir_creation_failure_aborts_setup`
# and tests/unit/report-writer.test.sh's `test_write_failure_gate` already use.
# No elevated privileges needed.
#
# Asserting only "non-zero and nothing seeded" would be VACUOUS: if the preamble
# is unguarded, execution falls through to `seed-config`, whose OWN data-dir
# guard then fails closed — non-zero exit, no config, and a message that also
# starts "Could not create the data directory". Both assertions below therefore
# identify WHICH layer aborted:
#
#   1. "aborting migration" is emitted ONLY by the preamble's guard;
#   2. "refusing to seed" is emitted ONLY by bin/ynab-migrate.sh's guard, so its
#      ABSENCE proves seed-config was never reached — i.e. the preamble stopped
#      Step 5, which is the whole point of the fix.
#
# Mutation-checked, reproduced live: reverting the preamble to the unguarded
# `( umask 077; mkdir -p … ) && chmod 700 …` chain reddens (1) and (2) — the
# output carries the helper's "refusing to seed" line instead.
test_data_dir_creation_failure_aborts_migration() {
  local sb blocker out rc=0
  sb="$(mktemp -d)"
  # Plant a regular file at the ".claude" level so the deeper mkdir -p cannot run.
  blocker="$sb/.claude"
  : > "$blocker"
  out="$(run_step5 "$sb")" || rc=$?
  [ "$rc" -ne 0 ] || fail "the migration must exit non-zero when the data dir can't be created: $out"
  assert_contains "$out" "aborting migration" \
    "the preamble's own guard aborts Step 5 and names the data-dir failure"
  case "$out" in
    *"refusing to seed"*)
      fail "Step 5 reached seed-config after the data-dir preamble failed — the preamble must abort BEFORE the seed call" ;;
  esac
  case "$out" in
    *Seeded*) fail "a failed data-dir creation must not go on to seed a config" ;;
  esac
  [ ! -e "$(data_dir_of "$sb")/config.json" ] \
    || fail "a config was seeded despite a failed data-dir creation"
  rm -rf "$sb"
}

run_tests
