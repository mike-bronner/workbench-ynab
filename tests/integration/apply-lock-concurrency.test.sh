#!/usr/bin/env bash
#
# apply-lock-concurrency.test.sh — end-to-end proof of the GAP-9 single-flight guard
# (issue #51) under a simulated concurrent review + apply pair.
#
# This is the AC #8 integration test: it drives bin/apply-lock.sh as a CLI (the way
# commands/ynab-apply.md and the M4-10 review emitter invoke it), with a real proposal
# file on disk. The load-bearing property: while an apply HOLDS the lock, a review that
# fires exits cleanly (the lighter guard) and NEVER overwrites or truncates the
# proposal file the apply is consuming; once the apply releases, the review proceeds;
# and a crashed apply's leftover lock never permanently blocks a later review.
#
# Pure bash + jq, no YNAB and no token, and NO long-lived background processes: the
# "held apply" is stood in by this test script's own (live) pid, and the "crashed
# apply" by a reaped (dead) pid — so nothing lingers to stall the harness.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/tests/lib/assert.sh"

LOCK="$ROOT/bin/apply-lock.sh"

# A stand-in proposal envelope (shape irrelevant here — the guard is content-agnostic;
# what matters is that its bytes survive a contended review untouched).
PROPOSAL_CONTENT='{"schema_version":"1.0.0","source":"run-orig","operations":[]}'
REGEN_CONTENT='{"schema_version":"1.0.0","source":"run-regenerated","operations":[]}'

# review_emulator <lock-cli> <proposal-path> <new-content>
#   Models the M4-10 review's guarded proposal write: take the single-flight lock as
#   `review`; only if acquired, (re)write the proposal and release; if an apply holds
#   it, back off WITHOUT touching the proposal. Owner pid defaults to $PPID — a live,
#   distinct actor from the apply holder — exactly as a real review process would run.
review_emulator() {
  local lock_cli="$1" proposal="$2" new_content="$3"
  if bash "$lock_cli" acquire review 2>/dev/null; then
    printf '%s' "$new_content" > "$proposal"   # regenerate — the destructive moment
    bash "$lock_cli" release
    return 0
  fi
  return 1   # lighter guard: an apply is in flight — leave the proposal alone
}

# reaped_pid — echo a pid that is guaranteed NOT alive (a child we start and reap), the
# exact state a crashed holder leaves behind. No lingering process: it is reaped here.
reaped_pid() {
  local p
  ( exit 0 ) &
  p=$!
  wait "$p" 2>/dev/null || true
  printf '%s' "$p"
}

# ---------------------------------------------------------------------------
# AC #8: review fires while apply holds the lock → review exits cleanly, proposal intact.
test_review_backs_off_and_does_not_clobber_while_apply_holds() {
  local sb proposal err rc
  sb="$(mktemp -d)"
  export YNAB_LOCK_FILE="$sb/apply.lock"
  proposal="$sb/changeset-2026-06-19T143000Z.json"
  printf '%s' "$PROPOSAL_CONTENT" > "$proposal"

  # An apply run holds the lock, owned by a live process — this test script ($$).
  YNAB_LOCK_PID="$$" bash "$LOCK" acquire apply >/dev/null
  assert_file_exists "$YNAB_LOCK_FILE"
  assert_eq "apply" "$(jq -r '.operation' "$YNAB_LOCK_FILE")" "apply owns the lock"

  # The review fires concurrently and must back off, touching nothing.
  err="$(review_emulator "$LOCK" "$proposal" "$REGEN_CONTENT" 2>&1)" && rc=0 || rc=$?
  assert_eq "1" "$rc" "the review exits non-zero (backed off) while apply holds the lock"
  assert_eq "$PROPOSAL_CONTENT" "$(cat "$proposal")" "the proposal file is NOT clobbered"

  # A contending review is told the exact held message.
  err="$(bash "$LOCK" acquire review 2>&1)" || true
  assert_contains "$err" "an apply/review is already running — try again once it completes" \
    "a contending review sees the exact held message"

  # The apply's lock is still held (the review broke nothing).
  assert_eq "apply" "$(jq -r '.operation' "$YNAB_LOCK_FILE")" "apply still holds the lock afterward"

  YNAB_LOCK_PID="$$" bash "$LOCK" release
  rm -rf "$sb"
  unset YNAB_LOCK_FILE
}

# Once the apply releases, the same review proceeds and regenerates the proposal.
test_review_proceeds_and_regenerates_once_apply_releases() {
  local sb proposal rc
  sb="$(mktemp -d)"
  export YNAB_LOCK_FILE="$sb/apply.lock"
  proposal="$sb/changeset-2026-06-19T143000Z.json"
  printf '%s' "$PROPOSAL_CONTENT" > "$proposal"

  # Apply acquires, then releases (its lifecycle completed).
  YNAB_LOCK_PID="$$" bash "$LOCK" acquire apply >/dev/null
  YNAB_LOCK_PID="$$" bash "$LOCK" release
  assert_eq "0" "$([ -e "$YNAB_LOCK_FILE" ] && echo 1 || echo 0)" "lock is free after apply releases"

  # Now the review is unobstructed: it regenerates the proposal and releases cleanly.
  review_emulator "$LOCK" "$proposal" "$REGEN_CONTENT" && rc=0 || rc=$?
  assert_eq "0" "$rc" "the review proceeds when no apply holds the lock"
  assert_eq "$REGEN_CONTENT" "$(cat "$proposal")" "the review regenerated the proposal"
  assert_eq "0" "$([ -e "$YNAB_LOCK_FILE" ] && echo 1 || echo 0)" "the review released the lock when done"

  rm -rf "$sb"
  unset YNAB_LOCK_FILE
}

# A crashed apply (lock left behind by a now-dead pid) never permanently blocks a review.
test_review_recovers_after_a_crashed_apply() {
  local sb proposal dead rc
  sb="$(mktemp -d)"
  export YNAB_LOCK_FILE="$sb/apply.lock"
  proposal="$sb/changeset-2026-06-19T143000Z.json"
  printf '%s' "$PROPOSAL_CONTENT" > "$proposal"

  # A crashed apply acquired the lock and died: the lock is left owned by a dead pid.
  dead="$(reaped_pid)"
  YNAB_LOCK_PID="$dead" bash "$LOCK" acquire apply >/dev/null
  assert_file_exists "$YNAB_LOCK_FILE"  # stale lock persists after the crash

  # The next review self-heals the stale lock and proceeds — no manual intervention.
  review_emulator "$LOCK" "$proposal" "$REGEN_CONTENT" && rc=0 || rc=$?
  assert_eq "0" "$rc" "the review recovers the crashed apply's stale lock and proceeds"
  assert_eq "$REGEN_CONTENT" "$(cat "$proposal")" "the review regenerated the proposal after recovery"

  rm -rf "$sb"
  unset YNAB_LOCK_FILE
}

# AC #1 storage location: the default lock lives in the plugin DATA dir, never /tmp.
test_default_lock_path_is_the_data_dir_not_tmp() {
  local out path
  # `status` on a free lock prints the resolved default path; no YNAB_LOCK_FILE seam.
  out="$(env -u YNAB_LOCK_FILE bash "$LOCK" status)"
  path="${out##*(}"; path="${path%)}"   # extract the path between the parentheses
  assert_contains "$path" ".claude/plugins/data/workbench-ynab-claude-workbench" \
    "default lock path is under the plugin data dir"
  case "$path" in
    /tmp/* | /var/folders/*) fail "default lock path must not be in a tmp dir: $path" ;;
    *) : ;;
  esac
}

run_tests
