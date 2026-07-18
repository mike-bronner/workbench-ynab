#!/usr/bin/env bash
#
# tests/unit/ynab-prune.test.sh — unit tests for bin/ynab-prune.sh, the report
# retention/prune helper (issue #65, GAP-21).
#
# Follows the repo test-harness convention (tests/lib/assert.sh): raw bash with
# `set -euo pipefail`, sources tests/lib/assert.sh, defines `test_*` functions,
# ends with `run_tests`. scripts/test.sh auto-discovers it via the `*.test.sh`
# glob.
#
# Seams used:
#   * --output-dir / --days flags — point prune at a sandbox dir and threshold.
#   * YNAB_CONFIG_FILE — the loader's documented test seam, so the
#     .report.output_dir / .report.retention_days reads are deterministic.
#   * HOME — overridden to the sandbox so the ~ default + ~ expansion never touch
#     the developer's real home directory.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"

PRUNE="$REPO_ROOT/bin/ynab-prune.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX"

# seed_reports <dir> — populate <dir> with two OLD reports (mtime well past any
# threshold), one FRESH report (mtime now), and one non-report file. Returns the
# dir ready for a prune run.
seed_reports() {
  local dir="$1"
  mkdir -p "$dir"
  : > "$dir/YNAB-Weekly-Review-2020-01-01.html";  touch -t 202001010000 "$dir/YNAB-Weekly-Review-2020-01-01.html"
  : > "$dir/YNAB-Monthly-Review-2020-02-15.html"; touch -t 202002150000 "$dir/YNAB-Monthly-Review-2020-02-15.html"
  : > "$dir/YNAB-Weekly-Review-2099-01-01.html"   # fresh (mtime = now) — must survive a +30d threshold
  : > "$dir/notes.txt"                             # non-report — must always survive
}

# Dry run is the DEFAULT: it previews the old reports and deletes NOTHING.
test_dry_run_is_default_and_deletes_nothing() {
  local dir="$SANDBOX/dry" out rc=0
  seed_reports "$dir"
  out="$( bash "$PRUNE" --output-dir "$dir" --days 30 )" || rc=$?
  assert_eq "0" "$rc" "dry run exits 0"
  assert_contains "$out" "Dry run" "output announces a dry run"
  assert_contains "$out" "YNAB-Weekly-Review-2020-01-01.html"  "old weekly report listed as a candidate"
  assert_contains "$out" "YNAB-Monthly-Review-2020-02-15.html" "old monthly report listed as a candidate"
  assert_contains "$out" "--apply" "output tells the user how to actually delete"
  # Nothing deleted — every seeded file still present.
  assert_file_exists "$dir/YNAB-Weekly-Review-2020-01-01.html"
  assert_file_exists "$dir/YNAB-Monthly-Review-2020-02-15.html"
  assert_file_exists "$dir/YNAB-Weekly-Review-2099-01-01.html"
  assert_file_exists "$dir/notes.txt"
  # The fresh report must NOT appear in the preview.
  case "$out" in *"YNAB-Weekly-Review-2099-01-01.html"*) fail "a fresh report was listed as a prune candidate" ;; esac
}

# --apply deletes the OLD reports, and keeps the fresh report + any non-report file.
test_apply_deletes_old_keeps_fresh_and_non_reports() {
  local dir="$SANDBOX/apply" out rc=0
  seed_reports "$dir"
  out="$( bash "$PRUNE" --output-dir "$dir" --days 30 --apply )" || rc=$?
  assert_eq "0" "$rc" "apply exits 0"
  assert_contains "$out" "removed 2 of 2 report(s)" "summary reports both old files removed"
  [ -e "$dir/YNAB-Weekly-Review-2020-01-01.html" ]  && fail "old weekly report was not deleted"
  [ -e "$dir/YNAB-Monthly-Review-2020-02-15.html" ] && fail "old monthly report was not deleted"
  assert_file_exists "$dir/YNAB-Weekly-Review-2099-01-01.html"  # fresh survives
  assert_file_exists "$dir/notes.txt"                           # non-report survives
  return 0
}

# The --days threshold is honoured: a very LARGE threshold spares even the old
# reports (nothing is old enough), and prune reports a clean no-op.
test_days_threshold_is_respected() {
  local dir="$SANDBOX/threshold" out rc=0
  seed_reports "$dir"
  out="$( bash "$PRUNE" --output-dir "$dir" --days 999999 --apply )" || rc=$?
  assert_eq "0" "$rc" "a huge threshold exits 0"
  assert_contains "$out" "nothing to prune" "no report is old enough under a huge threshold"
  assert_file_exists "$dir/YNAB-Weekly-Review-2020-01-01.html"  # spared
  assert_file_exists "$dir/YNAB-Monthly-Review-2020-02-15.html" # spared
}

# output_dir AND retention_days both resolve from config.json (the .report block)
# when no flag overrides them — the single-config-location contract.
test_output_dir_and_days_read_from_config() {
  local dir="$SANDBOX/from-config" cfg="$SANDBOX/cfg.json" out rc=0
  seed_reports "$dir"
  cat > "$cfg" <<JSON
{ "report": { "output_dir": "$dir", "retention_days": 30 } }
JSON
  out="$( YNAB_CONFIG_FILE="$cfg" bash "$PRUNE" --apply )" || rc=$?
  assert_eq "0" "$rc" "config-driven prune exits 0"
  assert_contains "$out" "removed 2 of 2 report(s)" "old reports removed using config-sourced dir + days"
  [ -e "$dir/YNAB-Weekly-Review-2020-01-01.html" ] && fail "config-driven prune did not delete the old report"
  assert_file_exists "$dir/YNAB-Weekly-Review-2099-01-01.html"
}

# A ~-based output dir expands under $HOME (the sandbox), never a literal ~ dir.
test_tilde_output_dir_expands_under_home() {
  local out rc=0
  seed_reports "$SANDBOX/Reports"
  # shellcheck disable=SC2088
  out="$( bash "$PRUNE" --output-dir '~/Reports' --days 30 )" || rc=$?
  assert_eq "0" "$rc" "~ output dir exits 0"
  assert_contains "$out" "$SANDBOX/Reports/YNAB-Weekly-Review-2020-01-01.html" \
    "~ expanded to \$HOME/Reports, not a literal ~ directory"
  [ -d "$SANDBOX/~" ] && fail "a literal ~ directory was created/targeted"
  return 0
}

# A `$VAR` in .report.output_dir is resolved to the variable's VALUE (via the
# shared expand_path), so prune scans exactly the directory the writer wrote to —
# NOT a literal `$VAR` path that exits 2 or silently finds nothing. Before prune
# shared the writer's resolver this case silently no-op'd. The heredoc is
# single-quoted so `$YNAB_PRUNE_DIR` reaches prune UNEXPANDED — the parent shell
# must not pre-expand it, or expand_path is never exercised.
test_env_var_in_output_dir_resolves_and_prunes() {
  local dir="$SANDBOX/env-dir" cfg="$SANDBOX/env-cfg.json" out rc=0
  seed_reports "$dir"
  export YNAB_PRUNE_DIR="$dir"
  # shellcheck disable=SC2016
  cat > "$cfg" <<'JSON'
{ "report": { "output_dir": "$YNAB_PRUNE_DIR", "retention_days": 30 } }
JSON
  out="$( YNAB_CONFIG_FILE="$cfg" bash "$PRUNE" --apply )" || rc=$?
  unset YNAB_PRUNE_DIR
  assert_eq "0" "$rc" "a \$VAR output_dir resolves and exits 0"
  assert_contains "$out" "removed 2 of 2 report(s)" "old reports in the \$VAR-resolved dir are pruned"
  [ -e "$dir/YNAB-Weekly-Review-2020-01-01.html" ] && fail "\$VAR output_dir: old report was not deleted (dir did not resolve)"
  assert_file_exists "$dir/YNAB-Weekly-Review-2099-01-01.html"
}

# The BRACED `${VAR}` form resolves too — a mutation dropping the `${…}` regex
# alternative from expand_path would leave the bare-$VAR test green but fail this.
test_braced_env_var_in_output_dir_resolves() {
  local dir="$SANDBOX/braced-dir" cfg="$SANDBOX/braced-cfg.json" out rc=0
  seed_reports "$dir"
  export YNAB_PRUNE_BRACED="$dir"
  cat > "$cfg" <<'JSON'
{ "report": { "output_dir": "${YNAB_PRUNE_BRACED}", "retention_days": 30 } }
JSON
  out="$( YNAB_CONFIG_FILE="$cfg" bash "$PRUNE" )" || rc=$?
  unset YNAB_PRUNE_BRACED
  assert_eq "0" "$rc" "a \${VAR} output_dir resolves and exits 0"
  assert_contains "$out" "$dir/YNAB-Weekly-Review-2020-01-01.html" \
    "\${VAR} expanded to its value — the old report is a listed candidate"
}

# A SYMLINKED output dir is normalized to its physical target and scanned. On
# BSD/macOS `find <symlink>` (no -L) does NOT descend a symlink given as the scan
# root, so without the `pwd -P` normalization prune would report "nothing to
# prune" while old reports sit in the real directory.
test_symlinked_output_dir_is_scanned() {
  local real="$SANDBOX/real-reports" link="$SANDBOX/link-reports" out rc=0
  seed_reports "$real"
  ln -s "$real" "$link"
  out="$( bash "$PRUNE" --output-dir "$link" --days 30 --apply )" || rc=$?
  assert_eq "0" "$rc" "a symlinked output dir exits 0"
  assert_contains "$out" "removed 2 of 2 report(s)" "old reports under the symlinked dir are pruned"
  [ -e "$real/YNAB-Weekly-Review-2020-01-01.html" ] && fail "symlinked dir: old report was not deleted (find did not descend)"
  assert_file_exists "$real/YNAB-Weekly-Review-2099-01-01.html"  # fresh survives
}

# A non-numeric --days is a usage error (exit 2), never a silent fallback that
# could delete more than intended.
test_non_numeric_days_is_usage_error() {
  local rc=0 err
  err="$( bash "$PRUNE" --output-dir "$SANDBOX/x" --days abc 2>&1 )" || rc=$?
  assert_eq "2" "$rc" "non-numeric --days → exit 2"
  assert_contains "$err" "non-negative integer" "error explains the bad --days value"
}

# A missing output directory is a clean no-op (exit 0), not an error.
test_missing_dir_is_a_clean_noop() {
  local out rc=0
  out="$( bash "$PRUNE" --output-dir "$SANDBOX/does-not-exist" --days 30 )" || rc=$?
  assert_eq "0" "$rc" "missing dir exits 0"
  assert_contains "$out" "nothing to prune" "missing dir reports nothing to prune"
}

# The filesystem root is refused (exit 2) — deletion must never be scoped to '/'.
test_root_output_dir_is_refused() {
  local rc=0 err
  err="$( bash "$PRUNE" --output-dir "/" --days 30 2>&1 )" || rc=$?
  assert_eq "2" "$rc" "output dir '/' → exit 2"
  assert_contains "$err" "filesystem root" "error explains the root refusal"
}

# A relative output dir is refused (exit 2) — prune only operates on an absolute
# path, so it can never delete under an unexpected CWD.
test_relative_output_dir_is_refused() {
  local rc=0 err
  err="$( cd "$SANDBOX" && bash "$PRUNE" --output-dir "relative-dir" --days 30 2>&1 )" || rc=$?
  assert_eq "2" "$rc" "a relative output dir → exit 2"
  assert_contains "$err" "absolute path" "error explains the absolute-path requirement"
}

# A partial --apply (a file that can't be removed) surfaces non-zero rather than
# reporting a clean success. Make one candidate undeletable by removing write on
# its PARENT dir (so rm -f fails), then restore perms for cleanup.
test_apply_reports_failure_when_a_file_cannot_be_removed() {
  local dir="$SANDBOX/locked" rc=0
  # root bypasses directory write-permission checks, so the chmod 500 trick can't
  # deny the unlink there — skip rather than false-fail under a root CI container.
  if [ "$(id -u)" -eq 0 ]; then
    printf '    (skipped: running as root — dir perms cannot deny unlink)\n'
    return 0
  fi
  mkdir -p "$dir"
  : > "$dir/YNAB-Weekly-Review-2020-01-01.html"; touch -t 202001010000 "$dir/YNAB-Weekly-Review-2020-01-01.html"
  chmod 500 "$dir"                       # read+exec, no write → unlink is denied
  bash "$PRUNE" --output-dir "$dir" --days 30 --apply >/dev/null 2>&1 || rc=$?
  chmod 700 "$dir"                       # restore so the trap can clean up
  assert_eq "2" "$rc" "an undeletable candidate makes --apply exit non-zero (2)"
}

# --help prints the WHOLE leading comment block (to the first blank line), not a
# hardcoded line range. A `sed -n '2,40p'` truncated it mid-header — dropping the
# OUTPUT DIRECTORY, USAGE, and EXIT CODES sections that live PAST line 40. Assert
# sections beyond the old cut so a regression to a fixed end-line fails.
test_help_prints_the_full_header_not_a_truncated_range() {
  local out rc=0
  out="$( bash "$PRUNE" --help )" || rc=$?
  assert_eq "0" "$rc" "--help exits 0"
  assert_contains "$out" "OUTPUT DIRECTORY" "help includes the OUTPUT DIRECTORY section (past the old 40-line cut)"
  assert_contains "$out" "EXIT CODES" "help includes the EXIT CODES section (past the old 40-line cut)"
  # The EXIT CODES doc records that exit 2 also covers a PARTIAL --apply deletion,
  # not only a usage error, so a caller scripting the codes isn't misled.
  assert_contains "$out" "PARTIAL" "help documents that exit 2 can mean a partial --apply deletion"
}

# With NO --output-dir and NO .report.output_dir, prune falls back to the shared
# default report dir ($HOME/Documents/Claude/Reports). That default is now
# single-sourced in bin/path-expand.sh so the writer and pruner can't drift on
# where reports live — exercise the fallback so dropping or renaming the shared
# constant is caught here (an unbound DEFAULT_OUTPUT_DIR trips `set -u`).
test_default_output_dir_fallback_is_the_shared_constant() {
  local dir="$SANDBOX/Documents/Claude/Reports" cfg="$SANDBOX/empty-config.json" out rc=0
  seed_reports "$dir"
  printf '{}\n' > "$cfg"                  # no .report.output_dir → resolution hits the default
  out="$( YNAB_CONFIG_FILE="$cfg" bash "$PRUNE" --days 30 --apply )" || rc=$?
  assert_eq "0" "$rc" "default-dir prune exits 0"
  assert_contains "$out" "removed 2 of 2 report(s)" "prune swept the shared default report dir"
  [ -e "$dir/YNAB-Weekly-Review-2020-01-01.html" ] && fail "default-dir: old report not deleted (shared default not resolved)"
  assert_file_exists "$dir/YNAB-Weekly-Review-2099-01-01.html"  # fresh survives
}

# An UNSET $VAR embedded in .report.output_dir is REFUSED (exit 2), not silently
# swallowed to a bogus path. `$TYPO/Reports` with TYPO unset must not collapse to
# `/Reports` and make prune scan the wrong dir (reporting "nothing to prune")
# while old reports pile up untouched; the shared expand_path fails so prune
# refuses. The single-quoted heredoc keeps `$YNAB_PRUNE_UNSET` UNEXPANDED so the
# parent shell can't pre-expand it — expand_path must do the resolving.
test_unset_var_in_output_dir_is_refused() {
  local cfg="$SANDBOX/unset-embedded-cfg.json" rc=0 err
  cat > "$cfg" <<'JSON'
{ "report": { "output_dir": "$YNAB_PRUNE_UNSET/Reports", "retention_days": 30 } }
JSON
  err="$( YNAB_CONFIG_FILE="$cfg" bash "$PRUNE" --apply 2>&1 )" || rc=$?
  assert_eq "2" "$rc" "an unset \$VAR embedded in output_dir → exit 2"
  assert_contains "$err" "did not fully resolve" "error explains the unresolved output dir"
}

# A SYMLINK whose target is `/` is refused AFTER normalization. The pre-normalize
# case guard only rejects the literal strings "/"/"" — a symlink passes it, then
# `pwd -P` collapses it to `/`. Without the post-normalization re-check, `find /`
# would run. Assert the refusal so a regression that drops the second guard fails.
test_symlink_to_root_is_refused_after_normalization() {
  local link="$SANDBOX/root-link" rc=0 err
  ln -s / "$link"
  err="$( bash "$PRUNE" --output-dir "$link" --days 30 2>&1 )" || rc=$?
  assert_eq "2" "$rc" "a symlink whose target is / → exit 2"
  assert_contains "$err" "filesystem root" "error explains the root refusal post-normalization"
}

# A `..`-laden path that RESOLVES to `/` is refused after normalization too. It
# starts with `/` so the pre-normalize guard's absolute-path branch passes it,
# and `pwd -P` collapses it to `/`. The post-normalization re-check must catch it.
test_dotdot_path_resolving_to_root_is_refused() {
  local rc=0 err
  err="$( bash "$PRUNE" --output-dir "/../../../../.." --days 30 2>&1 )" || rc=$?
  assert_eq "2" "$rc" "a ..-path resolving to / → exit 2"
  assert_contains "$err" "filesystem root" "error explains the root refusal post-normalization"
}

run_tests
