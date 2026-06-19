#!/usr/bin/env bash
#
# persona-loader.test.sh — verifies the persona-name loader contract (issue #36).
#
# Self-contained: no test framework required. Run directly:
#   bash tests/persona-loader.test.sh
# Exits 0 if all assertions pass, 1 otherwise. Suitable for CI once the
# Sprint-1 test harness lands; until then it is the documented automated check
# behind docs/persona.md "Verification".
#
# Drives bin/persona.sh against a temp config via the YNAB_CONFIG_FILE override
# so the real plugin data dir is never touched.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PERSONA_SH="${REPO_ROOT}/bin/persona.sh"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

pass=0
fail=0

# assert_name <description> <expected> <config-file-path-or-empty>
assert_name() {
  local desc="$1" expected="$2" cfg="$3" got
  got="$(YNAB_CONFIG_FILE="$cfg" bash "$PERSONA_SH" name)"
  if [ "$got" = "$expected" ]; then
    printf 'ok   — %s (got %q)\n' "$desc" "$got"
    pass=$((pass + 1))
  else
    printf 'FAIL — %s: expected %q, got %q\n' "$desc" "$expected" "$got"
    fail=$((fail + 1))
  fi
}

# (a) custom persona.name is picked up
custom_cfg="${TMPDIR_TEST}/custom.json"
printf '{"persona":{"name":"Calvin"}}' > "$custom_cfg"
assert_name "custom persona.name is picked up" "Calvin" "$custom_cfg"

# (b) absent config file falls back to Hobbes (no error)
assert_name "absent config falls back to Hobbes" "Hobbes" "${TMPDIR_TEST}/does-not-exist.json"

# missing .persona.name field falls back to Hobbes
empty_cfg="${TMPDIR_TEST}/empty.json"
printf '{"persona":{}}' > "$empty_cfg"
assert_name "missing persona.name falls back to Hobbes" "Hobbes" "$empty_cfg"

# malformed JSON falls back to Hobbes (no error)
bad_cfg="${TMPDIR_TEST}/bad.json"
printf 'this is not json {' > "$bad_cfg"
assert_name "malformed config falls back to Hobbes" "Hobbes" "$bad_cfg"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
