#!/usr/bin/env bash
#
# scripts/lint.sh — the single lint entrypoint for workbench-ynab (issue #16).
#
# CI's lint job runs exactly this script; run it locally to reproduce a CI lint
# failure bit-for-bit. It exits non-zero if ANY check fails. Two checks:
#
#   * shellcheck, at DEFAULT severity (style and up — the strictest level), over
#     every repo-authored shell script: bin/*.sh, hooks/*.sh, scripts/*.sh, and
#     everything under tests/ (helpers in tests/lib/ included). vendor/ is
#     excluded on purpose: it holds the vendored third-party bundle, and this
#     gate lints only code this repo authors. Genuine false positives are
#     suppressed at the finding site via `# shellcheck disable=<SC>` directives,
#     each carrying a one-line justification comment — never silenced here with
#     a blanket flag.
#
#   * `jq empty` over every git-tracked *.json file — a malformed JSON file
#     (plugin.json, hooks.json, schemas, fixtures, …) fails the run. An empty
#     file list also fails: like scripts/test.sh's run-nothing guard, this gate
#     never reports success having validated nothing (issue #191).
#
# Requirements: shellcheck, jq, git — nothing else, matching the repo's
# no-install test posture (docs/testing.md).
#
# USAGE:
#   scripts/lint.sh          # run both checks
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for tool in shellcheck jq git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "✗ $tool not found on PATH — required by the lint gate" >&2
    exit 1
  fi
done

fail=0

# --- ShellCheck: default severity, every repo-authored script ----------------
scripts=()
while IFS= read -r f; do scripts+=("$f"); done < <(
  find bin hooks scripts tests -type f -name '*.sh' | sort
)
echo "▶ shellcheck: ${#scripts[@]} script(s), default severity"
if shellcheck "${scripts[@]}"; then
  echo "  ✓ shellcheck clean"
else
  echo "✗ shellcheck reported findings (any severity fails — see above)" >&2
  fail=1
fi

# --- JSON validation: every tracked .json must parse --------------------------
json_files=()
while IFS= read -r f; do json_files+=("$f"); done < <(git ls-files -- '*.json')
echo "▶ jq empty: ${#json_files[@]} JSON file(s)"
# Fail closed on an empty list — mirrors scripts/test.sh's "refusing to exit 0
# having run nothing" guard: zero-validated must never read as "all parse".
if [ "${#json_files[@]}" -eq 0 ]; then
  echo "✗ no tracked JSON files found — refusing to report success having validated nothing" >&2
  fail=1
fi
for f in "${json_files[@]}"; do
  if ! jq empty "$f"; then
    echo "✗ invalid JSON: $f" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "  ✓ all JSON files parse"

if [ "$fail" -ne 0 ]; then
  echo "✗ lint failed" >&2
  exit 1
fi
echo "✓ lint passed"
