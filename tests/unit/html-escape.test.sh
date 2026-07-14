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

# ---- Unicode Tags block (U+E0000–U+E007F) is stripped (ASCII smuggling) -------
test_strips_unicode_tag_block_chars() {
  # Tag characters encode invisible ASCII — the canonical LLM smuggling channel
  # (#28 round-3 blocker). U+E0041 (TAG LATIN CAPITAL LETTER A) must be removed
  # by the shared strip list, leaving the visible text intact.
  local tag_a out
  tag_a="$(printf '\xf3\xa0\x81\x81')"
  out="$(escape_ynab_string "friendly${tag_a}${tag_a}payee")"
  assert_eq "friendlypayee" "$out"
}

# ---- Giant multibyte input still truncates correctly (#28 round 3) -----------
test_giant_multibyte_value_is_bounded_and_truncated() {
  # CORRECTNESS pin only: the O(1) byte gate slices a 6 000-CJK-char (~18 KB)
  # value before the character-accurate passes, and the output must still be
  # exactly HTML_ESCAPE_MAX_LEN characters + ellipsis — i.e. the gate's slice is
  # invisible in the result. This fixture CANNOT detect removal of the gate at
  # escape_ynab_string step 1 (plain CJK matches none of
  # strip_invisible_format_chars's patterns and _truncate_utf8 self-gates), so
  # the DoS guard is the watchdog test below, not this one (#28 round 5).
  local cjk unit s="" expected="" i=0 out
  cjk="$(printf '\xe6\x97\xa5')"
  unit="$cjk$cjk$cjk$cjk$cjk$cjk$cjk$cjk$cjk$cjk"                # 10 chars
  while [ "$i" -lt 600 ]; do s+="$unit"; i=$((i + 1)); done      # 6 000 chars
  out="$(escape_ynab_string "$s")"
  i=0; while [ "$i" -lt 20 ]; do expected+="$unit"; i=$((i + 1)); done  # 200 chars
  assert_eq "${expected}…" "$out"
}

# escape_timed <secs> <value> — run escape_ynab_string under a portable
# poll-and-kill watchdog (macOS ships no timeout(1); same idiom as
# tests/persona-loader.test.sh's render_tmpl_timed / run_voice_timed), so a
# regressed super-linear scan fails the test cleanly instead of stalling CI.
# Prints the sanitized value on stdout; returns 124 if the call overran (hung),
# else the call's own exit code.
escape_timed() {
  local secs="$1" value="$2" out_file pid waited=0 rc=0
  out_file="$(mktemp)"
  ( escape_ynab_string "$value" ) >"$out_file" 2>/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$out_file"
      return 124
    fi
    sleep 1; waited=$((waited + 1))
  done
  wait "$pid" || rc=$?
  cat "$out_file"
  rm -f "$out_file"
  return "$rc"
}

# ---- The DoS guard: match-dense invisible-char payload under a watchdog -------
test_match_dense_invisible_payload_is_bounded() {
  # The byte gate's REAL attack shape (#28 round-5 blocker: the CJK fixture
  # above is blind to gate removal). Every character here is on
  # strip_invisible_format_chars's strip list — ZWSP U+200B, RLO U+202E, and
  # TAG LATIN CAPITAL LETTER A U+E0041 — so with the gate at escape_ynab_string
  # step 1 deleted, the strip pass's `${//}` removals run match-dense over the
  # full ~80 KB value: measured minutes of CPU, versus ~0.02 s gated. The
  # watchdog turns that regression into a clean red instead of a hung CI job.
  # Gated, the slice keeps ≤ (HTML_ESCAPE_MAX_LEN + 1) * 4 bytes of pure
  # strip-list characters, so the sanitized output is exactly the empty string.
  local unit payload i=0 out rc=0
  unit="$(printf '\xe2\x80\x8b\xe2\x80\xae\xf3\xa0\x81\x81')"  # ZWSP+RLO+TAG: 3 chars, 10 bytes
  payload="$unit"
  while [ "$i" -lt 13 ]; do payload+="$payload"; i=$((i + 1)); done  # 10 B × 2^13 = 80 KB
  out="$(escape_timed 20 "$payload")" || rc=$?
  if [ "$rc" -eq 124 ]; then
    fail "escape_ynab_string overran the watchdog on a match-dense invisible-char payload — the O(1) byte gate regressed"
  fi
  assert_eq "0" "$rc" "escape_ynab_string must succeed on the hostile payload"
  assert_eq "" "$out" "every input char is on the strip list — nothing may survive"
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
test_cli_raw_refuses_an_unbounded_value() {
  # #28 cost invariant: html_escape's ${//} substitutions are super-linear on
  # match-dense input (32 KB of '&' ≈ 2 min on bash 3.2), and --raw skips the
  # sanitize path's byte gate — so the CLI refuses a value over 4096 LOUDLY
  # (exit 2, stderr names the contract) instead of truncating an owned value
  # silently or pegging the CPU. 4097 'a's: over the gate, cheap to build.
  local rc=0 err
  err="$(bash "$MODULE" --raw -- "$(a_string 4097)" 2>&1 >/dev/null)" || rc=$?
  assert_eq "2" "$rc" "over-4096 --raw value → exit 2"
  assert_contains "$err" "exceeds 4096" "refusal names the bound"
  assert_contains "$err" "sanitize" "refusal points at the sanitize path for untrusted input"
}
test_cli_raw_accepts_a_value_at_the_bound() {
  # Exactly 4096 is inside the contract and comes back escaped, not refused.
  assert_eq "$(a_string 4096)" "$(bash "$MODULE" --raw -- "$(a_string 4096)")"
}
test_cli_raw_gate_counts_bytes_not_chars() {
  # #28 round-6 blocker: the gate compared `${#raw_value}` — a CHARACTER count
  # under a UTF-8 locale — against the 4096-BYTE bound the header documents, so
  # a 2048-char / 6144-byte CJK value sailed straight through. The invocation
  # FORCES a UTF-8 locale: under LC_ALL=C bytes == chars and even the buggy
  # char-counting gate would refuse this fixture, making the guard vacuous —
  # the round-5 "test that passes with the protection deleted" class.
  local loc unit small payload i=0 rc=0 err
  loc="$(locale -a 2>/dev/null | grep -Eim1 '^(c|en_us)\.utf-?8$' || true)"
  [ -n "$loc" ] || loc="en_US.UTF-8"
  unit="$(printf '\xe6\x97\xa5')"                                    # 日 — 1 char, 3 bytes
  payload="$unit"
  while [ "$i" -lt 10 ]; do payload+="$payload"; i=$((i + 1)); done  # 1024 chars, 3072 bytes
  small="$payload"
  payload+="$payload"                                                # 2048 chars, 6144 bytes
  err="$(LC_ALL="$loc" bash "$MODULE" --raw -- "$payload" 2>&1 >/dev/null)" || rc=$?
  assert_eq "2" "$rc" "2048-char / 6144-byte --raw value → exit 2 (the gate must count bytes)"
  assert_contains "$err" "byte length 6144 exceeds 4096" "refusal reports the BYTE length"
  # Complement: multibyte INSIDE the byte bound (1024 chars / 3072 bytes) is
  # accepted and comes back unchanged (CJK carries no HTML metacharacters) —
  # the fix tightened the gate to bytes, not to something stricter.
  assert_eq "$small" "$(LC_ALL="$loc" bash "$MODULE" --raw -- "$small")" \
    "3072-byte multibyte value is inside the 4096-byte contract"
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
