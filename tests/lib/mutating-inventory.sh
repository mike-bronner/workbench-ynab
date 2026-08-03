#!/usr/bin/env bash
#
# tests/lib/mutating-inventory.sh — read the AUTHORITATIVE mutating-tool
# inventory (issue #257).
#
# `ALLOWED_TOOLS` ∪ `DENIED_TOOLS` in assets/write-safety-guardrail.js is the
# single source of truth for which YNAB verbs mutate. Several surfaces mirror
# that inventory — the read-only guard's `WRITE_VERBS` (#254), the user-facing
# safety doc's verdict table, the guardrail skill's bullet lists — and each
# mirror needs a test that DERIVES the expected verbs instead of hardcoding
# them, or a new verb silently escapes the mirror it was never added to.
#
# This file holds that derivation once, so the tests pinning those mirrors are
# not themselves a fresh set of independently-maintained copies. Source it:
#
#   source "$REPO_ROOT/tests/lib/mutating-inventory.sh"
#   mutating_inventory_verbs "$REPO_ROOT/assets/write-safety-guardrail.js" ALLOWED
#
# Extraction is awk, not sed: BSD sed (macOS, the primary dev platform) has no
# BRE alternation, so a `\(A\|B\)` range silently matches nothing there — the
# exact fail-open a guard's guard must not have.
#
# This file never holds a concrete tool name. It knows only the bare namespace
# prefix, which bin/check-tool-name-sources.sh deliberately never matches; the
# verb suffixes are read out of the inventory at runtime.

# The callable namespace prefix. Bare, so it is not a concrete tool name.
YNAB_TOOL_PREFIX='mcp__plugin_workbench-ynab_ynab__'

# mutating_inventory_verbs <guardrail-js> [ALLOWED|DENIED]
#
# Prints the inventory's verbs with the namespace prefix stripped, one bare verb
# per line, sorted and de-duplicated. With no block argument, prints the union
# (ALLOWED ∪ DENIED) — the full mutating-verb inventory.
#
# Scoped to the two array literals, so an unrelated tool name elsewhere in the
# file (a JSDoc example, say) can never masquerade as inventory.
#
# FAILS CLOSED — returns non-zero, printing nothing, when the file is
# unreadable, the block name is not one this function understands, or the
# extraction parses empty. A renamed or reformatted inventory must not read as
# "no mutating verbs", because every caller compares the result against a mirror
# and an empty expectation certifies nothing.
mutating_inventory_verbs() {
  local file="$1" want="${2-}" verbs
  [ -f "$file" ] || return 1
  case "$want" in
    '' | ALLOWED | DENIED) : ;;
    *) return 1 ;;
  esac
  verbs="$(awk -F"'" -v pre="$YNAB_TOOL_PREFIX" -v want="$want" '
    /^const (ALLOWED|DENIED)_TOOLS = Object\.freeze\(\[/ {
      in_block = (want == "" || index($0, "const " want "_TOOLS ") == 1)
      next
    }
    in_block && /^]\);/                        { in_block = 0; next }
    in_block && NF >= 2 && index($2, pre) == 1 { print substr($2, length(pre) + 1) }
  ' "$file" | sort -u)"
  [ -n "$verbs" ] || return 1
  printf '%s\n' "$verbs"
}
