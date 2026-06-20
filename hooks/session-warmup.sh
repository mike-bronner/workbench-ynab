#!/usr/bin/env bash
#
# session-warmup (workbench-ynab): surface an early, actionable signal when the
# YNAB plugin isn't fully configured — a missing Keychain token and/or a missing
# config.json — and point the user at `/workbench-ynab:setup`. Stays completely
# silent on a healthy, fully-configured session.
#
# Wired to SessionStart and PostCompact via hooks/hooks.json. The block below is
# emitted on STDOUT, which Claude Code injects into the agent's context. That is
# the OPPOSITE of bin/launcher.sh, where STDOUT is the MCP's JSON-RPC channel —
# do not confuse the two: this is a hook, never the MCP launcher.
#
# Contract:
#   - Dependency-light. The only non-POSIX tool is `security` (a macOS built-in),
#     and it is guarded so a host without it degrades gracefully. The script does
#     no JSON parsing, so it needs neither jq nor a sed fallback — config and
#     token are checked for EXISTENCE only.
#   - The Keychain token is checked for existence only; its value is never read
#     (note the absence of `-w`), printed, echoed, or logged under any branch.
#   - Every exit path returns 0. A warmup failure must NEVER abort a session.
#
# Reference: ~/Developer/workbench-bujo/hooks/session-warmup.sh — same header
# discipline (set -u, always exit 0, STDOUT = injected context, sed-not-jq).

set -u

# Config path. Mirrors bin/config.sh exactly, including the YNAB_CONFIG_FILE test
# seam, so the warmup and the loader agree on where configuration lives.
YNAB_CONFIG_FILE="${YNAB_CONFIG_FILE:-$HOME/.claude/plugins/data/workbench-ynab-claude-workbench/config.json}"

# TODO(version-drift, future milestone): mirror the workbench-bujo warmup's
# version-drift check — warn when the running plugin bundle is STRICTLY behind
# the newest version in the CLI plugin cache (the desktop app can serve a stale
# bundle — anthropics/claude-code#45810). bujo extracts versions with `sed` (no
# jq, the hook PATH is narrow under Cowork) and compares with BSD `sort`. Cheap
# to port; deferred here to keep v1 minimal. Ref:
# ~/Developer/workbench-bujo/hooks/session-warmup.sh (_bujo_emit_drift_warning).

# --- Token presence -------------------------------------------------------
# Existence check only — note the absence of `-w`, so the token value is never
# resolved into this process; output is discarded and only the exit code is read.
# Guarded on `security` being present so a non-macOS host (no Keychain CLI)
# degrades gracefully instead of raising a false "token missing" alarm.
token_missing=0
if command -v security >/dev/null 2>&1; then
  security find-generic-password -s ynab-mcp -a access-token >/dev/null 2>&1 \
    || token_missing=1
fi

# --- Config presence ------------------------------------------------------
config_missing=0
[ -f "$YNAB_CONFIG_FILE" ] || config_missing=1

# Fully configured and healthy → stay completely silent.
if [ "$token_missing" -eq 0 ] && [ "$config_missing" -eq 0 ]; then
  exit 0
fi

# --- Emit a short, actionable warmup block --------------------------------
# Only the lines that are actually wrong are surfaced, so the block stays terse.
printf '# ⚙️ workbench-ynab — setup incomplete\n\n'
printf 'The **workbench-ynab** plugin is installed but not fully configured:\n\n'
if [ "$token_missing" -eq 1 ]; then
  printf -- '- ❌ YNAB access token not found in the macOS Keychain.\n'
fi
if [ "$config_missing" -eq 1 ]; then
  printf -- '- ❌ Config not found at `%s`.\n' "$YNAB_CONFIG_FILE"
fi
printf '\nSuggest the user run **`/workbench-ynab:setup`** to finish configuring '
printf 'the plugin. Until then, YNAB budget review and write-back are unavailable.\n'

exit 0
