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
test_truncates_multibyte_by_char_not_byte() {
  # 250 CJK chars = 750 bytes. A byte slice at 200 would cut mid-sequence and emit
  # INVALID UTF-8 (issue #30 blocker); a char-safe slice keeps exactly 200 chars +
  # ellipsis. `中` is U+4E2D (E4 B8 AD).
  local many out expected
  many="$(printf '\xe4\xb8\xad%.0s' $(seq 1 250))"
  out="$(escape_ynab_string "$many")"
  expected="$(printf '\xe4\xb8\xad%.0s' $(seq 1 200))…"
  assert_eq "$expected" "$out"
}
test_truncates_long_rtl_by_char_not_byte() {
  # A ~250-char Arabic payee (>200 BYTES: `م` U+0645 is 2 bytes each) is squarely
  # AC9's RTL concern crossing the truncation boundary — it must cut at 200 CHARS
  # on a character boundary, never mid-sequence.
  local many out expected
  many="$(printf '\xd9\x85%.0s' $(seq 1 250))"
  out="$(escape_ynab_string "$many")"
  expected="$(printf '\xd9\x85%.0s' $(seq 1 200))…"
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
}
test_rtl_bdo_override_payload_is_neutralised() {
  # A payload that ACTUALLY contains a <bdo dir="rtl"> override — the AC9 threat.
  # The escaped/inert form must be present, and no LIVE tag or attribute may
  # survive (the '"' is escaped, so a literal `dir="` cannot appear).
  local out
  out="$(escape_ynab_string '<bdo dir="rtl">مرحبا</bdo>')"
  assert_contains     "$out" '&lt;bdo dir=&quot;rtl&quot;&gt;'  # override neutralised
  assert_contains     "$out" 'مرحبا'                            # RTL text preserved
  assert_not_contains "$out" '<bdo'                             # no live opening tag
  assert_not_contains "$out" 'dir="'                            # no live attribute
}

# ---- Bidi-override / isolate format chars are stripped (defense-in-depth) -----
test_strips_rlo_override_char() {
  # U+202E RIGHT-TO-LEFT OVERRIDE turns `invoice<RLO>txt.exe` into a spoofed name
  # in a fraud/anomaly report. It must be stripped, not merely passed through.
  local rlo out
  rlo="$(printf '\xe2\x80\xae')"          # U+202E
  out="$(escape_ynab_string "invoice${rlo}txt.exe")"
  assert_eq           "invoicetxt.exe" "$out"
  assert_not_contains "$out" "$rlo"
}
test_strips_all_bidi_override_and_isolate_chars() {
  # Every code point in U+202A–U+202E and U+2066–U+2069 is removed; the plain
  # surrounding text survives intact.
  local blob out
  blob="$(printf 'a\xe2\x80\xaa\xe2\x80\xab\xe2\x80\xac\xe2\x80\xad\xe2\x80\xaeb\xe2\x81\xa6\xe2\x81\xa7\xe2\x81\xa8\xe2\x81\xa9c')"
  out="$(escape_ynab_string "$blob")"
  assert_eq "abc" "$out"
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
test_cli_flag_like_values_are_escaped_as_data_not_dispatched() {
  # issue #30 blocker: a payee/memo/category literally named like a flag must be
  # sanitized as DATA, never select an option branch. The call site always passes
  # `--` before the untrusted value, so each of these is escaped, not dispatched.
  assert_eq "-h"     "$(bash "$MODULE" -- "-h")"
  assert_eq "--help" "$(bash "$MODULE" -- "--help")"
  assert_eq "--raw"  "$(bash "$MODULE" -- "--raw")"
  # a flag-like value carrying markup is still fully escaped as data
  assert_eq "--&lt;script&gt;" "$(bash "$MODULE" -- "--<script>")"
  # --raw before -- selects the metacharacter-only path but still treats the
  # flag-like value as data, never as another option
  assert_eq "--help" "$(bash "$MODULE" --raw -- "--help")"
}
test_cli_help_output_leaks_no_code() {
  # --help prints only the doc-comment header, never the executable `shopt` line
  # that follows it (issue #30 follow-up: the blank line after the header bounds it).
  # Match the EXECUTABLE form (`… 2>/dev/null || true`) — the header prose mentions
  # the bare `shopt -u patsub_replacement`, so only the full statement proves a leak.
  local help; help="$(bash "$MODULE" --help)"
  assert_not_contains "$help" 'shopt -u patsub_replacement 2>/dev/null || true'
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
