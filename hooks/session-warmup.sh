#!/usr/bin/env bash
#
# session-warmup (workbench-ynab): inject YNAB routing guidance at session start
# so the agent knows the namespaced tools, the config/token split, and the
# read-only (M2) posture even outside an explicit `/workbench-ynab:ynab-review`.
# Three signals, most-urgent first, all on STDOUT (Claude Code injects stdout
# into the agent's context):
#
#   1. Version-drift warning — the desktop app can keep serving a stale plugin
#      bundle while the CLI plugin cache is already current
#      (anthropics/claude-code#45810). Fired only when the running bundle is
#      STRICTLY behind the newest cached version.
#   2. Setup-incomplete warning — a missing Keychain token and/or config.json,
#      pointing the user at `/workbench-ynab:setup`. Emitted only when something
#      is actually wrong.
#   3. Routing guidance — the standing reference block (tools, config split,
#      read-only posture, trigger vocabulary). Emitted EVERY session.
#
# Wired to SessionStart and PostCompact via hooks/hooks.json. STDOUT is the
# injected-context channel — the OPPOSITE of bin/launcher.sh, where STDOUT is the
# MCP's JSON-RPC channel. Do not confuse the two: this is a hook, never the MCP
# launcher. Any diagnostic output (there is none today) must go to STDERR; a
# stray STDOUT byte pollutes the injected context.
#
# Contract:
#   - Dependency-free: only POSIX tools plus `sed` and BSD `sort` (no jq, no
#     GNU-only flags — the hook PATH is narrow under Cowork) and `security` (a
#     macOS built-in, guarded so a host without it degrades gracefully).
#   - The Keychain token is checked for existence only; its value is never read
#     (note the absence of `-w`), printed, echoed, or logged under any branch.
#   - Every exit path returns 0. A warmup failure must NEVER abort a session.
#
# No MCP pre-warm: unlike bujo (which cheaply launches Apple Notes), the YNAB MCP
# is a stdio server that needs the Keychain token and would attempt a live YNAB
# API connection on start — there is no cheap, side-effect-free cold-start to
# warm here, so pre-warming is deliberately omitted.
#
# Reference: ~/Developer/workbench-bujo/hooks/session-warmup.sh — same header
# discipline (set -u, always exit 0, STDOUT = injected context, sed-not-jq) and
# the source of the version-drift helpers ported below.

set -u

# ---------------------------------------------------------------------------
# Version-drift warning. Best-effort and dependency-free: extract versions with
# sed (no jq — the hook PATH is narrow under Cowork), compare numerically with
# BSD `sort` (no GNU-only `-V`), and stay silent on any missing input. Fires
# only when the running bundle is STRICTLY behind the newest version in the CLI
# cache. A Cowork-only setup with no CLI cache has nothing to compare against,
# so the check no-ops there. Mirrors the workbench-bujo warmup, swapping
# workbench-bujo → workbench-ynab, with one deliberate divergence: the cache_dir
# guards HOME as ${HOME:-} (see _ynab_newest_cached_version) so an unset HOME
# degrades to a guaranteed-absent path and stays silent, instead of raising
# "HOME: unbound variable" on stderr under set -u — the same guard already applied
# to the config path below.
# ---------------------------------------------------------------------------

_ynab_plugin_version() {
  # Echo the "version" field from a plugin.json, or nothing.
  [ -f "$1" ] || return 1
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -n 1
}

_ynab_newest_cached_version() {
  # Echo the highest semver dir name under the CLI plugin cache, or nothing.
  # HOME is expanded as ${HOME:-} (like the config path below): under set -u a
  # bare $HOME with HOME unset raises "HOME: unbound variable" on stderr, and this
  # hook must emit nothing outside its STDOUT context block. With HOME unset the
  # path degrades to a guaranteed-absent dir → the `-d` test fails → silent.
  local cache_dir="${HOME:-}/.claude/plugins/cache/claude-workbench/workbench-ynab"
  [ -d "$cache_dir" ] || return 1
  # `ls | grep` is safe here: the entries are the CLI's own semver dir names and
  # the grep discards anything that is not a bare X.Y.Z, so no whitespace- or
  # newline-bearing name survives to be mis-split. Mirrors the bujo warmup.
  # shellcheck disable=SC2010
  ls -1 "$cache_dir" 2>/dev/null \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -n 1
}

_ynab_version_lt() {
  # True (0) iff $1 is strictly lower than $2 (both X.Y.Z).
  [ "$1" = "$2" ] && return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)" = "$1" ]
}

_ynab_emit_drift_warning() {
  local root="${CLAUDE_PLUGIN_ROOT:-}"
  [ -n "$root" ] || return 0
  local bundle newest
  bundle=$(_ynab_plugin_version "$root/.claude-plugin/plugin.json") || return 0
  [ -n "$bundle" ] || return 0
  newest=$(_ynab_newest_cached_version) || return 0
  [ -n "$newest" ] || return 0
  _ynab_version_lt "$bundle" "$newest" || return 0
  cat <<DRIFT
# ⚠️ workbench-ynab plugin version drift — running v${bundle}, v${newest} available

The active **workbench-ynab** bundle is **v${bundle}**, but **v${newest}** is installed in your CLI plugin cache. The desktop app may be serving a stale plugin (known issue — anthropics/claude-code#45810), which silently routes the YNAB MCP and skills to outdated code against your live budget.

**Realign:** run \`claude plugin marketplace update claude-workbench\` in a terminal, then fully quit (Cmd-Q) and relaunch the desktop app. This warning clears once the running bundle matches the cache.

---

DRIFT
}

_ynab_emit_drift_warning

# ---------------------------------------------------------------------------
# Setup-incomplete warning. Surface a missing Keychain token and/or config.json
# and point the user at `/workbench-ynab:setup`. Unlike the routing block below,
# this is emitted ONLY when something is wrong — a healthy session sees nothing
# here.
# ---------------------------------------------------------------------------

# Config path. Tracks bin/config.sh's YNAB_CONFIG_FILE test seam and default
# location, so the warmup and the loader agree on where configuration lives. One
# deliberate divergence: HOME is expanded as ${HOME:-} here. The loader may error
# loudly when its environment is broken, but this hook must NEVER abort a session
# — under `set -u` a bare $HOME with HOME unset would raise "HOME: unbound
# variable" and exit non-zero. With HOME unset the path degrades to a
# guaranteed-absent location, so the config simply reads as missing and the setup
# block is emitted — the safe, actionable outcome rather than a silent non-zero
# abort.
YNAB_CONFIG_FILE="${YNAB_CONFIG_FILE:-${HOME:-}/.claude/plugins/data/workbench-ynab-claude-workbench/config.json}"

# Token presence — existence check only. Note the absence of `-w`, so the token
# value is never resolved into this process; output is discarded and only the
# exit code is read. Guarded on `security` being present so a non-macOS host (no
# Keychain CLI) degrades gracefully instead of raising a false "token missing".
token_missing=0
if command -v security >/dev/null 2>&1; then
  security find-generic-password -s ynab-mcp -a access-token >/dev/null 2>&1 \
    || token_missing=1
fi

# Config presence.
config_missing=0
[ -f "$YNAB_CONFIG_FILE" ] || config_missing=1

if [ "$token_missing" -eq 1 ] || [ "$config_missing" -eq 1 ]; then
  printf '# ⚙️ workbench-ynab — setup incomplete\n\n'
  printf 'The **workbench-ynab** plugin is installed but not fully configured:\n\n'
  if [ "$token_missing" -eq 1 ]; then
    printf -- '- ❌ YNAB access token not found in the macOS Keychain.\n'
  fi
  if [ "$config_missing" -eq 1 ]; then
    # Backticks are literal markdown around the path — no expansion intended.
    # shellcheck disable=SC2016
    printf -- '- ❌ Config not found at `%s`.\n' "$YNAB_CONFIG_FILE"
  fi
  # Backticks are literal markdown around the command — no expansion intended.
  # shellcheck disable=SC2016
  printf '\nSuggest the user run **`/workbench-ynab:setup`** to finish configuring '
  printf 'the plugin. Until then, YNAB budget review and write-back are unavailable.\n\n'
  printf -- '---\n\n'
fi

# ---------------------------------------------------------------------------
# Routing guidance — the standing reference block. Emitted EVERY session, so it
# is kept lean (it costs tokens each time). A static heredoc: no expansion, no
# set -u pitfalls.
# ---------------------------------------------------------------------------
cat <<'EOF'
# 💰 workbench-ynab routing

The `workbench-ynab` plugin is active — tax-aware YNAB budget review. **Milestone 2 is READ-ONLY:** review, categorization *proposals*, and reports only — never call a write/mutation tool, never move money. Propose changes for the user to apply later.

**Tools are namespaced `mcp__plugin_workbench-ynab_ynab__*`** — NOT `mcp__ynab__*`. Never hard-code a tool name; resolve it from the `ynab-protocol` skill (`skills/protocol/ynab-tools.md`), the single source of truth.

**Config / token split:** the YNAB access token is read from the macOS Keychain by the launcher (`bin/launcher.sh`) and handed to the MCP as `YNAB_ACCESS_TOKEN` — the ONLY thing the MCP ever sees. All budget / tax / profile / persona configuration lives in `config.json` under the plugin data-dir and is read by the SKILLS (`bin/config.sh`); it is never passed to the MCP.

## Trigger vocabulary → route

| The user asks about… | Route to |
|---|---|
| their budget / a category / month-to-date spend | the YNAB review skills — read-only |
| a transaction / payee / a possible duplicate | the YNAB review skills — read-only |
| categorization / "how should X be categorized?" | the categorize proposal path — proposes only, never writes |
| taxes / estimated tax / a tax-category rollup | the estimated-tax review skill — read-only |
| "run my review" / a weekly, monthly, quarterly-tax, or annual review | `/workbench-ynab:ynab-review` — the one entry point |
EOF

exit 0
