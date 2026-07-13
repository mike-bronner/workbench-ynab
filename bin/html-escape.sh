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
html_escape() {
  local s="${1-}" sq="'"   # hold the single quote in a var: a bare ' inside the
  s="${s//&/&amp;}"        # parameter expansion below would confuse the parser.
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//$sq/&#39;}"
  printf '%s' "$s"
}

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

# _strip_bidi <str> — remove the Unicode bidirectional override / isolate format
# characters (U+202A–U+202E, U+2066–U+2069). They inject no markup, but they
# visually reorder surrounding text, so a value like `PayPal<U+202E>txt.exe` can
# masquerade as another name in a report. Removed by literal substring
# replacement (encoding-agnostic). Shared by escape_ynab_string (the HTML sink)
# and persona.sh's render_voice (the model-context sink) so the bidi code-point
# list lives in exactly ONE place, never a copy that can drift (#28).
_strip_bidi() {
  local s="${1-}" bidi
  for bidi in $'\xe2\x80\xaa' $'\xe2\x80\xab' $'\xe2\x80\xac' $'\xe2\x80\xad' $'\xe2\x80\xae' \
              $'\xe2\x81\xa6' $'\xe2\x81\xa7' $'\xe2\x81\xa8' $'\xe2\x81\xa9'; do
    s="${s//"$bidi"/}"
  done
  printf '%s' "$s"
}

# escape_ynab_string <str> — sanitize one untrusted, externally-sourced value for
# safe interpolation into an HTML report fragment. Four ordered steps, each a
# prerequisite of the next:
#   1. Strip C0 control characters (U+0000–U+001F) EXCEPT tab (U+0009) and newline
#      (U+000A). LC_ALL=C makes `tr` operate byte-wise; every stripped code point
#      is a single byte that can NEVER appear inside a UTF-8 multibyte sequence
#      (continuation bytes are 0x80–0xBF), so right-to-left text, accents, and
#      emoji pass through untouched — only the invisible layout-wrecking controls
#      are removed.
#   2. Strip Unicode bidirectional override / isolate format characters
#      (U+202A–U+202E, U+2066–U+2069) via the shared _strip_bidi helper. They
#      inject no markup, but they visually reorder surrounding text, so a payee
#      like `PayPal<U+202E>txt.exe` can masquerade as another name in an
#      anomaly/fraud report. Removed as defense-in-depth.
#   3. Truncate to HTML_ESCAPE_MAX_LEN CHARACTERS (not bytes) with a visible
#      ellipsis (…) when longer, so one unusually long payee or memo can never
#      break the layout. Character-safe (see _truncate_utf8) and done BEFORE
#      escaping so the limit counts source characters, not the inflated entity forms.
#   4. html_escape the result LAST, so nothing steps 1–3 leave behind can reach the
#      markup unescaped.
escape_ynab_string() {
  local s="${1-}"
  s="$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013-\037')"
  s="$(_strip_bidi "$s")"
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
    html_escape "${1-}"
  else
    escape_ynab_string "${1-}"
  fi
fi
