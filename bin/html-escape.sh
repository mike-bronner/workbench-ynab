#!/usr/bin/env bash
#
# bin/html-escape.sh — the ONE shared, audited HTML escaper for every
# externally-sourced string the plugin renders into a report.
#
# WHAT THIS IS
#   A self-contained trust-boundary helper. The YNAB review report is a
#   self-contained HTML file opened in a browser, so a payee/memo/category/
#   account name — or a config-sourced persona name — literally named
#   `<script>…</script>` is a genuine XSS payload even for a local file. This is
#   the single place that neutralises those values. Two consumers previously
#   carried their OWN near-identical escaper (bin/persona.sh and
#   bin/report-writer.sh); both now source THIS module so there is exactly one
#   audited implementation, never a copy that can silently drift.
#
# TWO FUNCTIONS, TWO CONTEXTS
#   html_escape <str>          Pure metacharacter escape — the five HTML-dangerous
#                              characters only. For values the caller OWNS and has
#                              already length-bounded: the report writer's scalars
#                              (output path, tier, date) and the persona name.
#   escape_ynab_string <str>   The full untrusted-external-data sanitizer: strip
#                              control characters, truncate over-long input, THEN
#                              html_escape. For every YNAB-sourced free-text value
#                              (payee, memo, category, account, note) and any
#                              formatted amount carrying an off-the-wire currency
#                              symbol, before it is interpolated into a fragment.
#
# WHO USES IT
#   * bin/persona.sh        sources this and calls html_escape for the footer
#                           (GAP-13 / #28 — one audited escaper for config strings too).
#   * bin/report-writer.sh  sources this and calls html_escape for the scalars it owns.
#   * the review skill (M2-3, skills/review/ynab-review.md) EXECUTES this as a CLI
#     filter — `bash "${CLAUDE_PLUGIN_ROOT}/bin/html-escape.sh" -- "$payee"` — to
#     sanitize each YNAB-sourced value at the fragment-assembly boundary. The
#     stitching layer (M2-9, report-writer.sh) then treats every fragment as an
#     opaque, already-escaped string and never re-processes it.
#
# WHY SOURCED, NOT EXECUTED (for the two shell consumers)
#   Sourcing gives them the functions with no subprocess per value. The ONE
#   deliberate side effect of sourcing is `shopt -u patsub_replacement` below —
#   it MUST run in the caller's shell for the escaping to be correct on bash ≥5.2.
#
# bash 5.2 enables `patsub_replacement` by default, which makes a literal `&` in a
# `${var//pat/repl}` REPLACEMENT expand to the matched text (sed `&` semantics).
# Every replacement here intends `&` to be LITERAL (`&amp;`, `&lt;`, …), so turn
# it off for identical behaviour from bash 3.2 (macOS system bash) through 5.2+
# (GNU/Linux CI). Without this the security-relevant escaping silently produces
# `<lt;` instead of `&lt;` — the bug tracked in #126 that this module fixes for
# both persona.sh and report-writer.sh at once.
#
# NOTE: the blank line below terminates the `--help` output (it prints lines 2..
# first-blank), so this executable `shopt` line never leaks into help text.

shopt -u patsub_replacement 2>/dev/null || true

# Longest YNAB-sourced string rendered verbatim before it is truncated with an
# ellipsis. 200 characters is generous for any real payee/memo yet short enough
# that a hostile or accidental multi-kilobyte value can never blow out the report
# layout. Measured in source characters, BEFORE escaping, so an escaped `&` costs
# 1 (its data length), not 5 (its entity length).
HTML_ESCAPE_MAX_LEN=200

# html_escape <str> — escape the five HTML metacharacters (`&`, `<`, `>`, `"`,
# `'`) to their entity equivalents. `&` is replaced FIRST so the entities the
# later rules introduce are never double-escaped. The apostrophe (`&#39;`) is
# defense-in-depth: it lets a value be safely placed inside a single-quoted
# attribute as well as a double-quoted one or a text node.
# COST CONTRACT (#28 cost invariant): the five global `${//}` substitutions are
# severely super-linear on match-dense input (measured on bash 3.2: 32 KB of
# '&' ≈ 2 min), so the "caller OWNS and has already length-bounded" contract in
# the header is load-bearing for cost, not just layout. Every in-repo call site
# complies: escape_ynab_string byte-gates first; persona.sh bounds the name
# (validated ≤ 64 chars) and the footer's [when] argv (256-byte gate);
# report-writer.sh enum/regex-validates tier/date and refuses an out_dir over
# 1024 bytes; the CLI's --raw path below refuses an over-4096-byte value. A new
# caller MUST bound its value the same way before calling this.
html_escape() {
  local s="${1-}" sq="'"   # hold the single quote in a var: a bare ' inside the
  s="${s//&/&amp;}"        # parameter expansion below would confuse the parser.
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//$sq/&#39;}"
  printf '%s' "$s"
}

# _byte_len <str> — the length of <str> in BYTES, independent of the caller's
# locale. `${#var}` counts CHARACTERS under a UTF-8 locale (macOS's default
# LANG=en_US.UTF-8, CI's C.UTF-8), silently under-counting multibyte input by
# up to 4× — so a gate that compares `${#var}` against a BYTE bound only
# enforces that bound for pure-ASCII values (issue #28 round-6 blocker). The
# C-locale subshell makes `${#s}` the cheap O(1) byte count — the same idiom
# as _byte_bound_utf8 below — and keeps the override from leaking.
_byte_len() (
  LC_ALL=C
  printf '%s' "${#1}"
)

# _byte_bound_utf8 <str> <max-bytes> — hard-slice <str> to at most <max-bytes>
# BYTES, landing the cut on a UTF-8 character boundary (the slice backs off past
# any continuation bytes, so a multibyte character is dropped whole, never split).
# COST INVARIANT (issue #28 round-3 DoS blocker): this is the cheap O(1)-check
# gate every character-accurate helper below hides behind. `${#s}` in a C-locale
# subshell is an O(1) BYTE count, and UTF-8 spends at most 4 bytes per character
# — so a value can be bounded to `(max_chars + 1) * 4` bytes here BEFORE any
# `${var//[range]/}` character scan runs. Those global range substitutions are
# severely super-linear on match-dense multibyte input (every continuation byte
# matches), which made the character-length gate ITSELF the DoS: ~18 KB of CJK
# in voice_overrides pegged the CPU for ~55 s per render pre-fix. No super-linear
# op may ever touch an unbounded value; this helper is how callers guarantee that.
_byte_bound_utf8() (
  LC_ALL=C
  local s="$1" max="$2" i
  if [ "${#s}" -le "$max" ]; then
    printf '%s' "$s"
    return 0
  fi
  # Byte s[max] is the first byte the slice excludes: while it is a continuation
  # byte (0x80–0xBF), cutting there would split the character that starts before
  # it — back off (at most 3 steps; UTF-8 characters are ≤ 4 bytes).
  i="$max"
  while [ "$i" -gt 0 ]; do
    case "${s:i:1}" in
      [$'\x80'-$'\xbf']) i=$((i - 1)) ;;
      *) break ;;
    esac
  done
  printf '%s' "${s:0:i}"
)

# _truncate_utf8 <str> <max> — truncate <str> to at most <max> Unicode CHARACTERS,
# appending a visible ellipsis (…) only when it was longer. LOCALE-INDEPENDENT: the
# whole body runs in a C-locale subshell, so `${#s}` and `${s:i:1}` are byte ops,
# and it walks UTF-8 by hand — a character is one lead byte (NOT 0x80–0xBF) plus its
# continuation bytes — so the cut always lands on a character boundary. A naive
# `${s:0:max}` in the caller's locale slices by BYTE under a byte-oriented locale
# (LC_CTYPE=C is this plugin's ambient default), cutting mid-sequence and corrupting
# a multibyte payee into invalid UTF-8 — issue #30 blocker. Runs in a subshell so
# the LC_ALL override never leaks to the caller.
_truncate_utf8() (
  LC_ALL=C
  local s="$1" max="$2" noncont i chars n byte
  # Self-defending byte gate (issue #28 round-3 DoS blocker): the continuation-
  # byte scan below is super-linear on match-dense multibyte input, so it must
  # never see an unbounded value. Anything longer than (max + 1) * 4 bytes is
  # over the character cap by construction (UTF-8 ≤ 4 bytes/char), and slicing
  # keeps ≥ max + 1 leading characters intact — the truncated output is
  # byte-identical to what the unbounded computation would produce.
  if [ "${#s}" -gt $(( (max + 1) * 4 )) ]; then
    s="$(_byte_bound_utf8 "$s" $(( (max + 1) * 4 )))"
  fi
  noncont="${s//[$'\x80'-$'\xbf']/}"   # drop continuation bytes → lead bytes == chars
  if [ "${#noncont}" -le "$max" ]; then
    printf '%s' "$s"
  else
    i=0; chars=0; n=${#s}
    while [ "$i" -lt "$n" ]; do
      byte="${s:i:1}"
      case "$byte" in
        [$'\x80'-$'\xbf']) : ;;          # continuation byte — part of the current char
        *)                               # a lead byte begins a new character
          [ "$chars" -ge "$max" ] && break   # this would be char max+1 — stop here
          chars=$((chars + 1)) ;;
      esac
      i=$((i + 1))
    done
    printf '%s…' "${s:0:i}"
  fi
)

# strip_invisible_format_chars <str> — remove invisible Unicode FORMAT
# characters that carry no legitimate content in this plugin's rendered strings
# yet enable visual spoofing or delimiter obfuscation:
#   * Bidirectional override / isolate controls (U+202A–U+202E, U+2066–U+2069):
#     they inject no markup, but they visually reorder surrounding text, so a
#     payee like `PayPal<U+202E>txt.exe` can masquerade as another name in an
#     anomaly/fraud report.
#   * Zero-width space (U+200B), word joiner (U+2060), and zero-width no-break
#     space / BOM (U+FEFF): they invisibly split a token so a human, a filter,
#     or a lenient downstream reader each see different words — e.g. a
#     `</voice<U+200B>-overrides>` wrapper-lookalike smuggled through a
#     byte-exact delimiter check (issue #28 review blocker).
#   * The Unicode Tags block (U+E0000–U+E007F): the canonical LLM
#     "ASCII smuggling" channel — arbitrary ASCII encoded as fully invisible
#     tag characters rides straight into model context past any human review
#     of the config or the rendered block (issue #28 round-3 blocker).
# ZWNJ / ZWJ (U+200C / U+200D) are deliberately KEPT: they are functional
# joiners inside emoji sequences and several scripts, and removing them corrupts
# legitimate text. Removal is literal substring replacement, plus two byte-wise
# range patterns for the Tags block; the body runs in a C-locale subshell so
# the range patterns match single BYTES deterministically on every bash.
# Shared by escape_ynab_string (HTML sink), persona.sh's render_voice
# (model-context sink), and _persona_name_violation (name validation), so there
# is exactly ONE audited list — never a private copy that can silently drift.
# CALLER CONTRACT: byte-bound the value first (_byte_bound_utf8) — the `${//}`
# removals below must never run on an unbounded value.
strip_invisible_format_chars() (
  LC_ALL=C
  local s="${1-}" ch
  for ch in $'\xe2\x80\xaa' $'\xe2\x80\xab' $'\xe2\x80\xac' $'\xe2\x80\xad' $'\xe2\x80\xae' \
            $'\xe2\x81\xa6' $'\xe2\x81\xa7' $'\xe2\x81\xa8' $'\xe2\x81\xa9' \
            $'\xe2\x80\x8b' $'\xe2\x81\xa0' $'\xef\xbb\xbf'; do
    s="${s//"$ch"/}"
  done
  # Tags block: every code point is a 4-byte sequence F3 A0 80 XX (U+E0000–3F)
  # or F3 A0 81 XX (U+E0040–7F) with XX in 0x80–0xBF, so two prefix + byte-class
  # patterns remove the whole block. The prefixes live in variables and are
  # expanded QUOTED (bash 3.2 mis-parses quoted literals written inline in a
  # ${var//pat/} pattern — same idiom as persona.sh's render_voice).
  local t0=$'\xf3\xa0\x80' t1=$'\xf3\xa0\x81'
  s="${s//"$t0"[$'\x80'-$'\xbf']/}"
  s="${s//"$t1"[$'\x80'-$'\xbf']/}"
  printf '%s' "$s"
)

# escape_ynab_string <str> — sanitize one untrusted, externally-sourced value for
# safe interpolation into an HTML report fragment. Five ordered steps, each a
# prerequisite of the next:
#   1. Hard byte gate (O(1) length check): slice the raw value to
#      (HTML_ESCAPE_MAX_LEN + 1) * 4 bytes on a character boundary
#      (_byte_bound_utf8), so no later pass — the `${//}` scans in
#      strip_invisible_format_chars and _truncate_utf8 are super-linear on
#      match-dense multibyte input — ever runs on an unbounded value (issue #28
#      round-3 DoS blocker: this input is untrusted AND unbounded off the wire).
#      Anything sliced here was over the character cap anyway (UTF-8 ≤ 4
#      bytes/char), so step 4's truncation output is unchanged.
#   2. Strip C0 control characters (U+0000–U+001F) EXCEPT tab (U+0009) and newline
#      (U+000A). LC_ALL=C makes `tr` operate byte-wise; every stripped code point
#      is a single byte that can NEVER appear inside a UTF-8 multibyte sequence
#      (continuation bytes are 0x80–0xBF), so right-to-left text, accents, and
#      emoji pass through untouched — only the invisible layout-wrecking controls
#      are removed.
#   3. Strip invisible Unicode format characters (bidi overrides/isolates,
#      zero-width space, word joiner, BOM, the Tags block) via the shared
#      strip_invisible_format_chars above — defense-in-depth against visual
#      spoofing, token-splitting obfuscation, and invisible ASCII smuggling.
#   4. Truncate to HTML_ESCAPE_MAX_LEN CHARACTERS (not bytes) with a visible
#      ellipsis (…) when longer, so one unusually long payee or memo can never
#      break the layout. Character-safe (see _truncate_utf8) and done BEFORE
#      escaping so the limit counts source characters, not the inflated entity forms.
#   5. html_escape the result LAST, so nothing steps 1–4 leave behind can reach the
#      markup unescaped.
escape_ynab_string() {
  local s="${1-}"
  s="$(_byte_bound_utf8 "$s" $(( (HTML_ESCAPE_MAX_LEN + 1) * 4 )))"
  s="$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013-\037')"
  s="$(strip_invisible_format_chars "$s")"
  s="$(_truncate_utf8 "$s" "$HTML_ESCAPE_MAX_LEN")"
  html_escape "$s"
}

# --- CLI ---------------------------------------------------------------------
# When EXECUTED directly (not sourced), act as the filter the review skill calls
# to sanitize one YNAB-sourced value before it enters a fragment. Sourcing skips
# this block entirely, so persona.sh / report-writer.sh get the functions only.
#   html-escape.sh -- <string>       full YNAB sanitize (strip → truncate → escape)
#   html-escape.sh --raw -- <string> metacharacter escape ONLY (no strip/truncate)
# `--` ends option parsing, so a value that ITSELF looks like a flag — a payee
# literally named `-h`, `--help`, or `--raw` — is always treated as data, never
# dispatched as an option. The untrusted CLI route therefore can't be hijacked by
# an attacker-chosen value (issue #30 blocker: without `--`, a payee named `--help`
# printed this file's header — which contains a literal <script> — into the report,
# and `--raw` silently dropped the value). Callers MUST pass `--` before the value;
# the review skill's call site does. --raw is the explicit opt-out (metacharacter
# escape only) for a caller-owned, already-bounded value.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  mode=sanitize
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) sed -n '2,/^$/p' "$0"; exit 0 ;;
      --raw)     mode=raw; shift ;;
      --)        shift; break ;;
      -*)        printf 'html-escape.sh: unknown option: %s\n' "$1" >&2; exit 2 ;;
      *)         break ;;   # first non-flag is the value — treat everything after as data
    esac
  done
  if [ "$mode" = raw ]; then
    # --raw skips the sanitize path's byte gate, but html_escape's `${//}`
    # substitutions are super-linear on match-dense input (its COST CONTRACT
    # above) — so the CLI still enforces the caller contract with an O(1)
    # BYTE-length check via _byte_len (`${#raw_value}` in the ambient UTF-8
    # locale counts CHARACTERS, under-counting multibyte input up to 4× —
    # round-6 blocker). --raw exists for caller-owned, ALREADY-BOUNDED values;
    # any plausible owned scalar fits well inside 4096 bytes, and a bigger
    # value is a contract violation refused LOUDLY rather than truncated
    # silently (a silently-sliced owned value — a path, say — is worse than an
    # error). Untrusted/unbounded input belongs on the default sanitize path,
    # which bounds and truncates by design.
    raw_value="${1-}"
    raw_bytes="$(_byte_len "$raw_value")"
    if [ "$raw_bytes" -gt 4096 ]; then
      printf 'html-escape.sh: --raw value byte length %s exceeds 4096 — --raw is for caller-owned, already-bounded values; pass untrusted input through the default sanitize mode instead\n' \
        "$raw_bytes" >&2
      exit 2
    fi
    html_escape "$raw_value"
  else
    escape_ynab_string "${1-}"
  fi
fi
