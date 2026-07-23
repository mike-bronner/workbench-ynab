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

Sourcing only **defines** functions (`_cfg`, `_require_config`, the timezone
helpers `_is_valid_timezone`, `_cfg_timezone`, `_today_in_tz`, and the
multi-budget helpers `_migrate_config`, `_cfg_budgets`, `_cfg_budget_field`,
`_cfg_default_budget`) and two path variables (`YNAB_CONFIG_FILE`, `TZ_DB_DIR`).
It never runs `set -e`/`set -u` or any command with side effects, so it cannot
abort or mutate the caller's shell.

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
persona_name="$(_cfg '.persona.name')"
```

`_cfg` **never bakes in a default** — that is how no owner-specific value can ever
be hardcoded in the loader. Callers apply their own defaults at the call site with
parameter expansion, exactly as `mcp-memory.sh` does:

```bash
output_dir="$(_cfg '.report.output_dir')"
output_dir="${output_dir:-$HOME/Documents/Claude/Reports}"   # caller's default
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

## The timezone helpers (issue #31)

`config.timezone` is the single source of truth for every date-sensitive
computation in a review (window, carryover, month/quarter boundaries, tax-year
label). Three helpers own reading, validating, and applying it — so no skill or
command computes a date from the host clock.

| Helper | Behaviour |
|---|---|
| `_is_valid_timezone TZ` | Pure predicate — returns 0 iff `TZ` is a syntactically-safe, existing IANA zone name. Prints nothing. **Fails closed**: rejects empty, an absolute path, a `..` traversal, a trailing slash, any character outside `[A-Za-z0-9_+/-]`, and any name with no matching file under `$TZ_DB_DIR` (default `/usr/share/zoneinfo`, honouring `$TZDIR`). Nested zones like `America/Argentina/Buenos_Aires` are accepted. |
| `_cfg_timezone` | The **load-time timezone gate**. Reads `.timezone`; echoes it on stdout when valid. On a **missing or invalid** value it prints a descriptive error to **stderr** and returns **non-zero** — it **never** falls back to the host clock. Resolve it as a hard stop: `tz="$(_cfg_timezone)" \|\| exit 1`. |
| `_today_in_tz TZ [EPOCH]` | Echoes today's ISO-8601 date (`YYYY-MM-DD`) in zone `TZ` — the single source of "today" for the review router and the four ad-hoc tier commands, so a scheduled run and an interactive run at the same instant agree on the window and tax-year label. `EPOCH` (Unix seconds; or the `$YNAB_NOW_EPOCH` env var) overrides "now" — the deterministic test seam, mirroring `lib/monitor/alerts.mjs`'s `options.now`. Portable across GNU (`date -d @…`) and BSD (`date -r …`). Assumes `TZ` is already validated. |

```bash
source "${CLAUDE_PLUGIN_ROOT}/bin/config.sh"
_require_config || exit 1
timezone="$(_cfg_timezone)" || exit 1        # required IANA tz — fail closed, never host clock
today="$(_today_in_tz "$timezone")"          # authoritative today in the configured tz
```

Because a review's window and tax-year label are timezone-sensitive, `_cfg_timezone`
is deliberately **stricter** than `_cfg`: `_cfg` is tolerant (empty on absence, so a
caller with its own default reads optional fields freely), but a missing timezone is
a hard stop — the review must not run in the wrong zone.

## The multi-budget helpers (schema v2, issue #84)

Skills resolve their target budget set through three helpers instead of reading
a singular budget path. All three apply the **legacy migration at read time**
(below), emit compact one-line JSON (or plain text for a single field), and
emit **nothing** when unconfigured — same tolerance as `_cfg`. No budget name
is ever hardcoded in the loader.

| Helper | Emits |
|---|---|
| `_cfg_budgets` | The full `budgets` array as JSON. |
| `_cfg_budget_field LABEL FIELD` | One field of the entry whose `label` equals `LABEL`. **Null-aware**, unlike `_cfg`'s `// empty` idiom: a boolean `false` (e.g. `write_back_enabled`) reads back as `false` instead of vanishing. **First-match**: labels are documented-unique, but should duplicates exist the first matching entry wins outright — one value always comes back, never one line per duplicate. |
| `_cfg_default_budget` | The entry whose `label` matches `default_budget`, or the **first** entry when `default_budget` is absent. A `default_budget` matching no label emits nothing — a typo surfaces as empty, never as a silently different budget. |

```bash
budgets_json="$(_cfg_budgets)"                                    # e.g. loop with: jq -c '.[]' <<<"$budgets_json"
biz_group="$(_cfg_budget_field 'Business' 'business_category_group')"
default_label="$(_cfg_default_budget | jq -r '.label')"
```

### Legacy migration: `_migrate_config`

`_migrate_config` echoes the **effective** config JSON: a schema-v1 file
(singular `budget`, no `budgets` key) gets a single-entry `budgets` array
synthesized from `budget.name`/`budget.id` (`label` = the budget name, `role` =
`personal`), so an existing config keeps working without manual editing. The
migration is **read-only** — the file is never rewritten and its
`schema_version` stays `1`; re-run `/workbench-ynab:setup` to upgrade the file
itself. A file that already has `budgets` passes through unchanged. See the
[migration note](config-schema.md#migrating-a-v1-config-singular-budget) in the
schema doc.

## Worked example — one read per top-level key

```bash
source "${CLAUDE_PLUGIN_ROOT}/bin/config.sh"
_require_config || exit 1

# schema_version (integer) — branch on it for forward migration
version="$(_cfg '.schema_version')"

# budgets (required) — resolve the target set, or the default entry
budget_count="$(_cfg_budgets | jq 'length')"
default_budget_id="$(_cfg_default_budget | jq -r '.budget_id // empty')"

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
report_dir="${report_dir:-$HOME/Documents/Claude/Reports}"
template="$(_cfg '.report.template_path')"   # empty → use the bundled template
```

Every `_cfg` call returns plain text on stdout, so it composes with normal shell
substitution. Use full `jq` path expressions (array indexing, `length`, `join`,
filters) — they are passed straight through to `jq`.

## Testing the loader

`tests/unit/config.test.sh` sources `bin/config.sh` against a sandbox config (via
the `YNAB_CONFIG_FILE` seam) and asserts: a present field reads back correctly, an
absent field returns empty, and the missing-config guard emits the expected error
text and a non-zero exit. `tests/unit/config-budgets.test.sh` covers the
multi-budget helpers the same way: two-budget isolation, per-label field reads
(including boolean-`false` readback), the read-time legacy migration (file
untouched, `schema_version` stays 1), and the `default_budget` fallback rules.
`tests/unit/timezone.test.sh` covers the timezone helpers: `_is_valid_timezone`
accept/reject cases, `_cfg_timezone`'s fail-closed behaviour on a missing or
invalid zone, and `_today_in_tz`'s boundary scenarios (near-midnight, month
boundary, and Dec 31 / Jan 1 tax-year) via the `$YNAB_NOW_EPOCH` seam. It follows the issue #4 harness convention — sources
`tests/lib/assert.sh`, organises the cases into `test_*` functions, and ends with
`run_tests` — so the repo-wide entrypoint auto-discovers it. Run the whole suite,
or just this file:

```bash
scripts/test.sh                            # the whole suite
scripts/test.sh tests/unit/config.test.sh  # just the config-loader tests
```
