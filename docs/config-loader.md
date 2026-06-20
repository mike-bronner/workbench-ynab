# `bin/config.sh` — the config loader contract

`bin/config.sh` is a **sourceable** bash helper that lets plugin skills and
commands read the user's [`config.json`](config-schema.md) without each one
reimplementing the same `jq` plumbing. It mirrors the `_cfg()` idiom from
`workbench-core/hooks/mcp-memory.sh` (lines 73–83).

## Who may source it

| Caller | Sources `bin/config.sh`? |
|---|---|
| Plugin **skills** and **slash-commands** | ✅ yes — this is what it is for. |
| `bin/launcher.sh` and the vendored YNAB MCP | ❌ **never.** |

> **Skills/commands only.** `bin/launcher.sh` deliberately does **not** read this
> config — it resolves only the Keychain token before `exec`-ing `node` on the
> vendored bundle. Keeping the MCP launch path config-free is an intentional
> architectural boundary. **Do not source `bin/config.sh` from the launcher.**

## Sourcing it

```bash
source "${CLAUDE_PLUGIN_ROOT}/bin/config.sh"
```

Sourcing only **defines** two functions (`_cfg`, `_require_config`) and one path
variable (`YNAB_CONFIG_FILE`). It never runs `set -e`/`set -u` or any command with
side effects, so it cannot abort or mutate the caller's shell.

## The config path

`YNAB_CONFIG_FILE` resolves to:

```
$HOME/.claude/plugins/data/workbench-ynab-claude-workbench/config.json
```

There is **no fallback to a user-specific path**. If the caller pre-sets
`YNAB_CONFIG_FILE` it is honoured unchanged — this is the seam the test harness
uses to point the loader at a sandbox fixture. In normal use it is left unset and
resolves to the canonical plugin-data path above.

## `_cfg '<jq-path>'`

Echoes the value at a `jq` path, or **nothing** when the file is missing, `jq` is
unavailable, or the field is absent/null. It is exactly `jq -r '<path> // empty'`,
guarded on file existence and `jq` availability — the same shape as
`mcp-memory.sh`.

```bash
budget_name="$(_cfg '.budget.name')"
```

`_cfg` **never bakes in a default** — that is how no owner-specific value can ever
be hardcoded in the loader. Callers apply their own defaults at the call site with
parameter expansion, exactly as `mcp-memory.sh` does:

```bash
output_dir="$(_cfg '.report.output_dir')"
output_dir="${output_dir:-$HOME/Documents/YNAB Reports}"   # caller's default
```

## Missing-config behaviour: `_require_config`

Call `_require_config` once, before reading any fields, in any skill/command that
**cannot proceed** without configuration. When the file is absent (or `jq` is
unavailable) it prints a clear, actionable message to **stderr** and returns a
**non-zero** exit code:

```text
workbench-ynab: config not found at <path>
workbench-ynab: run /workbench-ynab:setup to create it.
```

```bash
source "${CLAUDE_PLUGIN_ROOT}/bin/config.sh"
_require_config || exit 1     # fail fast, pointing the user at /workbench-ynab:setup
```

`_cfg` on its own is **tolerant** — it returns empty rather than erroring, so a
skill that has its own defaults can read optional fields without the guard. Use
`_require_config` when a missing config is a hard stop.

## Worked example — one read per top-level key

```bash
source "${CLAUDE_PLUGIN_ROOT}/bin/config.sh"
_require_config || exit 1

# schema_version (integer) — branch on it for forward migration
version="$(_cfg '.schema_version')"

# budget (required) — resolve by name, fall back to id
budget_name="$(_cfg '.budget.name')"
budget_id="$(_cfg '.budget.id')"

# business (optional) — read the first business account and the category group
business_name="$(_cfg '.business.name')"
business_account="$(_cfg '.business.accounts[0]')"
business_group="$(_cfg '.business.category_group')"

# tax_profile (required) — generic, data-driven tax parameters
filing_status="$(_cfg '.tax_profile.filing_status')"
se_rate="$(_cfg '.tax_profile.se_tax_rate')"
schedules="$(_cfg '.tax_profile.schedules | join(",")')"    # C,A,SE,1

# mapping_rules (optional) — count the rules, read the first rule's schedule
rule_count="$(_cfg '.mapping_rules | length')"
first_rule_schedule="$(_cfg '.mapping_rules[0].schedule')"

# persona (required) — caller supplies the shipped default name when unset
persona="$(_cfg '.persona.name')"
persona="${persona:-$DEFAULT_PERSONA}"

# report (required) — output dir with the caller's default
report_dir="$(_cfg '.report.output_dir')"
report_dir="${report_dir:-$HOME/Documents/YNAB Reports}"
template="$(_cfg '.report.template_path')"   # empty → use the bundled template
```

Every `_cfg` call returns plain text on stdout, so it composes with normal shell
substitution. Use full `jq` path expressions (array indexing, `length`, `join`,
filters) — they are passed straight through to `jq`.

## Testing the loader

`tests/unit/test-config.sh` sources `bin/config.sh` against a sandbox config (via
the `YNAB_CONFIG_FILE` seam) and asserts: a present field reads back correctly, an
absent field returns empty, and the missing-config guard emits the expected error
text and a non-zero exit. Run it directly:

```bash
tests/unit/test-config.sh
```

It also slots into the repo-wide test entrypoint established in issue #4
(`tests/unit/` + `scripts/test.sh`).
