#!/usr/bin/env bash
#
# scripts/test.sh — the single entrypoint for the workbench-ynab test suite.
#
# Runs the raw-bash suite (tests/**/*.test.sh) and the Node suite
# (tests/**/*.test.mjs) and exits non-zero if ANY test fails. This is the
# command CI (issue #16) invokes — keep it the one true entrypoint.
#
# DESIGN CONSTRAINTS (see docs/testing.md):
#   * Zero third-party dependencies: needs only system `bash`, `node`, `jq` —
#     exactly what the plugin already requires. It runs with NO node_modules
#     present, which is what keeps the M1-7 offline-boot test (issue #14)
#     faithful. The Node suite uses the built-in `node:test` runner, never an
#     installed framework.
#   * macOS-first (darwin); the non-Keychain tests are portable enough to run
#     on Linux CI too.
#
# USAGE:
#   scripts/test.sh                       # run the whole suite
#   scripts/test.sh --bash                # only the bash suite
#   scripts/test.sh --node                # only the Node suite
#   scripts/test.sh tests/unit/x.test.sh  # run one bash test file
#   scripts/test.sh tests/unit/x.test.mjs # run one node test file
#   UPDATE_SNAPSHOTS=1 scripts/test.sh    # (re)write golden snapshots, then pass
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

run_bash=1
run_node=1
explicit_files=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --bash) run_node=0 ;;
    --node) run_bash=0 ;;
    -h | --help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    --*)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
    *) explicit_files+=("$1") ;;
  esac
  shift
done

bash_tests=()
node_tests=()

if [ "${#explicit_files[@]}" -gt 0 ]; then
  for f in "${explicit_files[@]}"; do
    case "$f" in
      *.test.sh) bash_tests+=("$f") ;;
      *.test.mjs | *.test.js) node_tests+=("$f") ;;
      *)
        echo "not a recognized test file (expected *.test.sh or *.test.mjs): $f" >&2
        exit 2
        ;;
    esac
  done
else
  if [ -d tests ]; then
    while IFS= read -r f; do bash_tests+=("$f"); done < <(
      find tests -type f -name '*.test.sh' -not -path 'tests/lib/*' | sort
    )
    while IFS= read -r f; do node_tests+=("$f"); done < <(
      find tests -type f \( -name '*.test.mjs' -o -name '*.test.js' \) -not -path 'tests/lib/*' | sort
    )
  fi
fi

# "No tests yet" — a clean checkout with the harness in place but no test files
# selected should exit 0 with a clear message, never a harness error.
discovered=0
[ "$run_bash" = 1 ] && discovered=$((discovered + ${#bash_tests[@]}))
[ "$run_node" = 1 ] && discovered=$((discovered + ${#node_tests[@]}))
if [ "$discovered" -eq 0 ]; then
  echo "no tests yet — harness is set up but no test files matched (tests/**/*.test.sh, tests/**/*.test.mjs)"
  exit 0
fi

failed_groups=0

# --- Bash suite -------------------------------------------------------------
if [ "$run_bash" = 1 ] && [ "${#bash_tests[@]}" -gt 0 ]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "✗ jq not found on PATH — required by the bash suite" >&2
    exit 1
  fi
  for t in "${bash_tests[@]}"; do
    echo "▶ bash: $t"
    if bash "$t"; then
      :
    else
      echo "✗ FAIL: $t" >&2
      failed_groups=$((failed_groups + 1))
    fi
  done
fi

# --- Node suite -------------------------------------------------------------
if [ "$run_node" = 1 ] && [ "${#node_tests[@]}" -gt 0 ]; then
  if ! command -v node >/dev/null 2>&1; then
    echo "✗ node not found on PATH but Node tests exist" >&2
    exit 1
  fi
  echo "▶ node: ${#node_tests[@]} file(s)"
  if node --test "${node_tests[@]}"; then
    :
  else
    echo "✗ FAIL: Node suite" >&2
    failed_groups=$((failed_groups + 1))
  fi
fi

if [ "$failed_groups" -gt 0 ]; then
  echo "✗ suite failed ($failed_groups failing group(s))" >&2
  exit 1
fi

echo "✓ all tests passed"
