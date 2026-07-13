#!/usr/bin/env bash
#
# persona.sh — resolve the configured financial-assistant persona name and
# render the persona-stamped surfaces (report footer, dispatch sign-off).
#
# Single source of truth for the persona-name substitution described in
# docs/persona.md. Skills, wrappers, and the report writer call this instead of
# re-implementing the config read or hardcoding a name, so the resolution order
# lives in exactly one place and the name is substituted consistently everywhere
# it appears.
#
# The resolved name is consumed by the SKILL only. It is NEVER forwarded to the
# vendored YNAB MCP — that server receives only the token + package-native env
# (see docs/persona.md, "Boundary").
#
# Usage:
#   bash bin/persona.sh name           # print the resolved persona name (default)
#   bash bin/persona.sh html-name      # the resolved name, HTML-escaped (footer slot)
#   bash bin/persona.sh footer [when]  # render the report footer  (AC 7)
#   bash bin/persona.sh signoff        # render the dispatch sign-off (AC 8)
#
# Name resolution precedence (first non-empty wins):
#   1. .persona.name in the workbench-ynab plugin config — explicit override.
#   2. .agent_name   in the workbench-core plugin config — the requesting
#      agent's own persona, so the assistant speaks as the Claude agent that
#      runs the review rather than an invented name.
#   3. "Hobbes"      — the shipped standalone default for a user who has neither
#      config (the public, no-workbench-core case).
#
# Config paths (overridable for tests):
#   ynab:  YNAB_CONFIG_FILE          ~/.claude/plugins/data/workbench-ynab-claude-workbench/config.json
#   core:  WORKBENCH_CORE_CONFIG_FILE ~/.claude/plugins/data/workbench-core-claude-workbench/config.json
#          (when unset, the legacy ~/.claude/plugins/data/workbench-claude-workbench/config.json
#           is probed too, for parity with workbench-core's hooks/mcp-memory.sh)
#
# Footer template (overridable for tests):
#   YNAB_FOOTER_TEMPLATE            <repo>/assets/templates/report-footer.html
#
# Every read is total: an absent config file, missing jq, malformed JSON, or an
# absent/null field is swallowed and the next tier takes over, ending at
# "Hobbes" — no error, exit 0.

set -u

DEFAULT_PERSONA_NAME="Hobbes"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The ONE shared, audited HTML escaper (GAP-13 / #28): the footer is an HTML
# fragment, so the persona name is escaped through the same html_escape every
# other externally-sourced string goes through — no private copy. Sourcing also
# disables `patsub_replacement`, which is what makes the escaping correct on
# bash ≥5.2 (the #126 footer bug).
# shellcheck source=/dev/null
. "${REPO_ROOT}/bin/html-escape.sh"

: "${YNAB_CONFIG_FILE:=$HOME/.claude/plugins/data/workbench-ynab-claude-workbench/config.json}"
FOOTER_TEMPLATE="${YNAB_FOOTER_TEMPLATE:-$REPO_ROOT/assets/templates/report-footer.html}"

# workbench-core config: honor an explicit override; otherwise probe the current
# location and the legacy pre-rename location (parity with mcp-memory.sh).
if [ -n "${WORKBENCH_CORE_CONFIG_FILE:-}" ]; then
  CORE_CONFIG_CANDIDATES=("$WORKBENCH_CORE_CONFIG_FILE")
else
  CORE_CONFIG_CANDIDATES=(
    "$HOME/.claude/plugins/data/workbench-core-claude-workbench/config.json"
    "$HOME/.claude/plugins/data/workbench-claude-workbench/config.json"
  )
fi

# Read a jq path from a config file, echoing empty on any failure. Mirrors the
# workbench-core hooks/mcp-memory.sh `_cfg` idiom: guard the file, guard jq,
# swallow parse errors, let `// empty` collapse a missing/null field to empty so
# the caller's fallback takes over.
_cfg() {
  local file="$1" path="$2"
  [ -f "$file" ] && command -v jq >/dev/null 2>&1 \
    && jq -r "$path // empty" "$file" 2>/dev/null
}

# Echo the first existing workbench-core config candidate, or nothing.
_core_config() {
  local f
  for f in "${CORE_CONFIG_CANDIDATES[@]}"; do
    [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
}

# Strip leading/trailing whitespace so a whitespace-only config value counts as
# empty — the contract is "first NON-EMPTY tier wins", and "   " is not a name.
_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"   # strip leading whitespace
  s="${s%"${s##*[![:space:]]}"}"   # strip trailing whitespace
  printf '%s' "$s"
}

# HTML-escape a value for safe substitution into the HTML footer. Walk the
# string one character at a time and append the entity for each special char.
# A character loop — rather than a chain of `${s//c/&ent;}` substitutions — is
# deliberate: bash 5.2 turned on the `patsub_replacement` shell option by
# default, which makes an unquoted `&` in a `${//}` replacement stand for the
# text matched by the pattern, so `${s//</&lt;}` corrupts `<` into `<lt;` there
# (bash < 5.2 keeps `&` literal — the option is `#if 0` dead code in 5.0/5.1 —
# which is why the bug only surfaced on the GNU/Linux CI runner, where
# ubuntu-latest ships bash 5.2). Appending literal single-quoted entities
# sidesteps that reinterpretation entirely and behaves identically on bash 3.2
# and 5.2 (#126). Only the footer needs this — it is an HTML fragment; the
# sign-off is plain text (a different output context) and stays literal.
_html_escape() {
  local s="$1" out="" i c
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      '&') out+='&amp;'  ;;
      '<') out+='&lt;'   ;;
      '>') out+='&gt;'   ;;
      '"') out+='&quot;' ;;
      "'") out+='&#39;'  ;;
      *)   out+="$c"     ;;
    esac
  done
  printf '%s' "$out"
}

# Render <template> by substituting each {{placeholder}} with its paired value in
# a SINGLE left-to-right pass: at each step, find the earliest-occurring
# remaining placeholder in the still-unconsumed template tail, emit the text
# before it followed by that value VERBATIM, then advance past the placeholder.
#
# Only the template's own tail is ever scanned for placeholders — an inserted
# value is emitted and never re-examined. Two consequences matter here:
#   * A value that itself contains a `{{…}}` token (an HTML-escaped persona name
#     preserves `{`/`}`) can never be mistaken for a LATER placeholder. A chain
#     of first-occurrence splices would do exactly that: a hostile name like
#     `pwned {{generated_at}} pwned` spliced into `{{persona}}` smuggles in a
#     `{{generated_at}}` that the next splice then consumes, leaking the real
#     trailing placeholder and misplacing the date (#126, review blocker #1).
#   * An absent placeholder simply never matches, so a template missing one is
#     emitted intact rather than duplicated.
#   * A degenerate EMPTY placeholder key is ignored, never treated as a match: a
#     zero-length token matches at every position yet consumes nothing, so
#     selecting it would spin the loop forever — the inner scan considers only
#     non-empty keys, and an all-empty-keys arg list falls through to the
#     `out+="$rest"` terminator.
# Values are inserted verbatim (no `${//}` replacement anywhere), so bash 5.2's
# patsub_replacement `&`-as-matched-text semantics never apply.
#
# Usage: _render_template <template> <placeholder> <value> [<placeholder> <value>]...
_render_template() {
  local template="$1"; shift
  local out="" rest="$template"
  while [ -n "$rest" ]; do
    # Pick the placeholder that occurs earliest in the unconsumed tail.
    local best_ph="" best_val="" best_prefix="" best_idx=-1
    local i=1
    while [ "$i" -lt "$#" ]; do
      local ph="${!i}" j=$((i + 1))
      local val="${!j}" prefix="${rest%%"$ph"*}"
      # Skip an EMPTY key outright: `${rest%%""*}` always strips to "" (a
      # zero-length match at position 0), which would be picked as the earliest
      # match yet advance nothing (`${rest#*""}` strips nothing), hanging the
      # outer loop. For a non-empty key, `${rest%%"$ph"*}` equals "$rest" only
      # when $ph does not occur in $rest; otherwise the strip leaves a strictly
      # shorter prefix ending at $ph.
      if [ -n "$ph" ] && [ "$prefix" != "$rest" ]; then
        if [ "$best_idx" -lt 0 ] || [ "${#prefix}" -lt "$best_idx" ]; then
          best_idx=${#prefix}; best_ph="$ph"; best_val="$val"; best_prefix="$prefix"
        fi
      fi
      i=$((i + 2))
    done
    if [ "$best_idx" -lt 0 ]; then
      out+="$rest"; break        # no placeholder left in the tail
    fi
    out+="${best_prefix}${best_val}"
    rest="${rest#*"$best_ph"}"
  done
  printf '%s' "$out"
}

persona_name() {
  local name core
  # 1. ynab plugin's explicit persona.name
  name="$(_trim "$(_cfg "$YNAB_CONFIG_FILE" '.persona.name')")"
  # 2. the requesting agent's own name from workbench-core
  if [ -z "$name" ]; then
    core="$(_core_config)"
    [ -n "$core" ] && name="$(_trim "$(_cfg "$core" '.agent_name')")"
  fi
  # 3. shipped standalone default
  printf '%s\n' "${name:-$DEFAULT_PERSONA_NAME}"
}

render_footer() {
  local when="${1:-$(date '+%Y-%m-%d')}" name template
  name="$(persona_name)"
  if [ -f "$FOOTER_TEMPLATE" ]; then
    template="$(cat "$FOOTER_TEMPLATE")"
  else
    # Inline fallback keeps the renderer total even if the asset is missing.
    template='Generated by {{persona}} — {{generated_at}}'
  fi
  # The footer is an HTML fragment, so escape both substituted values through the
  # shared html_escape for the HTML output context: an ordinary name like
  # "Smith & Sons" must emit a valid entity (&amp;), and any stray markup is
  # neutralised rather than injected.
  template="${template//\{\{persona\}\}/$(html_escape "$name")}"
  template="${template//\{\{generated_at\}\}/$(html_escape "$when")}"
  printf '%s\n' "$template"
}

render_signoff() {
  printf '— %s, your financial assistant\n' "$(persona_name)"
}

# Dispatch the CLI only when executed directly. When another script sources this
# file to unit-test the helpers (e.g. _render_template / _html_escape), the guard
# is false so the CLI never runs — the same pattern as tests/unit/test-audit-log.sh
# sourcing bin/audit-log.sh.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-name}" in
    name)      persona_name ;;
    # The HTML-escaped name, for the report chrome's `SLOT:footer-persona` block
    # slot (see skills/review/ynab-review.md §8). Routes through the SAME tested
    # `_html_escape` the footer uses, so the review skill injects it verbatim
    # rather than hand-escaping the raw name a second time (#126 review follow-up).
    html-name) printf '%s\n' "$(_html_escape "$(persona_name)")" ;;
    footer)    shift; render_footer "$@" ;;
    signoff)   render_signoff ;;
    *)
      printf 'persona.sh: unknown subcommand %q (expected: name|html-name|footer|signoff)\n' "$1" >&2
      exit 2
      ;;
  esac
fi
