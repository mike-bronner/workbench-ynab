#!/usr/bin/env bash
#
# bin/config.sh — sourceable config loader for workbench-ynab SKILLS and commands.
#
# WHAT THIS IS
#   A shared helper that reads the user's out-of-repo configuration so the config
#   shape is defined once and not re-invented per skill. It mirrors the `_cfg()`
#   jq idiom from workbench-core/hooks/mcp-memory.sh (lines 73-83).
#
# WHO SOURCES THIS
#   Plugin SKILLS and slash-commands that need user configuration (budget name,
#   tax profile, persona, report paths, mapping rules, …).
#
# WHO MUST NOT SOURCE THIS
#   bin/launcher.sh and the vendored YNAB MCP deliberately do NOT read this
#   config — the launcher resolves only the Keychain token before exec'ing node.
#   Keeping the MCP launch path config-free is intentional; do not source this
#   file from the launcher. See docs/config-loader.md.
#
# WHY IT IS SOURCED, NOT EXECUTED
#   This file only DEFINES functions and one path variable. It never runs
#   `set -e`/`set -u` or any command with side effects at load time, so sourcing
#   it cannot alter or abort the caller's shell.
#
# USAGE
#   source "${CLAUDE_PLUGIN_ROOT}/bin/config.sh"
#   _require_config || exit 1                 # fail fast if unconfigured
#   budgets="$(_cfg_budgets)"                 # full budgets array as JSON
#   group="$(_cfg_budget_field 'Business' 'business_category_group')"
#   default_entry="$(_cfg_default_budget)"    # one budgets entry as JSON
#   persona="$(_cfg '.persona.name')"
#   persona="${persona:-$DEFAULT_PERSONA}"    # caller applies its own default
#
# See docs/config-loader.md for the full contract and a worked example per key.

# Resolve the config path. The plugin-data dir survives plugin updates, so it is
# the single source of truth for configuration. There is NO fallback to a
# user-specific path: if the file is absent the user must run /workbench-ynab:setup.
#
# YNAB_CONFIG_FILE may be pre-set by the caller (used by the test harness to point
# at a sandbox fixture); when unset it resolves to the canonical plugin-data path.
YNAB_CONFIG_FILE="${YNAB_CONFIG_FILE:-$HOME/.claude/plugins/data/workbench-ynab-claude-workbench/config.json}"

# _cfg '<jq-path>'
#   Echo the value at the given jq path, or nothing when the file is missing, jq
#   is unavailable, or the field is absent/null. Same shape as mcp-memory.sh:
#   `jq -r '<path> // empty'`. Callers apply their own defaults at the call site
#   with `"${value:-default}"` — this function never bakes defaults in, so no
#   owner-specific value is ever hardcoded here.
_cfg() {
  [ -f "$YNAB_CONFIG_FILE" ] && command -v jq >/dev/null 2>&1 \
    && jq -r "$1 // empty" "$YNAB_CONFIG_FILE" 2>/dev/null
}

# _require_config
#   Guard for callers that cannot proceed without configuration. Emits a clear,
#   actionable message to stderr and returns non-zero when the config file is
#   missing or jq is unavailable. Call it once before reading any fields.
_require_config() {
  if [ ! -f "$YNAB_CONFIG_FILE" ]; then
    echo "workbench-ynab: config not found at $YNAB_CONFIG_FILE" 1>&2
    echo "workbench-ynab: run /workbench-ynab:setup to create it." 1>&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "workbench-ynab: jq is required to read the config but was not found on PATH." 1>&2
    echo "workbench-ynab: install jq (e.g. 'brew install jq'), then re-run /workbench-ynab:setup." 1>&2
    return 1
  fi
  return 0
}

# _migrate_config
#   Echo the EFFECTIVE config JSON: the file's content with the legacy→multi
#   budget migration applied in memory. A schema-v1 file (singular `budget`, no
#   `budgets` key) gets a single-entry `budgets` array synthesized from
#   `budget.name`/`budget.id` — label = the budget name, role = `personal` (the
#   v1 shape modeled one personal budget; its side-business lived in the
#   `business` block, not a separate budget). A file that already has `budgets`
#   passes through unchanged.
#
#   READ-ONLY: the config file is never rewritten, so a legacy file's
#   schema_version stays 1 — the migration never auto-bumps it; the user
#   re-runs /workbench-ynab:setup to upgrade the file itself. Emits nothing
#   when the file is missing or jq is unavailable, same as _cfg.
_migrate_config() {
  [ -f "$YNAB_CONFIG_FILE" ] && command -v jq >/dev/null 2>&1 \
    && jq 'if has("budgets") then .
           else . + { budgets: [
             { label: (.budget.name // "default"), role: "personal" }
             + (if .budget.name != null then { budget_name: .budget.name } else {} end)
             + (if .budget.id   != null then { budget_id:   .budget.id   } else {} end)
           ] } end' "$YNAB_CONFIG_FILE" 2>/dev/null
}

# _cfg_budgets
#   Echo the full `budgets` array as compact JSON (one line), after the legacy
#   migration — a v1 file yields its synthesized single-entry array. Emits
#   nothing when unconfigured. No budget name is hardcoded here or in any
#   helper below: every value comes from the user's config instance.
_cfg_budgets() {
  _migrate_config | jq -c '.budgets // empty' 2>/dev/null
}

# _cfg_budget_field LABEL FIELD
#   Echo one field of the budgets entry whose `label` equals LABEL, or nothing
#   when the entry or field is absent. Unlike _cfg's `// empty` idiom this is
#   null-aware, so a boolean `false` (e.g. write_back_enabled) reads back as
#   the string "false" instead of vanishing. Labels are documented-unique;
#   should a config carry duplicates anyway, the FIRST matching entry wins
#   outright — one value always comes back, never one line per duplicate —
#   mirroring _cfg_default_budget's `.[0]` collapse below.
_cfg_budget_field() {
  _migrate_config | jq -r --arg label "$1" --arg field "$2" \
    'first(.budgets[]? | select(.label == $label)) | .[$field] | if . == null then empty else . end' 2>/dev/null
}

# _cfg_default_budget
#   Echo the budgets entry (compact JSON, one line) selected as the default:
#   the entry whose `label` matches the top-level `default_budget` key, or the
#   FIRST entry when `default_budget` is absent. A `default_budget` that
#   matches no entry emits nothing — a config typo surfaces as empty for the
#   caller to guard, never as a silently different budget.
_cfg_default_budget() {
  _migrate_config | jq -c '.default_budget as $d
    | (.budgets // [])
    | if $d == null then (.[0] // empty)
      else (map(select(.label == $d)) | .[0] // empty) end' 2>/dev/null
}
