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
#     filter — `bash "${CLAUDE_PLUGIN_ROOT}/bin/html-escape.sh" "$payee"` — to
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

# escape_ynab_string <str> — sanitize one untrusted, externally-sourced value for
# safe interpolation into an HTML report fragment. Three ordered steps, each a
# prerequisite of the next:
#   1. Strip C0 control characters (U+0000–U+001F) EXCEPT tab (U+0009) and newline
#      (U+000A). LC_ALL=C makes `tr` operate byte-wise; every stripped code point
#      is a single byte that can NEVER appear inside a UTF-8 multibyte sequence
#      (continuation bytes are 0x80–0xBF), so right-to-left text, accents, and
#      emoji pass through untouched — only the invisible layout-wrecking controls
#      are removed.
#   2. Truncate to HTML_ESCAPE_MAX_LEN characters with a visible ellipsis (…) when
#      longer, so one unusually long payee or memo can never break the layout.
#      Done BEFORE escaping so the limit counts source characters, not the inflated
#      entity forms.
#   3. html_escape the result LAST, so nothing steps 1–2 leave behind can reach the
#      markup unescaped.
escape_ynab_string() {
  local s="${1-}"
  s="$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013-\037')"
  [ "${#s}" -gt "$HTML_ESCAPE_MAX_LEN" ] && s="${s:0:$HTML_ESCAPE_MAX_LEN}…"
  html_escape "$s"
}

# --- CLI ---------------------------------------------------------------------
# When EXECUTED directly (not sourced), act as the filter the review skill calls
# to sanitize one YNAB-sourced value before it enters a fragment. Sourcing skips
# this block entirely, so persona.sh / report-writer.sh get the functions only.
#   html-escape.sh <string>          full YNAB sanitize (strip → truncate → escape)
#   html-escape.sh --raw <string>    metacharacter escape ONLY (no strip/truncate)
# The unflagged default is the SAFE one — the sanitize path — so the untrusted
# route is the one you reach without thinking; --raw is the explicit opt-out for a
# caller-owned, already-bounded value.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1-}" in
    -h|--help)
      sed -n '2,/^$/p' "$0"
      ;;
    --raw)
      html_escape "${2-}"
      ;;
    *)
      escape_ynab_string "${1-}"
      ;;
  esac
fi
