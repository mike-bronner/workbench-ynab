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
# deliberate: bash 5.0 made an unquoted `&` in a `${//}` replacement stand for
# the text matched by the pattern, so `${s//</&lt;}` corrupts `<` into `<lt;`
# there (bash 3.2 keeps `&` literal, which is why the bug only surfaced on the
# GNU/Linux CI runner). Appending literal single-quoted entities sidesteps that
# reinterpretation entirely and behaves identically on bash 3.2 and 5.x (#126).
# Only the footer needs this — it is an HTML fragment; the sign-off is plain text
# (a different output context) and stays literal.
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

# Splice <value> into <template> at the first <placeholder>, inserting the value
# VERBATIM. Unlike `${template//{{x}}/$value}`, this never reinterprets the
# value: bash 5.0 treats an unquoted `&` in a `${//}` replacement as the text
# matched by the pattern, so an already-escaped value like `Smith &amp; Sons`
# corrupts into `Smith {{persona}}amp; Sons`. Prefix/suffix removal splices the
# value in as-is on both bash 3.2 and 5.x (#126). The footer templates (the
# shipped asset and the inline fallback) each carry exactly one of each
# placeholder, so a single-occurrence splice is sufficient.
_splice() {
  local template="$1" placeholder="$2" value="$3"
  printf '%s' "${template%%"$placeholder"*}${value}${template#*"$placeholder"}"
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
  # The footer is an HTML fragment, so escape both substituted values for the
  # HTML output context: an ordinary name like "Smith & Sons" must emit a valid
  # entity (&amp;), and any stray markup is neutralised rather than injected.
  # Splice the escaped values in verbatim — a plain `${//}` would let bash 5.0
  # reinterpret the `&` in an entity as the matched placeholder (see _splice).
  template="$(_splice "$template" '{{persona}}' "$(_html_escape "$name")")"
  template="$(_splice "$template" '{{generated_at}}' "$(_html_escape "$when")")"
  printf '%s\n' "$template"
}

render_signoff() {
  printf '— %s, your financial assistant\n' "$(persona_name)"
}

case "${1:-name}" in
  name)    persona_name ;;
  footer)  shift; render_footer "$@" ;;
  signoff) render_signoff ;;
  *)
    printf 'persona.sh: unknown subcommand %q (expected: name|footer|signoff)\n' "$1" >&2
    exit 2
    ;;
esac
