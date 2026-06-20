# Persona & configuration

The financial assistant has a **default voice** that any user can name. By
default it speaks as **the Claude agent that runs the review** — your
`workbench-core` agent — and falls back to **Hobbes** when no agent is
configured. You can also give it a dedicated name via `persona.name`. This
mirrors how `workbench-core` ships a persona the user customizes
(`/workbench-core:install-persona`) and how `workbench-bujo` keeps tier-agnostic
voice rules in one reusable file rather than inline in every wrapper.

## The persona asset

The default voice lives at [`assets/persona/hobbes.md`](../assets/persona/hobbes.md):
warm, plain-spoken, action-oriented, no jargon-as-drama, leads with the finding.

It is the **default identity only** — it carries zero facts about any specific
user, budget, account, or tax situation. Owner details live in config and the
tax profile, never in the persona file. The file is kept short (≤ 60 lines) on
purpose: it is injected into context on every review run, so every line costs
tokens.

## Config: where it lives

Plugin configuration lives **outside this repo**, in the Claude Code plugin data
directory:

```
~/.claude/plugins/data/workbench-ynab-claude-workbench/config.json
```

This path is deliberately outside the cloned/installed plugin tree, so it
**survives plugin updates** — re-installing or upgrading `workbench-ynab` never
clobbers your settings. It is also never committed (it holds user-specific
preferences, and the YNAB token never goes here — that lives in the macOS
Keychain).

## Config: the `persona` object

`config.json` accepts a `persona` object:

```json
{
  "persona": {
    "name": "Hobbes",
    "voice_overrides": "Optional extra voice notes layered on top of hobbes.md."
  }
}
```

| Field | Type | Default | Meaning |
|---|---|---|---|
| `persona.name` | string | _(see precedence)_ | The assistant's name, substituted everywhere the report/dispatch refers to the assistant. When unset, the name falls back through the precedence below — `workbench-core` `agent_name`, then `"Hobbes"`. |
| `persona.voice_overrides` | string | _(none)_ | Optional voice tweaks layered on top of the default `hobbes.md`. |

Both fields are optional. With no `config.json` at all and no `workbench-core`
agent configured, the assistant is **Hobbes** with the default voice.

## Name resolution: precedence

The name is resolved by the shared loader in this order — the first non-empty
value wins:

1. **`persona.name`** in this plugin's `config.json` — an explicit override for
   anyone who wants the financial assistant to carry its own distinct name.
2. **`agent_name`** in the `workbench-core` config
   (`~/.claude/plugins/data/workbench-core-claude-workbench/config.json`, with
   the legacy `workbench-claude-workbench` path probed too) — *the default
   persona of the agent requesting the review.* The assistant speaks as your own
   Claude agent rather than an invented name. `workbench-core` is a declared
   prerequisite, so this is the common case.
3. **`"Hobbes"`** — the shipped standalone default for a public user who has
   neither config.

The `agent_name` read is consumed by the loader the same defensive way as the
`persona.name` read (file guard, `jq` guard, swallowed parse errors,
`// empty`), so a missing `workbench-core` config simply falls through to
`Hobbes` with no error.

## The loader contract

Skills, wrappers, and the report writer **must not** read the config inline or
hardcode `"Hobbes"`. They resolve the name through the single shared loader,
[`bin/persona.sh`](../bin/persona.sh), which is the one source of truth for the
substitution:

```bash
PERSONA_NAME="$(bash "${CLAUDE_PLUGIN_ROOT}/bin/persona.sh" name)"
```

Under the hood the loader follows the established `workbench-core` config-read
idiom (`hooks/mcp-memory.sh`): guard the file, guard `jq`, read with
`jq -r '<path> // empty'`, and walk the precedence in the shell:

```bash
YNAB_CONFIG="$HOME/.claude/plugins/data/workbench-ynab-claude-workbench/config.json"
CORE_CONFIG="$HOME/.claude/plugins/data/workbench-core-claude-workbench/config.json"
_cfg() {  # _cfg <file> <jq-path>
  [ -f "$1" ] && command -v jq >/dev/null 2>&1 \
    && jq -r "$2 // empty" "$1" 2>/dev/null
}
PERSONA_NAME="$(_cfg "$YNAB_CONFIG" '.persona.name')"          # 1. explicit override
[ -z "$PERSONA_NAME" ] && PERSONA_NAME="$(_cfg "$CORE_CONFIG" '.agent_name')"  # 2. requesting agent
PERSONA_NAME="${PERSONA_NAME:-Hobbes}"                         # 3. standalone default
```

The fallback is total at every tier — **when a config file is absent, `jq` is
missing, the JSON is malformed, or the field is absent/null, that tier collapses
to empty and the next one takes over, ending at `"Hobbes"` with no error.** (The
bare `jq -r '.persona.name // "Hobbes"'` only covers the missing-field case; it
errors on a missing file, so the file guard above is part of the contract.)

> Test overrides: `bin/persona.sh` honors `YNAB_CONFIG_FILE` and
> `WORKBENCH_CORE_CONFIG_FILE` to point at alternate config paths, and
> `YNAB_FOOTER_TEMPLATE` to point at an alternate footer template. These exist
> for the test harness — production callers never set them.

## Substitution points

The loaded name replaces the assistant's name everywhere it surfaces. **No
hardcoded `"Hobbes"` string appears in any skill or template file** — each
surface is rendered through the shared loader, which owns the one
`DEFAULT_PERSONA_NAME` constant:

- **Report footer** — `assets/templates/report-footer.html` is a frozen fragment
  with a `{{persona}}` token (and `{{generated_at}}`). The loader renders it:

  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/bin/persona.sh" footer "2026-06-19"
  #   -> <footer class="report-footer"><p>Generated by {persona} — 2026-06-19</p></footer>
  ```

- **Dispatch sign-off** — the review dispatch signs off with the loaded name:

  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/bin/persona.sh" signoff
  #   -> — {persona}, your financial assistant
  ```

Both renderers resolve the name through the same precedence above, so the
footer template and the sign-off carry **no literal name** — substitution is the
only path. The Sprint 3 review engine (M2-3) composes these surfaces into the
full HTML report and dispatch; it calls these subcommands rather than
re-implementing the substitution.

## Boundary: SKILL-only, never the MCP

`persona.name` is consumed by the **SKILL only**. It is **never** forwarded to
the vendored third-party YNAB MCP server. That MCP cannot read this plugin's
config, and it only ever receives the YNAB token plus its package-native
environment — nothing about the persona. The persona shapes how *the skill*
writes the report and dispatch; it has no bearing on the data calls.

## Verification

Automated check (self-contained, no framework required):

```bash
bash tests/persona-loader.test.sh
```

It asserts the full precedence and both renderers: (a) a custom `persona.name`
is picked up, (b) `workbench-core` `agent_name` is used when `persona.name` is
unset, (c) `persona.name` wins over `agent_name`, (d) absent/missing/null/
malformed configs fall back to `"Hobbes"`, and (e) the footer and sign-off
substitute the resolved name with no leftover token and no hardcoded `"Hobbes"`.
The tests pin both config paths via the override env vars, so they are hermetic
— they never read the host's real plugin config.

Manual spot-check:

```bash
# Explicit override picked up (tier 1):
echo '{"persona":{"name":"Calvin"}}' > /tmp/ynab-cfg.json
YNAB_CONFIG_FILE=/tmp/ynab-cfg.json WORKBENCH_CORE_CONFIG_FILE=/tmp/none bash bin/persona.sh name   # -> Calvin

# Requesting agent's name (tier 2):
echo '{"agent_name":"Holmes"}' > /tmp/core-cfg.json
YNAB_CONFIG_FILE=/tmp/none WORKBENCH_CORE_CONFIG_FILE=/tmp/core-cfg.json bash bin/persona.sh name   # -> Holmes

# Standalone fallback (tier 3):
YNAB_CONFIG_FILE=/tmp/none WORKBENCH_CORE_CONFIG_FILE=/tmp/none bash bin/persona.sh name   # -> Hobbes

# Rendered surfaces:
YNAB_CONFIG_FILE=/tmp/ynab-cfg.json bash bin/persona.sh footer 2026-06-19   # footer with "Generated by Calvin — 2026-06-19"
YNAB_CONFIG_FILE=/tmp/ynab-cfg.json bash bin/persona.sh signoff             # "— Calvin, your financial assistant"
```
