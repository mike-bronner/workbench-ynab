#!/usr/bin/env bash
#
# tests/unit/html-escape.test.sh — unit tests for bin/html-escape.sh, the ONE
# shared, audited HTML escaper for every externally-sourced string the plugin
# renders into a report (issue #30, GAP-18).
#
# Follows the repo test-harness convention (tests/lib/assert.sh): raw bash with
# `set -euo pipefail`, sources tests/lib/assert.sh, defines `test_*` functions,
# ends with `run_tests`. scripts/test.sh auto-discovers it via the `*.test.sh`
# glob — run the whole suite with `scripts/test.sh`, this file alone with
# `scripts/test.sh tests/unit/html-escape.test.sh`, or directly with
# `bash tests/unit/html-escape.test.sh`.
#
# The module is BOTH sourced (for html_escape / escape_ynab_string) and executed
# as a CLI (the review skill's per-value filter), so both surfaces are exercised.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"

MODULE="$REPO_ROOT/bin/html-escape.sh"
# Source the module for direct function access. The CLI block inside it is guarded
# by BASH_SOURCE==$0, so sourcing defines the functions without running the CLI.
# shellcheck source=/dev/null
source "$MODULE"

# assert_not_contains <haystack> <needle> [msg] — the shared lib has no negative
# form; the trust-boundary tests need "the payload must be ABSENT from the output".
assert_not_contains() {
  case "$1" in
    *"$2"*)
      printf '  assert_not_contains failed: [%s] must NOT contain [%s]%s\n' "$1" "$2" "${3:+ — $3}" >&2
      return 1
      ;;
    *) : ;;
  esac
}

# a<repeat> — build an N-character ASCII string deterministically (locale-free).
a_string() {
  local n="$1" s
  printf -v s '%*s' "$n" ''
  printf '%s' "${s// /a}"
}

# ---- AC8: every escape substitution, one assertion per character -------------
test_escape_ampersand() { assert_eq "&amp;"  "$(html_escape '&')"; }
test_escape_lt()        { assert_eq "&lt;"   "$(html_escape '<')"; }
test_escape_gt()        { assert_eq "&gt;"   "$(html_escape '>')"; }
test_escape_dquote()    { assert_eq "&quot;" "$(html_escape '"')"; }
test_escape_squote()    { assert_eq "&#39;"  "$(html_escape "'")"; }

# ---- AC1: ampersand is escaped FIRST, so entities are never double-escaped ----
test_ampersand_escaped_first() {
  # If '<' were escaped before '&', the '&' of the resulting '&lt;' would then be
  # re-escaped to '&amp;lt;'. Ampersand-first yields exactly one entity each.
  assert_eq "&amp;&lt;" "$(html_escape '&<')"
}
test_all_five_together() {
  assert_eq "&amp;&lt;&gt;&quot;&#39;" "$(html_escape "&<>\"'")"
}

# ---- AC7: a <script> payee payload renders as inert, escaped text ------------
test_script_payload_is_escaped_and_inert() {
  local out; out="$(escape_ynab_string "<script>alert('xss')</script>")"
  # (a) the fully-escaped form is present …
  assert_contains "$out" "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;"
  # (b) … and no literal <script> tag survives anywhere in the output.
  assert_not_contains "$out" "<script>"
  assert_not_contains "$out" "</script>"
}

# ---- AC5: over-long strings truncate to 200 chars + ellipsis BEFORE escaping --
test_truncates_over_200_with_ellipsis() {
  local out; out="$(escape_ynab_string "$(a_string 201)")"
  assert_eq "$(a_string 200)…" "$out"
}
test_exactly_200_is_not_truncated() {
  local exact; exact="$(a_string 200)"
  assert_eq "$exact" "$(escape_ynab_string "$exact")"   # no ellipsis appended
}
test_truncation_counts_source_chars_not_entities() {
  # 201 ampersands: escaping first would inflate to 201×5 chars and truncate the
  # DATA to ~40 ampersands. Truncating first (200 source chars) then escaping
  # keeps exactly 200 escaped ampersands + the ellipsis.
  local out expected
  out="$(escape_ynab_string "$(printf '&%.0s' $(seq 1 201))")"
  expected="$(printf '&amp;%.0s' $(seq 1 200))…"
  assert_eq "$expected" "$out"
}

# ---- AC6: C0 control characters stripped, except tab and newline -------------
test_strips_control_chars_except_tab_newline() {
  # bell (0x07), vertical tab (0x0B) and ESC (0x1B) are stripped; a/b/c survive.
  assert_eq "abc" "$(escape_ynab_string "$(printf 'a\007b\013c\033')")"
}
test_preserves_tab_and_newline() {
  # tab (0x09) and newline (0x0A) are the two C0 chars kept — assert both survive
  # the strip. Build the input with printf so the literal bytes are unambiguous.
  local in; in="$(printf 'a\tb')"
  assert_eq "$(printf 'a\tb')" "$(escape_ynab_string "$in")"
  # newline: internal newline preserved (command substitution only trims trailing).
  in="$(printf 'a\nb')"
  assert_eq "$(printf 'a\nb')" "$(escape_ynab_string "$in")"
}

# ---- AC9: a right-to-left / Unicode payee stays intact and injects nothing ----
test_rtl_unicode_payee_is_safe() {
  # Arabic text plus embedded markup: the RTL characters must survive verbatim,
  # the markup must be escaped, and no <bdo>/dir= override or unbalanced tag may
  # appear that could flip document flow.
  local rtl out
  rtl='مرحبا <b>x</b>'
  out="$(escape_ynab_string "$rtl")"
  assert_contains     "$out" 'مرحبا'                       # RTL text preserved
  assert_contains     "$out" '&lt;b&gt;x&lt;/b&gt;'        # markup neutralised
  assert_not_contains "$out" '<b>'
  assert_not_contains "$out" '<bdo'
  assert_not_contains "$out" 'dir='
}

# ---- CLI surface: the review skill's per-value filter ------------------------
test_cli_default_sanitizes() {
  assert_eq "&lt;script&gt;" "$(bash "$MODULE" '<script>')"
}
test_cli_default_truncates() {
  assert_eq "$(a_string 200)…" "$(bash "$MODULE" "$(a_string 201)")"
}
test_cli_raw_escapes_only_without_truncation() {
  # --raw is the caller-owned, already-bounded path: escape metacharacters, but
  # never strip or truncate. A 201-char all-'a' value comes back unchanged.
  assert_eq "$(a_string 201)" "$(bash "$MODULE" --raw "$(a_string 201)")"
  assert_eq "&lt;a&gt;"       "$(bash "$MODULE" --raw '<a>')"
}

# ---- AC4: ONE shared module — the two consumers import it, no duplicate copy --
test_persona_uses_shared_escaper_no_duplicate() {
  grep -q 'bin/html-escape.sh' "$REPO_ROOT/bin/persona.sh" \
    || fail "persona.sh must source the shared bin/html-escape.sh"
  ! grep -qE '^[[:space:]]*_?html_escape\(\)' "$REPO_ROOT/bin/persona.sh" \
    || fail "persona.sh must not define its own escaper (shared module only)"
}
test_report_writer_uses_shared_escaper_no_duplicate() {
  grep -q 'bin/html-escape.sh' "$REPO_ROOT/bin/report-writer.sh" \
    || fail "report-writer.sh must source the shared bin/html-escape.sh"
  ! grep -qE '^[[:space:]]*html_escape\(\)' "$REPO_ROOT/bin/report-writer.sh" \
    || fail "report-writer.sh must not define its own escaper (shared module only)"
}

run_tests
