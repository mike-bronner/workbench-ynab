#!/usr/bin/env bash
#
# session-warmup (workbench-ynab): the LIVE half of the plugin's session start.
# Two signals, most-urgent first, both on STDOUT (Claude Code injects stdout into
# the agent's context):
#
#   1. Version-drift warning — the desktop app can keep serving a stale plugin
#      bundle while the CLI plugin cache is already current
#      (anthropics/claude-code#45810). Fired only when the running bundle is
#      STRICTLY behind the newest cached version.
#   2. Setup-incomplete warning — a missing Keychain token and/or config.json,
#      pointing the user at `/workbench-ynab:setup`. Emitted only when something
#      is actually wrong.
#
# Both read live machine state, so both have to run per session. A healthy,
# fully-configured, up-to-date session sees NOTHING from this hook.
#
# The *static* half — the YNAB routing block (tool namespace, config/token split,
# read-only posture, trigger vocabulary) — is deliberately NOT emitted here. It
# lives in `session-warmup.md` at the plugin root, which workbench-core's own
# SessionStart hook aggregates with every other workbench-* plugin's contribution
# into one block baked into ~/.claude/CLAUDE.md. One shared, byte-stable block
# instead of one live `additionalContext` block per plugin keeps the prompt-cache
# prefix intact for scheduled tasks, and picks up fleet-wide fixes for free. See
# workbench-core's `docs/session-warmup-contributions.md`, which is also why the
# two warnings above stay HERE: they flip on upgrade and on setup state, and the
# aggregated block must be byte-identical across runs to stay cacheable.
#
# Wired to SessionStart and PostCompact via hooks/hooks.json. STDOUT is the
# injected-context channel — the OPPOSITE of bin/launcher.sh, where STDOUT is the
# MCP's JSON-RPC channel. Do not confuse the two: this is a hook, never the MCP
# launcher. Any diagnostic output (there is none today) must go to STDERR; a
# stray STDOUT byte pollutes the injected context.
#
# Contract:
#   - Silent under `--agent` sub-agent dispatch (see the CLAUDE_CODE_AGENT skip
#     guard below): no block is emitted, the script exits 0 immediately.
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
# Skip guard. Claude Code sets CLAUDE_CODE_AGENT on every `--agent` sub-agent
# dispatch (Watson, Holmes, Lestrade, and any future agent from any plugin).
# Neither block below is actionable in such a run: the drift warning and the setup
# pointer both ask a HUMAN to run a command. Injected into every dispatch they only
# burn tokens and break the agent's prompt-cache prefix. Interactive sessions — and
# the orchestrator runs that spawn those agents — carry no `--agent`, leave this
# unset, and are unaffected.
#
# First statement in the script on purpose: unlike the bujo warmup (which keeps a
# silent, idempotent Apple Notes pre-warm above its guard), this hook has no side
# effect worth running for a dispatched agent, so the cheapest correct behaviour
# is to do nothing at all. Ported from ~/Developer/workbench-bujo/hooks/session-warmup.sh
# per workbench-core/docs/session-warmup-contributions.md, which names a plugin
# hook missing this guard as a known fleet-wide defect.
# ---------------------------------------------------------------------------
if [ -n "${CLAUDE_CODE_AGENT:-}" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Version-drift warning. Best-effort and dependency-free: extract versions with
# sed (no jq — the hook PATH is narrow under Cowork), compare numerically with
# BSD `sort` (no GNU-only `-V`), and stay silent on any missing input. Fires
# only when the running bundle is STRICTLY behind the newest version in the CLI
# cache. A Cowork-only setup with no CLI cache has nothing to compare against,
# so the check no-ops there. Mirrors the workbench-bujo warmup, swapping
# workbench-bujo → workbench-ynab, with two deliberate divergences, both strict
# hardenings that keep every well-formed input behaving identically:
#   1. The cache_dir guards HOME as ${HOME:-} (see _ynab_newest_cached_version) so
#      an unset HOME degrades to a guaranteed-absent path and stays silent, instead
#      of raising "HOME: unbound variable" on stderr under set -u — the same guard
#      already applied to the config path below.
#   2. The extracted bundle version is validated against a strict X.Y.Z allowlist
#      (see _ynab_plugin_version), matching the allowlist the cache side already
#      applies, so a malformed version reads as a missing input instead of flowing
#      unvalidated into the agent-facing drift block.
# ---------------------------------------------------------------------------

_ynab_plugin_version() {
  # Echo the "version" field from a plugin.json, or nothing.
  #
  # The sed capture is deliberately permissive ([^"]*) because JSON says nothing
  # about the field's shape, so the extracted string is validated against the
  # SAME strict X.Y.Z allowlist the cache side already applies in
  # _ynab_newest_cached_version. Anything else echoes nothing, which the caller's
  # `[ -n "$bundle" ] || return 0` gate reads as "missing input" → silent, exit 0
  # (AC #4: silent on any missing input). Two reasons the allowlist is load-bearing:
  #   1. The value is interpolated verbatim into the drift heredoc, which is the
  #      injected-context channel for the agent. An unvalidated version string is
  #      therefore agent-facing text, and a crafted plugin.json could smuggle
  #      arbitrary markdown/instructions into context.
  #   2. _ynab_version_lt assumes both operands are X.Y.Z and mis-sorts garbage.
  # A deliberate divergence from the bujo reference (like the ${HOME:-} guard
  # below), and a strict tightening only: every well-formed version still passes.
  [ -f "$1" ] || return 1
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | head -n 1
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
# and point the user at `/workbench-ynab:setup`. Emitted ONLY when something is
# wrong — a healthy session sees nothing here.
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

# The routing block that used to live here now ships as `session-warmup.md` at
# the plugin root — see the header. Do not reintroduce it: emitting it here as
# well would inject it twice, once per channel, and reinstate the byte-volatility
# this hook was split to avoid. `tests/unit/session-warmup.test.sh` pins that.

exit 0
