#!/usr/bin/env bash
#
# bin/ynab-prune.sh — prune old generated YNAB reports under the retention policy
# (issue #65, GAP-21).
#
# WHAT THIS IS
#   Generated review reports are UNENCRYPTED financial records (full transaction
#   history, balances, payees, tax detail). Left unbounded they accumulate in
#   plaintext forever. This helper enforces a documented retention policy: it
#   removes report files OLDER than a maximum age from the report output
#   directory. It is DRY-RUN BY DEFAULT — it previews exactly what would be
#   deleted and deletes nothing unless `--apply` is passed, mirroring the
#   ynab-apply "dry-run first" convention.
#
# WHAT IT TOUCHES — AND WHAT IT NEVER TOUCHES
#   It only ever considers regular files matching the report writer's frozen
#   naming pattern `YNAB-*-Review-*.html`, DIRECTLY inside the resolved output
#   directory (no recursion). It never deletes directories, never follows into
#   sub-directories, and never touches the live state files (monitor-state,
#   tax-tracker), the append-only audit log, config, or anything that is not a
#   dated report. Proposals are emitted INTO the weekly-review report (issue
#   #53), so pruning old reports prunes their proposals too — there is no
#   separate proposal file to sweep.
#
# RETENTION POLICY — ONE SOURCE OF TRUTH
#   The default maximum age lives ONCE, here, as DEFAULT_RETENTION_DAYS. A user
#   may override it per-install via `.report.retention_days` in config.json, or
#   per-invocation via `--days N`. Resolution order (first wins):
#     --days N  →  .report.retention_days  →  DEFAULT_RETENTION_DAYS
#
# OUTPUT DIRECTORY
#   Resolved exactly like the report writer's default: `.report.output_dir` from
#   config.json, else the shipped default `~/Documents/Claude/Reports`. A leading
#   `~` is expanded to $HOME. If the resolved directory does not exist there is
#   nothing to prune — the helper says so and exits 0 (a no-op, never an error).
#
# USAGE
#   ynab-prune.sh                 # dry-run: preview reports older than the threshold
#   ynab-prune.sh --apply         # actually delete them
#   ynab-prune.sh --days 7        # override the age threshold (days)
#   ynab-prune.sh --output-dir D  # override the report directory
#
# EXIT CODES
#   0  success (preview printed, or deletion completed, or nothing to do)
#   2  usage error (bad flag, non-numeric --days, unsafe output dir)
#
# bash 3.2 compatible (macOS system bash): no associative arrays, no mapfile.

set -uo pipefail

prog="ynab-prune.sh"
err()       { printf '%s: %s\n' "$prog" "$1" >&2; }
usage_err() { err "$1"; exit 2; }

# The single source of truth for the default retention age. Reports older than
# this many days are pruning candidates.
DEFAULT_RETENTION_DAYS=30

# Shipped fallback report directory — identical to bin/report-writer.sh's default
# so prune and write agree on where reports live.
DEFAULT_OUTPUT_DIR="$HOME/Documents/Claude/Reports"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Reuse the shared loader's `_cfg` (jq-read with `// empty`). Sourcing only
# defines functions + YNAB_CONFIG_FILE and honours a pre-set YNAB_CONFIG_FILE
# (the test seam); it has no load-time side effects.
# shellcheck source=/dev/null
. "${REPO_ROOT}/bin/config.sh"

apply=0
days=""
output_dir=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply)      apply=1 ;;
    --days)       shift; [ "$#" -gt 0 ] || usage_err "--days requires a value"; days="$1" ;;
    --output-dir) shift; [ "$#" -gt 0 ] || usage_err "--output-dir requires a value"; output_dir="$1" ;;
    -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
    *)            usage_err "unknown argument: $1" ;;
  esac
  shift
done

# Resolve the age threshold: --days → config → default. Must be a non-negative
# integer — a bad value is a usage error, never a silent fallback that could
# delete more than intended.
if [ -z "$days" ]; then
  days="$(_cfg '.report.retention_days')"
fi
[ -n "$days" ] || days="$DEFAULT_RETENTION_DAYS"
case "$days" in
  ''|*[!0-9]*) usage_err "retention days must be a non-negative integer, got: $days" ;;
esac

# Resolve the output directory: --output-dir → config → default, then expand a
# leading ~.
if [ -z "$output_dir" ]; then
  output_dir="$(_cfg '.report.output_dir')"
fi
[ -n "$output_dir" ] || output_dir="$DEFAULT_OUTPUT_DIR"
# The `~` here is a LITERAL to match in config DATA (an unexpanded tilde the user
# typed into output_dir), not a path we want the shell to expand — so the quoted
# tilde is intentional and SC2088 is a false positive.
# shellcheck disable=SC2088
case "$output_dir" in
  "~")   output_dir="$HOME" ;;
  "~/"*) output_dir="$HOME/${output_dir#\~/}" ;;
esac

# Never operate on the filesystem root or a relative/empty path — deletion must
# be scoped to a real, absolute report directory.
case "$output_dir" in
  "/"|"") usage_err "refusing to prune the filesystem root or an empty path" ;;
  /*)     : ;;
  *)      usage_err "output directory must be an absolute path, got: $output_dir" ;;
esac

# A missing directory is a clean no-op, not an error — there is simply nothing to
# prune yet.
if [ ! -d "$output_dir" ]; then
  printf 'no report directory at %s — nothing to prune.\n' "$output_dir"
  exit 0
fi

# Collect the pruning candidates: regular files matching the report writer's
# frozen `YNAB-*-Review-*.html` pattern, DIRECTLY in the output dir (no
# recursion), with a modification time older than the threshold. `-mtime +N`
# selects files last modified MORE than N*24 h ago. NUL-delimited so paths with
# spaces survive; bash 3.2 has no mapfile, so read in a loop.
candidates=()
while IFS= read -r -d '' f; do
  candidates+=("$f")
done < <(find "$output_dir" -maxdepth 1 -type f -name 'YNAB-*-Review-*.html' -mtime +"$days" -print0 2>/dev/null)

count="${#candidates[@]}"

if [ "$count" -eq 0 ]; then
  printf 'no reports older than %s day(s) in %s — nothing to prune.\n' "$days" "$output_dir"
  exit 0
fi

if [ "$apply" -eq 1 ]; then
  printf 'Pruning %s report(s) older than %s day(s) from %s:\n' "$count" "$days" "$output_dir"
  removed=0
  for f in "${candidates[@]}"; do
    if rm -f "$f"; then
      printf '  removed  %s\n' "$f"
      removed=$((removed + 1))
    else
      err "could not remove: $f"
    fi
  done
  printf 'Done — removed %s of %s report(s).\n' "$removed" "$count"
  [ "$removed" -eq "$count" ] || exit 2
else
  printf 'Dry run — %s report(s) older than %s day(s) in %s would be removed:\n' "$count" "$days" "$output_dir"
  for f in "${candidates[@]}"; do
    printf '  would remove  %s\n' "$f"
  done
  printf 'Re-run with --apply to delete them.\n'
fi
