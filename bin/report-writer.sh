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

# bash 5.2 enables `patsub_replacement` by default, which makes a literal `&` in
# a `${var//pat/repl}` REPLACEMENT expand to the matched text (sed-style). Every
# substitution here — html_escape's entities (`&lt;`, `&gt;`, …) and the block/
# scalar slot fills — intends `&` to be LITERAL, so turn it off for identical
# behaviour on bash 3.2 (macOS) through 5.2+ (Linux CI). Without this, the
# security-relevant HTML escaping silently produces `<lt;` instead of `&lt;`.
shopt -u patsub_replacement 2>/dev/null || true

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
# data, not code), returning the FULLY resolved path or FAILING (non-zero, no
# output) rather than a partially-resolved one. The tilde and the variable
# substitution run in ONE fixpoint loop: each pass resolves a leading ~ AND the
# first $VAR/${VAR}, then repeats until the string stops changing. Expansion is
# therefore TRANSITIVE — a $VAR whose value itself contains $OTHER expands too —
# and a leading ~ introduced by a variable's VALUE (not just one typed literally
# at the front) is resolved as well, which a single pre-loop tilde check missed.
#
# A partially-resolved path is NEVER emitted. If the result still carries a
# component-leading ~ (a `~user`, or a `~` a variable's value introduced mid-path)
# or an unresolved $VAR after the loop settles — a self-referential
# value like FOO='$FOO/x' that exhausts the guard, or any value the shell cannot
# fully expand — the function returns 1 WITHOUT printing, and the caller turns
# that into a usage_err (exit 2, no file). Silently writing to `$PWD/~/…` or a
# path still holding a literal `$FOO` is exactly the falsely-successful report
# this helper exists to prevent.
expand_path() {
  local p="$1" guard=0 before match name value
  # Literal ~ in these case patterns is intentional: we MATCH an input that
  # begins with a literal tilde and rewrite it to $HOME. (Not a tilde meant to
  # shell-expand — that is exactly what this function exists to do by hand.)
  # The guard caps iterations so a self-referential value can never loop forever.
  # shellcheck disable=SC2088
  while [ "$guard" -lt 64 ]; do
    before="$p"
    # Resolve a leading ~ — including one a variable's value introduced on an
    # earlier pass (the old single pre-loop check never saw those).
    case "$p" in
      "~")   p="$HOME" ;;
      "~/"*) p="${HOME}/${p#\~/}" ;;
    esac
    # Resolve the first $NAME / ${NAME} reference (an unset name → empty).
    if [[ "$p" =~ (\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)) ]]; then
      match="${BASH_REMATCH[1]}"
      name="${BASH_REMATCH[2]:-${BASH_REMATCH[3]}}"
      value="${!name:-}"
      p="${p//"$match"/$value}"
    fi
    # Nothing changed this pass → settled (fully resolved, or stuck on a
    # self-reference the checks below will reject).
    [ "$p" = "$before" ] && break
    guard=$((guard + 1))
  done
  # Refuse a still-partial path rather than emit it. The tilde and $VAR guards are
  # SYMMETRIC — each rejects its token wherever it survives the loop, not just at
  # the front:
  #   * A `~` that begins ANY path component (start-of-string OR right after a `/`)
  #     is refused. The loop resolves a LEADING current-user `~`/`~/`; every other
  #     tilde form is one this helper deliberately does NOT expand — a `~user`
  #     (another user's home; expanding it needs eval or passwd parsing, both barred
  #     by the no-eval design) or a `~` a variable's value shoved mid-string
  #     (`prefix/$VAR` with VAR='~/x' → `prefix/~/x`). Emitting either would write to
  #     a LITERAL `~mike`/`~` directory at exit 0 — the falsely-successful report
  #     this helper exists to prevent. A `~` MID-component (a literal char in a name
  #     like `file~backup`) is not a tilde form and is left untouched.
  #   * A surviving $VAR/${VAR} anywhere (a self-referential value that exhausts the
  #     guard, or any value the shell cannot expand) is likewise refused.
  # The caller turns the non-zero return into a usage_err (exit 2, no file).
  # shellcheck disable=SC2088
  case "$p" in "~"* | *"/~"*) return 1 ;; esac
  [[ "$p" =~ (\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*) ]] && return 1
  printf '%s' "$p"
}

# html_escape <string> — escape the five HTML metacharacters (`&`, `<`, `>`, `"`,
# `'`) so a scalar the writer injects into the report (the output path, the tier,
# the date) can never break out of an attribute or inject an element. The writer
# OWNS escaping the scalars it places; fragment values are escaped by their
# producer (the review skill's trust-boundary rule). '&' is replaced first so
# entities it introduces are not double-escaped. The apostrophe (`&#39;`) is
# defense-in-depth: the frozen template only ever places scalars in double-quoted
# attributes or text nodes, but escaping it too means a future single-quoted
# attribute could never be broken out of either.
html_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&#39;}"
  printf '%s' "$s"
}

# trim <string> — strip leading and trailing whitespace. Used so a whitespace-only
# --slot value ("   ") is judged empty (hence missing) rather than passing the
# completeness guard and rendering a silently-blank section.
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
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
      slot_name="${2%%=*}"         # name = before the FIRST '='
      # Validate the name at PARSE time (allowed: lowercase letters, digits,
      # hyphen) — the exact charset a template `<!-- SLOT:name -->` marker uses.
      # The single-pass block-slot walk below matches each marker name against the
      # supplied names (via slot_index, an exact string compare); rejecting a glob
      # metachar or other stray character here keeps a supplied name from ever
      # masquerading as — or failing to match — a declared marker, so the
      # completeness check and the walk agree on exactly one value per slot.
      case "$slot_name" in
        ""|*[!a-z0-9-]*) usage_err "invalid --slot name '$slot_name' (allowed: lowercase letters, digits, hyphen)" ;;
      esac
      # Reject a DUPLICATE --slot name loudly. Slot resolution keeps the FIRST
      # occurrence (slot_index returns the earliest match) — the opposite of the
      # conventional last-wins flag idiom — so a repeated name would silently drop
      # the caller's later value. For a strict one-`--slot`-per-block-slot contract
      # a duplicate is a near-certain mistake; fail rather than guess which wins.
      for (( dup_i = 0; dup_i < ${#slot_names[@]}; dup_i++ )); do
        [ "${slot_names[$dup_i]}" = "$slot_name" ] \
          && usage_err "duplicate --slot name '$slot_name' (supply each block slot exactly once)"
      done
      slot_names+=("$slot_name")
      slot_values+=("${2#*=}")     # value = everything after it (HTML may contain '=')
      shift 2
      ;;
    -h|--help)
      # Print the whole leading comment block (line 2 → the first blank line) so a
      # header that grows can never be truncated the way a hardcoded end-line was.
      sed -n '2,/^$/p' "$0"
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
# Shape AND range: month 01-12, day 01-31 (a real calendar day-of-month check —
# e.g. Feb 30 — is beyond the AC and left to the caller, but obviously-invalid
# values like month 13 / day 39 are rejected here rather than baked into a filename).
if [ -z "$date" ]; then
  usage_err "--date is required (YYYY-MM-DD)"
elif [[ ! "$date" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]]; then
  usage_err "invalid --date '$date' (expected YYYY-MM-DD, month 01-12, day 01-31)"
fi

# --- resolve template -------------------------------------------------------
template="$cli_template"
[ -z "$template" ] && template="$(_cfg '.report.template_path')"
[ -z "$template" ] && template="$DEFAULT_TEMPLATE"
template="$(expand_path "$template")" || usage_err "template path did not fully resolve (a leading ~ or a \$VAR expand_path could not settle — e.g. a self-referential value): check --template / .report.template_path"
[ -f "$template" ] || usage_err "template not found: $template"

# --- resolve output directory (config → default), tolerate a trailing slash --
out_dir="$cli_output_dir"
[ -z "$out_dir" ] && out_dir="$(_cfg '.report.output_dir')"
[ -z "$out_dir" ] && out_dir="$DEFAULT_OUTPUT_DIR"
out_dir="$(expand_path "$out_dir")" || usage_err "output dir did not fully resolve (a leading ~ or a \$VAR expand_path could not settle — e.g. a variable whose value is itself unresolvable, or a self-referential value): check .report.output_dir"
# A path that expands to empty (e.g. .report.output_dir referencing an unset
# variable) would otherwise make out_path "/YNAB-…html" and write to the
# filesystem root — refuse it, the symmetric guard to the template's [ -f ] check.
[ -n "$out_dir" ] || usage_err "output dir resolved to empty after expansion — check .report.output_dir"
# Drop ALL trailing slashes (keeping a bare root "/") so the filename join never
# doubles them, even for a multi-slash input like "/path//".
while [ "$out_dir" != "/" ] && [ "${out_dir%/}" != "$out_dir" ]; do
  out_dir="${out_dir%/}"
done
# Refuse the filesystem root outright — a report belongs in a directory, never at
# "/YNAB-…html". (The write gates below fail safe on a permissioned "/", but the
# symmetric guard names the real problem instead of a cryptic mkdir/mv error.)
[ "$out_dir" != "/" ] || usage_err "output dir resolved to the filesystem root '/' — refusing to write there; check .report.output_dir"
# Make the resolved directory absolute so the emitted path is absolute for EVERY
# input (AC #7 — "prints that absolute path"), not just ~-rooted / absolute
# configs. A bare-relative .report.output_dir would otherwise print a path that
# silently points elsewhere once a caller `cd`s away from this CWD.
case "$out_dir" in
  /*) : ;;
  *)  out_dir="${PWD}/${out_dir}" ;;
esac

# --- build the output path: YNAB-{Tier}-Review-YYYY-MM-DD.html --------------
out_path="${out_dir}/YNAB-${tier}-Review-${date}.html"
# Refuse when the target path already exists as anything but a regular file. On
# BSD/macOS `mv file existing_dir` moves the file *into* the directory and exits
# 0, so without this guard the writer would print $out_path and exit 0 while no
# file exists there — the exact falsely-successful report the atomic write exists
# to prevent. A pre-existing regular file is fine: the mv replaces it in place.
if [ -e "$out_path" ] && [ ! -f "$out_path" ]; then
  err "refusing to write — output path exists and is not a regular file (a directory?): $out_path"
  exit 1
fi

# --- reject a MALFORMED template BEFORE deriving slots (fail loud, no write) --
# The single-pass fill loop below trusts every literal `<!-- SLOT:` opener to be
# closed by its OWN ` -->`. A malformed opener — unclosed (no ` -->` before EOL),
# or a name with characters outside [a-z0-9-] — is otherwise swallowed into a
# composite "name" that never resolves: the loop re-emits the span verbatim and,
# when the malformed opener precedes a real marker, silently drops that real slot
# — an exit-0 corrupt report, the one thing this writer must never produce. The
# required-slot grep below matches only WELL-FORMED markers, so a malformed one
# never even reaches the completeness gate. Guard it here: the count of raw
# `<!-- SLOT:` openers must equal the count of well-formed `<!-- SLOT:name -->`
# markers, or the template is malformed and we refuse loudly (exit 2, no file).
raw_slot_openers="$(grep -oE '<!-- SLOT:' "$template" | wc -l | tr -d '[:space:]')"
wellformed_slots="$(grep -oE '<!-- SLOT:[a-z0-9-]+ -->' "$template" | wc -l | tr -d '[:space:]')"
if [ "$raw_slot_openers" != "$wellformed_slots" ]; then
  usage_err "malformed <!-- SLOT: --> marker in template — every slot marker must match '<!-- SLOT:name -->' (name: lowercase letters, digits, hyphen): $template"
fi

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
    # Trim first: a whitespace-only value ("   ") is as empty as "" — treat it
    # as missing rather than let it render a silently-blank section.
    [ -z "$(trim "${slot_values[$idx]}")" ] && missing+=("$rs")
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

# Report missing AND unknown together: a typo'd --slot name shows up as BOTH a
# now-missing real slot and an unknown name, so surfacing only "missing" would
# hide the typo. Missing slots are the harder failure (the report would be
# incomplete) and set the exit code; unknown names are reported as the likely cause.
if [ "${#missing[@]}" -gt 0 ] || [ "${#unknown[@]}" -gt 0 ]; then
  if [ "${#missing[@]}" -gt 0 ]; then
    err "refusing to write a partial report — these required slots are missing or empty:"
    for (( i = 0; i < ${#missing[@]}; i++ )); do err "  • ${missing[$i]}"; done
  fi
  if [ "${#unknown[@]}" -gt 0 ]; then
    err "unknown slot name(s) not declared by the template (typo of a required slot?):"
    for (( i = 0; i < ${#unknown[@]}; i++ )); do err "  • ${unknown[$i]}"; done
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    err "supply each missing slot via --slot <name>=<html>, or --slot <name>='no findings' to leave it intentionally empty."
    exit 1
  fi
  exit 2
fi

# --- assemble: constant template + scalar slots + variable fragments --------
# Read the (already-validated) template. Gate the read: if the file vanished or
# became unreadable between the slot-grep above and now, `html` would be empty
# and we would silently write an empty report — the same "no partial reports"
# failure the write gates guard against, one step upstream.
if ! html="$(cat "$template")"; then
  err "could not read template: $template"
  exit 1
fi

# Scalar slots FIRST, before the block fragments are spliced in — for two reasons:
#   1. A fragment's own text may legitimately contain the literal `{{output_path}}`
#      / `{{tier}}` / `{{report_date}}` (e.g. a YNAB payee or memo). Substituting
#      the scalars first leaves that fragment text intact instead of a later
#      scalar pass silently overwriting it (and leaking the local save path).
#   2. Each scalar value is enum/regex-validated (tier/date) or HTML-escaped
#      (out_path), so no scalar substitution can introduce a `<!-- SLOT:name -->`
#      needle for the block pass below to mis-splice.
# Every scalar the writer injects is HTML-escaped — the writer OWNS escaping the
# values it places into the report (out_path is neither enum- nor regex-bounded).
# {{tier}} renders the friendly display form (`Quarterly-Tax` → `Quarterly Tax`,
# matching the review skill's promise); the hyphenated enum stays in the filename.
tier_display="$tier"
[ "$tier" = "Quarterly-Tax" ] && tier_display="Quarterly Tax"
html="${html//\{\{tier\}\}/$(html_escape "$tier_display")}"
html="${html//\{\{report_date\}\}/$(html_escape "$date")}"
html="${html//\{\{output_path\}\}/$(html_escape "$out_path")}"

# Block slots — filled in a SINGLE left-to-right pass over the template so a
# fragment's value is NEVER re-scanned. A per-slot global `${html//needle/value}`
# re-examines the cumulatively-grown string, so a fragment whose own text
# contains a *later* slot's marker (`<!-- SLOT:name -->`) would have that marker
# rewritten by the later pass — splicing one section's content into another. This
# is the block-vs-block twin of the scalar-first ordering above: the scalars are
# substituted before fragments for the same reason, but that never protected
# fragment-vs-fragment. Walking the template once and appending each resolved
# value into an accumulator that is never re-read leaves an embedded marker inside
# a fragment verbatim, so arbitrary HTML in a fragment value is genuinely safe.
assembled=""
rest="$html"
while :; do
  # Everything before the next block marker (or the whole tail if none remain).
  prefix="${rest%%<!-- SLOT:*}"
  if [ "$prefix" = "$rest" ]; then
    assembled="${assembled}${rest}"     # no marker left — emit the tail and stop
    break
  fi
  assembled="${assembled}${prefix}"     # verbatim template text up to the marker
  after_open="${rest#"$prefix"<!-- SLOT:}"
  n="${after_open%% -->*}"              # slot name = up to the first " -->"
  # Resolve this marker's value. Every lowercase name the template declares is a
  # required slot with a supplied value (the completeness check above guaranteed
  # it); a marker whose name is unrecognised is emitted verbatim, never dropped.
  if idx="$(slot_index "$n")"; then
    v="${slot_values[$idx]}"
    [ "$(trim "$v")" = "no findings" ] && v=""   # explicit-empty sentinel → empty section
    assembled="${assembled}${v}"
  else
    assembled="${assembled}<!-- SLOT:${n} -->"
  fi
  rest="${after_open#"$n" -->}"         # continue after THIS marker only
done
html="$assembled"

# --- write + emit the path --------------------------------------------------
# Gate every step: a helper whose contract is "no partial/empty reports" must
# never print a success path for a file it failed to create. Write to a temp
# file in the destination dir, then mv it into place — an atomic swap, so a
# failed same-day rerun (same tier+date → same path) can never destroy a prior
# good report, and a partially-written file is never observable at the final path.
mkdir -p "$out_dir" || { err "could not create output directory: $out_dir"; exit 1; }
tmp="$(mktemp "${out_dir}/.report-writer.XXXXXX")" || { err "could not create a temp file in: $out_dir"; exit 1; }
if ! printf '%s\n' "$html" > "$tmp"; then
  err "could not write report: $out_path"
  rm -f "$tmp"
  exit 1
fi
if ! mv "$tmp" "$out_path"; then
  err "could not move report into place: $out_path"
  rm -f "$tmp"
  exit 1
fi
printf '%s\n' "$out_path"
