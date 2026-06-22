#!/usr/bin/env bash
#
# bin/report-writer.sh — assemble a YNAB review report from the frozen template
# (M2-5, issue #42) + the universal review skill's fragments, and write it to the
# configured output directory (M2-9, issue #46).
#
# WHAT THIS IS
#   The ONE place the full report HTML is assembled. The review skill (M2-3,
#   issue #40) emits fragments only — it never regenerates the report chrome. This
#   writer stitches the constant template (`<!-- SLOT:name -->` block slots +
#   `{{name}}` scalar slots) together with those fragments and saves the result.
#   Centralising assembly here is the locked anti-pattern fix: the skill produces
#   variable content, the template stays a constant, and chrome is never
#   regenerated per run.
#
# WHY A SEPARATE HELPER (not inline in the skill)
#   The skill is a markdown protocol; the deterministic string-stitch + path
#   resolution + completeness check belong in a testable shell unit, exactly as
#   persona-name resolution lives in bin/persona.sh and config reads in
#   bin/config.sh. The full contract lives in docs/report-writer.md.
#
# OUTPUT DIRECTORY — CONFIGURABLE, OUTSIDE-REPO, UPDATE-SURVIVING
#   The save directory comes from `.report.output_dir` in the user's config.json,
#   which lives OUTSIDE the repo at
#     $HOME/.claude/plugins/data/workbench-ynab-claude-workbench/config.json
#   so it SURVIVES plugin updates. It is read with the same default-fallback idiom
#   as workbench-core/hooks/mcp-memory.sh (`jq -r '<path> // empty'`, then a shell
#   default) — reused here via bin/config.sh's `_cfg`. When the field is absent or
#   empty the shipped default `~/Documents/Claude/Reports` applies (the prototype's
#   original location, SKILL.md line 143). NB: the literal field is `.report.output_dir`
#   (the schema's nested `report` object), not a flat top-level key — the config
#   schema, loader, and review skill all already use this path.
#
# USAGE
#   report-writer.sh \
#     --tier   <Weekly|Monthly|Quarterly-Tax|Annual> \
#     --date   <YYYY-MM-DD> \
#     [--template   <path>]    # default: .report.template_path, else bundled asset
#     [--output-dir <dir>]     # default: .report.output_dir, else ~/Documents/Claude/Reports
#     --slot   <name>=<html>   # repeatable: ONE per block slot in the template
#     …
#
#   On success: writes the assembled HTML to the resolved absolute path, creates
#   the directory tree if needed, and prints that absolute path to stdout (a
#   single line, usable directly as a shell variable by the caller).
#
#   Completeness is enforced: every block slot the template declares must be
#   supplied via --slot. A section with nothing to report is supplied as the
#   literal `no findings` (rendered as an empty section, the <section> stays).
#   Any required slot left unsupplied — or supplied empty without the sentinel —
#   prints an error to stderr and exits non-zero WITHOUT writing a file. No
#   partial / silently-empty reports.
#
# EXIT CODES
#   0  report written
#   1  a required slot was missing / empty (no file written)
#   2  usage error (bad flag, bad tier, bad date, unknown slot, missing template)
#
# bash 3.2 compatible (macOS system bash): indexed arrays only (no associative
# arrays / `declare -A`), no `${x,,}`, no mapfile. Array expansions are guarded so
# `set -u` never trips on an empty array.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Shipped fallback output directory (prototype default, SKILL.md line 143),
# notated to the user as ~/Documents/Claude/Reports. Resolved eagerly via $HOME
# so it is already absolute before path handling.
DEFAULT_OUTPUT_DIR="$HOME/Documents/Claude/Reports"
DEFAULT_TEMPLATE="${REPO_ROOT}/assets/report/template.html"

# Reuse the shared loader's `_cfg` (jq-read with `// empty`) so the config shape
# is defined once. Sourcing only defines functions + YNAB_CONFIG_FILE; it honours
# a pre-set YNAB_CONFIG_FILE (the test seam) and has no load-time side effects.
# shellcheck source=/dev/null
. "${REPO_ROOT}/bin/config.sh"

prog="report-writer.sh"
err()   { printf '%s: %s\n' "$prog" "$1" >&2; }
usage_err() { err "$1"; exit 2; }

# expand_path <path> — resolve a leading ~ and $VAR / ${VAR} references WITHOUT
# eval (no command/arithmetic substitution is ever executed — a config path is
# data, not code). Only simple variable references expand; a literal ~ appears
# only as the leading component.
expand_path() {
  local p="$1" guard=0 match name value
  # Literal ~ in these case patterns is intentional: we MATCH an input that
  # begins with a literal tilde and rewrite it to $HOME. (Not a tilde meant to
  # shell-expand — that is exactly what this function exists to do by hand.)
  # shellcheck disable=SC2088
  case "$p" in
    "~")   p="$HOME" ;;
    "~/"*) p="${HOME}/${p#\~/}" ;;
  esac
  # Expand $NAME and ${NAME}. The guard caps iterations so a value that itself
  # contains a literal '$' can never loop forever.
  while [ "$guard" -lt 64 ]; do
    if [[ "$p" =~ (\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)) ]]; then
      match="${BASH_REMATCH[1]}"
      name="${BASH_REMATCH[2]:-${BASH_REMATCH[3]}}"
      value="${!name:-}"
      p="${p//"$match"/$value}"
    else
      break
    fi
    guard=$((guard + 1))
  done
  printf '%s' "$p"
}

# --- parse args -------------------------------------------------------------
tier=""
date=""
cli_template=""
cli_output_dir=""
slot_names=()
slot_values=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tier)       [ "$#" -ge 2 ] || usage_err "--tier needs a value";       tier="$2";           shift 2 ;;
    --date)       [ "$#" -ge 2 ] || usage_err "--date needs a value";       date="$2";           shift 2 ;;
    --template)   [ "$#" -ge 2 ] || usage_err "--template needs a value";   cli_template="$2";   shift 2 ;;
    --output-dir) [ "$#" -ge 2 ] || usage_err "--output-dir needs a value"; cli_output_dir="$2"; shift 2 ;;
    --slot)
      [ "$#" -ge 2 ] || usage_err "--slot needs a <name>=<value> argument"
      case "$2" in
        *=*) : ;;
        *)   usage_err "--slot expects <name>=<value>, got: $2" ;;
      esac
      slot_names+=("${2%%=*}")     # name = before the FIRST '='
      slot_values+=("${2#*=}")     # value = everything after it (HTML may contain '=')
      shift 2
      ;;
    -h|--help)
      sed -n '2,60p' "$0"
      exit 0
      ;;
    --*) usage_err "unknown flag: $1" ;;
    *)   usage_err "unexpected argument: $1" ;;
  esac
done

# --- validate tier + date ---------------------------------------------------
case "$tier" in
  Weekly|Monthly|Quarterly-Tax|Annual) : ;;
  "") usage_err "--tier is required (one of: Weekly, Monthly, Quarterly-Tax, Annual)" ;;
  *)  usage_err "invalid --tier '$tier' (expected: Weekly, Monthly, Quarterly-Tax, Annual)" ;;
esac
case "$date" in
  [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]) : ;;
  "") usage_err "--date is required (YYYY-MM-DD)" ;;
  *)  usage_err "invalid --date '$date' (expected YYYY-MM-DD)" ;;
esac

# --- resolve template -------------------------------------------------------
template="$cli_template"
[ -z "$template" ] && template="$(_cfg '.report.template_path')"
[ -z "$template" ] && template="$DEFAULT_TEMPLATE"
template="$(expand_path "$template")"
[ -f "$template" ] || usage_err "template not found: $template"

# --- resolve output directory (config → default), tolerate a trailing slash --
out_dir="$cli_output_dir"
[ -z "$out_dir" ] && out_dir="$(_cfg '.report.output_dir')"
[ -z "$out_dir" ] && out_dir="$DEFAULT_OUTPUT_DIR"
out_dir="$(expand_path "$out_dir")"
out_dir="${out_dir%/}"          # drop one trailing slash so the join never doubles it

# --- build the output path: YNAB-{Tier}-Review-YYYY-MM-DD.html --------------
out_path="${out_dir}/YNAB-${tier}-Review-${date}.html"

# --- required block slots are whatever the (frozen) template declares -------
# Deriving the set from the template keeps the writer swap-ready: a template
# change can never silently desync a hardcoded slot list here.
required_slots=()
while IFS= read -r name; do
  [ -n "$name" ] && required_slots+=("$name")
done < <(grep -oE '<!-- SLOT:[a-z0-9-]+ -->' "$template" \
           | sed -E 's/^<!-- SLOT:([a-z0-9-]+) -->$/\1/' | sort -u)

if [ "${#required_slots[@]}" -eq 0 ]; then
  usage_err "template declares no <!-- SLOT:name --> block slots: $template"
fi

# slot_index <name> — echo the index of <name> in slot_names, return 1 if absent.
slot_index() {
  local target="$1" i
  for (( i = 0; i < ${#slot_names[@]}; i++ )); do
    if [ "${slot_names[$i]}" = "$target" ]; then printf '%s' "$i"; return 0; fi
  done
  return 1
}

# --- completeness check (BEFORE any write) ----------------------------------
# Every required slot must be supplied and non-empty; the literal `no findings`
# is the explicit "intentionally empty" marker (rendered as an empty section).
missing=()
for (( r = 0; r < ${#required_slots[@]}; r++ )); do
  rs="${required_slots[$r]}"
  if idx="$(slot_index "$rs")"; then
    [ -z "${slot_values[$idx]}" ] && missing+=("$rs")
  else
    missing+=("$rs")
  fi
done

# Unknown slots are almost always a caller typo that would leave the real slot
# unfilled — reject them loudly rather than ignore them.
unknown=()
for (( i = 0; i < ${#slot_names[@]}; i++ )); do
  n="${slot_names[$i]}"
  found=0
  for (( r = 0; r < ${#required_slots[@]}; r++ )); do
    [ "${required_slots[$r]}" = "$n" ] && { found=1; break; }
  done
  [ "$found" -eq 0 ] && unknown+=("$n")
done

if [ "${#missing[@]}" -gt 0 ]; then
  err "refusing to write a partial report — these required slots are missing or empty:"
  for (( i = 0; i < ${#missing[@]}; i++ )); do err "  • ${missing[$i]}"; done
  err "supply each via --slot <name>=<html>, or --slot <name>='no findings' to leave it intentionally empty."
  exit 1
fi
if [ "${#unknown[@]}" -gt 0 ]; then
  err "unknown slot name(s) not declared by the template:"
  for (( i = 0; i < ${#unknown[@]}; i++ )); do err "  • ${unknown[$i]}"; done
  exit 2
fi

# --- assemble: constant template + variable fragments + scalar slots --------
# Literal bash substitution (the persona.sh idiom): the needle is quoted so it is
# matched literally (no glob), and the replacement is taken verbatim — safe for
# arbitrary HTML in a fragment value.
html="$(cat "$template")"
for (( i = 0; i < ${#slot_names[@]}; i++ )); do
  n="${slot_names[$i]}"
  v="${slot_values[$i]}"
  [ "$v" = "no findings" ] && v=""     # explicit-empty sentinel → empty section
  needle="<!-- SLOT:${n} -->"
  html="${html//"$needle"/$v}"
done
# Scalar slots. {{output_path}} is decided here (never hardcoded in the template).
html="${html//\{\{tier\}\}/$tier}"
html="${html//\{\{report_date\}\}/$date}"
html="${html//\{\{output_path\}\}/$out_path}"

# --- write + emit the path --------------------------------------------------
mkdir -p "$out_dir"
printf '%s\n' "$html" > "$out_path"
printf '%s\n' "$out_path"
