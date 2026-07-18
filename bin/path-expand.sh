#!/usr/bin/env bash
#
# bin/path-expand.sh — the ONE shared config-path resolver for every helper that
# turns a user-configured directory (`.report.output_dir`, `.report.template_path`,
# …) into a fully-resolved absolute path (issue #65, GAP-21).
#
# WHAT THIS IS
#   A self-contained, sourceable path resolver. A config path is DATA, not code:
#   it may carry a leading `~` or `$VAR`/`${VAR}` references that must be expanded
#   WITHOUT eval (no command/arithmetic substitution is ever executed), and a
#   path that does not FULLY resolve must be refused rather than half-expanded.
#   Two consumers need exactly this: bin/report-writer.sh (where to WRITE reports)
#   and bin/ynab-prune.sh (where to PRUNE them). They previously diverged — the
#   writer resolved `$VAR` and mid-path `~`, prune handled only a leading `~` —
#   so a `$VAR` or symlinked output_dir made prune silently no-op while the writer
#   wrote there. Both now source THIS module so write and prune agree, byte for
#   byte, on where reports live (mirroring how bin/html-escape.sh unified the two
#   escapers that had drifted apart).
#
# WHY IT IS SOURCED, NOT EXECUTED
#   This file only DEFINES a function and one variable (and sets one shell option,
#   below). It runs no command with side effects at load time and never
#   `set -e`/`set -u`, so sourcing it cannot alter control flow or abort the
#   caller's shell.
#
# USAGE
#   . "${REPO_ROOT}/bin/path-expand.sh"
#   dir="$(expand_path "$raw")" || usage_err "path did not fully resolve"
#
# bash 3.2 compatible (macOS system bash): no associative arrays, no mapfile.

# bash 5.2 enables `patsub_replacement` by default, which makes a literal `&` in a
# `${var//pat/repl}` REPLACEMENT expand to the matched text (sed-style). The
# single-occurrence substitution below (`${p/"$match"/$value}`) intends the
# variable's VALUE to be inserted LITERALLY — a `$VAR` whose value contains `&`
# must not have that `&` rewritten to the matched `$VAR` token. Turn the option
# off here so the resolver behaves identically on bash 3.2 (macOS) through 5.2+
# (Linux CI), independent of whether the sourcing script already disabled it.
shopt -u patsub_replacement 2>/dev/null || true

# The shipped fallback report output directory — the ONE definition shared by
# bin/report-writer.sh (where to WRITE reports) and bin/ynab-prune.sh (where to
# PRUNE them), which both source this module. Single-sourcing the default VALUE
# here — not just the expand_path resolver — is what stops the two from drifting
# on where reports live: a copy-pasted literal in each script could be edited in
# one and not the other, so prune would scan a different dir than the writer
# wrote. Resolved eagerly via $HOME so it is already absolute. (Prototype default,
# SKILL.md line 143 — ~/Documents/Claude/Reports.)
# SC2034: this variable is consumed by the scripts that SOURCE this module
# (bin/report-writer.sh, bin/ynab-prune.sh), not within this file — that is the
# whole point of single-sourcing it here, so the "appears unused" heuristic is a
# false positive.
# shellcheck disable=SC2034
DEFAULT_OUTPUT_DIR="$HOME/Documents/Claude/Reports"

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
  # The guard caps iterations, and each pass resolves only the FIRST reference
  # (single-occurrence replace, not global — see below), so a self-referential
  # value grows only LINEARLY: it exhausts the cap in bounded time and is then
  # refused by the post-loop guard, rather than looping — or ballooning — forever.
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
      # Replace only the FIRST occurrence (single `/`, not global `//`). A global
      # replace lets a value that names itself TWICE (FOO='$FOO$FOO') DOUBLE the
      # occurrence count every pass — exponential growth that pegs CPU/memory and
      # hangs long before the iteration cap, never reaching the refuse-loudly guard.
      # One-at-a-time keeps a self-referential value LINEAR: it hits the cap and is
      # refused. Repeated legitimate references still fully resolve over more passes.
      p="${p/"$match"/$value}"
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
