---
description: Configure the workbench-ynab plugin — verify prerequisites, store the YNAB token in the Keychain, collect config interactively, write config.json, pre-approve the read-only YNAB tools, prove the vendored MCP boots and lists budgets, and deploy the proactive-monitor scheduled task from config. Idempotent — re-run after a plugin update.
---

The user has invoked `/workbench-ynab:setup`. Walk them through the one-time (or
re-run-after-update) configuration that makes the plugin zero-config-after-token.

This command is **fully idempotent** — re-running is safe at any time. It checks
each piece of state first and skips what is already in place: an existing
Keychain token is acknowledged (no re-prompt), existing `config.json` values
pre-fill the prompts, and already-approved tool entries are not duplicated.

## What setup produces

- **One Keychain entry** — the YNAB Personal Access Token, stored under service
  `ynab-mcp`, account `access-token`. The token lives **only** in the Keychain —
  never in `config.json`, never on disk, never in a log.
- **One config file** at
  `~/.claude/plugins/data/workbench-ynab-claude-workbench/config.json` — budget,
  business, tax profile, persona, and report settings. It lives in the
  plugin-data dir so it **survives plugin updates**.
- **Pre-approved read-only tools** in `~/.claude/settings.json` so routine YNAB
  *reads* run without a permission dialog. Write tools are **not** approved here
  (see Step 5).

## Constants

```text
Config dir:    $HOME/.claude/plugins/data/workbench-ynab-claude-workbench
Config file:   $CONFIG_DIR/config.json
Keychain:      service "ynab-mcp", account "access-token"
Tool SSoT:     ${CLAUDE_PLUGIN_ROOT}/skills/protocol/ynab-tools.md
Tool prefix:   mcp__plugin_workbench-ynab_ynab__   (NB: plugin-namespaced — the
               bare mcp__<key>__ form never resolves)
```

Resolve the dir once at the top of the run:

```bash
CONFIG_DIR="$HOME/.claude/plugins/data/workbench-ynab-claude-workbench"
CONFIG_FILE="$CONFIG_DIR/config.json"
```

## Step 1 — Verify prerequisites

### 1a. CLI tools (hard-stop on a miss)

Run a single Bash check for the host tools the rest of the command needs:

```bash
missing=()
for cmd in node jq security; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "❌ Missing prerequisites: ${missing[*]}"
  for m in "${missing[@]}"; do
    case "$m" in
      jq)       echo "   • jq — install with: brew install jq" ;;
      node)     echo "   • node — install via your preferred path (nvm, brew install node, …)" ;;
      security) echo "   • security — ships with macOS; this command is macOS-only" ;;
    esac
  done
  echo "   Install the missing tool(s) and re-run /workbench-ynab:setup."
  exit 1
fi
echo "✅ node, jq, security all present"
```

If anything is missing, **stop here** — do not run any further step.

### 1b. Scheduled-tasks MCP probe (report-only, never hard-stops)

Call `mcp__scheduled-tasks__list_scheduled_tasks` to confirm the scheduled-tasks
MCP is reachable. Step 7 deploys the proactive-monitor task through it, so this
is an early heads-up (and the source of the existing-task list Step 7 reuses),
not a gate:

- **Reachable** → set `SCHEDULING_AVAILABLE=true`, keep the returned task list
  for Step 7, and report `✅ scheduled-tasks MCP reachable`.
- **Unavailable / errors** → set `SCHEDULING_AVAILABLE=false` and report
  `⚠ scheduled-tasks MCP not reachable — the ynab-monitor task can't be deployed
  until it is, but setup continues.`

Either way, **continue to Step 2** — unavailability never stops setup.

## Step 2 — Store the YNAB token (check-first)

Check for an existing Keychain entry **before** prompting:

```bash
if security find-generic-password -s "ynab-mcp" -a "access-token" >/dev/null 2>&1; then
  echo "✅ YNAB token already in Keychain (ynab-mcp / access-token) — skipping prompt"
  TOKEN_PRESENT=1
else
  echo "⚠ No YNAB token in Keychain yet"
  TOKEN_PRESENT=0
fi
```

**If `TOKEN_PRESENT=1`**, leave it untouched and move on.

**If `TOKEN_PRESENT=0`**, ask the user in chat:

> "Paste your **YNAB Personal Access Token** (create one at
> <https://app.ynab.com/settings/developer>). I'll store it in the macOS
> Keychain under `ynab-mcp / access-token` — it never lands in any file."

Wait for the next user message, then store it (the value is passed as a
positional arg — **never** echoed, logged, or written to a file):

```bash
security add-generic-password -s "ynab-mcp" -a "access-token" -w "<paste-value>" -U
echo "✅ Stored in Keychain (ynab-mcp / access-token)"
```

`-U` updates the entry if it somehow already exists, so this is safe to re-run.
**Never** print the token back, and never place it in `config.json`.

## Step 3 — Collect config (interactive, pre-filled on re-run)

Read the existing config first so every prompt can default to the current value:

```bash
have_cfg=0
[ -f "$CONFIG_FILE" ] && have_cfg=1
# Read a field's current value (empty when absent/unset):
cfg() { [ "$have_cfg" = 1 ] && jq -r "$1 // empty" "$CONFIG_FILE" 2>/dev/null; }
```

Resolve the **persona default** through the shared loader so the prompt offers
the right name (explicit override → workbench-core agent name → `Hobbes`):

```bash
PERSONA_DEFAULT="$(bash "${CLAUDE_PLUGIN_ROOT}/bin/persona.sh" name)"
```

Walk the M1-6 schema fields (see `docs/config-schema.md`) with `AskUserQuestion`,
**pre-filling each default from `cfg '<path>'`** (or the documented default when
absent). Collect, in order:

| # | Field | Config path | Default on first run |
|---|---|---|---|
| 1 | Budget name | `.budget.name` | _(ask — required)_ |
| 2 | Business account(s) | `.business.accounts` | _(optional — empty skips the whole `business` block)_ |
| 3 | Business category group | `.business.category_group` | _(optional)_ |
| 4 | Business expense categories | `.business.expense_categories` | _(optional)_ |
| 5 | Filing status | `.tax_profile.filing_status` | `single` |
| 6 | Standard deduction | `.tax_profile.standard_deduction` | `0.0` _(public IRS figure — verify for the tax year)_ |
| 7 | Medical AGI threshold | `.tax_profile.medical_agi_threshold_pct` | `0.075` |
| 8 | SE tax rate | `.tax_profile.se_tax_rate` | `0.153` |
| 9 | Quarterly due dates | `.tax_profile.quarterly_due_dates` | `04-15, 06-15, 09-15, 01-15` |
| 10 | Schedules that apply | `.tax_profile.schedules` | `C, A, SE, 1` |
| 11 | Persona name | `.persona.name` | `$PERSONA_DEFAULT` (the default voice) |
| 12 | Report output directory | `.report.output_dir` | `~/Documents/Claude/Reports` |

Notes for the walk:

- The **tax-profile interiors** (Schedule C/A/SE/1 line data) are owned by the
  Sprint 2 tax engine; here you collect only the top-level `tax_profile` fields
  above. They are **public tax constants**, not personal income — this plugin is
  **not tax advice**; tell the user to verify them for the current tax year.
- `business` is **optional**: if the user has no side-business, leave the
  business prompts empty and **omit the whole `business` key** from the config.
- `persona.name` defaults to `$PERSONA_DEFAULT` — the assistant's default voice.
  Leaving it at the default keeps it speaking as the user's own agent / `Hobbes`.
- **Validate the collected persona name before it enters the config** (issue
  #28): run

  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/bin/persona.sh" validate-name -- "$COLLECTED_NAME"
  ```

  A non-zero exit means the name violates the contract (longer than 64
  characters, or contains control characters). **Fail loudly**: surface the
  loader's stderr message (it names the field and the violation) and re-ask for
  the name — never write a violating `persona.name` into `config.json`. An
  empty answer is fine (the loader falls back silently), and `--` guards
  against a name that itself looks like a flag.
- Use `schema_version: 1`.

When every field is gathered, **assemble the full JSON, show it to the user**,
and ask: **"Save this configuration? (yes/no)"**. Only proceed to Step 4 on yes.

## Step 4 — Write config.json (jq merge — preserve unknown keys)

Create the dir if needed, then **merge** the collected values over any existing
file so keys this command doesn't manage (e.g. `mapping_rules` hand-added by the
user, or fields added by a future schema) are preserved — never a blind
overwrite:

```bash
mkdir -p "$CONFIG_DIR"

# $NEW_JSON is the object Step 3 assembled (schema_version + budget + optional
# business + tax_profile + persona + report). Merge it over the existing file so
# unknown/hand-added keys survive. `*` deep-merges objects; the new values win.
#
# Every gate below fails CLOSED (issue #154): any failure removes the staged
# .tmp, leaves the real $CONFIG_FILE byte-for-byte untouched, prints a ❌, and
# exits non-zero so Steps 5–7 never run against a corrupted config. Without
# these gates a failed merge truncates the .tmp to 0 bytes, the token gate
# fails open on the unparseable file, and the empty .tmp is published over the
# user's config with a ✅ — data loss reported as success.
EXISTING='{}'
if [ -f "$CONFIG_FILE" ]; then
  EXISTING="$(cat "$CONFIG_FILE")"
  # Validate BEFORE merging: a malformed pre-existing config is detected here,
  # not inferred later from a failed merge — and it is never overwritten.
  if ! printf '%s\n' "$EXISTING" | jq -e . >/dev/null 2>&1; then
    echo "❌ Existing $CONFIG_FILE is not valid JSON — refusing to touch it. Fix or remove the file, then re-run /workbench-ynab:setup." >&2
    exit 1
  fi
fi

# Check the merge's exit code explicitly: on failure the > redirect has already
# truncated the .tmp, so drop it instead of letting it near the real path.
if ! printf '%s\n' "$EXISTING" \
  | jq --argjson new "$NEW_JSON" '. * $new' \
  > "$CONFIG_FILE.tmp"; then
  rm -f "$CONFIG_FILE.tmp"
  echo "❌ jq merge failed — $CONFIG_FILE left untouched." >&2
  exit 1
fi

# The staged file must be non-empty, valid JSON before it is eligible to
# publish. (`jq -e .` rejects an empty file; `jq empty` would wave it through.)
if ! jq -e . "$CONFIG_FILE.tmp" >/dev/null 2>&1; then
  rm -f "$CONFIG_FILE.tmp"
  echo "❌ Staged config is empty or invalid JSON — $CONFIG_FILE left untouched." >&2
  exit 1
fi

# Sanity: the token must NEVER be in config.json. Scan the STAGED file *before*
# publishing it, so a token-shaped value never reaches the real path. Aggregate
# every string test with `any` — `jq -e` keys its exit code off only the LAST
# streamed value, so a bare `getpath(paths) | strings | test(…)` silently misses
# a token anywhere but the final string position. The gate keys on jq's full
# exit code and fails CLOSED: 0 = token found, 1 = scan ran clean (the ONLY
# pass), anything else = jq could not scan the staged file, which counts as
# "cannot verify safety" — never as "no token found, safe to proceed". On
# anything but 1, drop the staged file and never `mv` it into place.
TOKEN_SCAN=0
jq -e '[getpath(paths) | strings | test("^[0-9a-f]{64}$")] | any' "$CONFIG_FILE.tmp" >/dev/null 2>&1 || TOKEN_SCAN=$?
if [ "$TOKEN_SCAN" -eq 0 ]; then
  rm -f "$CONFIG_FILE.tmp"
  echo "❌ Refusing to keep a token-shaped value in config.json — the token belongs in the Keychain only." >&2
  exit 1
elif [ "$TOKEN_SCAN" -ne 1 ]; then
  rm -f "$CONFIG_FILE.tmp"
  echo "❌ Could not verify the staged config is token-free (jq failed to scan it) — $CONFIG_FILE left untouched." >&2
  exit 1
fi
mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
echo "✅ Wrote $CONFIG_FILE"
jq . "$CONFIG_FILE"
```

> If the user **omitted** the `business` block in Step 3, build `$NEW_JSON`
> without a `business` key. To *remove* a previously-saved business block on a
> re-run, drop it explicitly with `del(.business)` after the merge.

## Step 5 — Pre-approve the read-only YNAB tools

By default Claude Code shows a permission dialog every time the agent calls a
YNAB tool that isn't pre-approved. For routine **reads** of the user's own
budget that's friction without security value, so offer to pre-approve them.

**Scope — read tools only.** Pre-approve **only** the read tools and **exclude
every write verb**. Do **not** add the whole `mcp__plugin_workbench-ynab_ynab__ynab_*`
family wildcard here — it would sweep in the ledger-mutating write tools. v1 does
ship gated write-back, but the human-approval gate for money-affecting batches is
enforced at the **skill/workflow layer** (the write-safety guardrail), not by
pre-approving the tools. The write tools are approved in **Sprint 4** behind that
guardrail. (Writes are ledger-only inside YNAB — categorize / allocate / dedup /
reconcile — never external money movement.)

> **Write pre-approval is a manual opt-in — setup never seeds a write verb.**
> Even in Sprint 4, this command only pre-approves reads. To silence the
> redundant per-call dialog on the gated write tools, follow the permission
> notes in [`docs/mcp-capability-map.md`](../docs/mcp-capability-map.md): they
> give the exact tight set (the four write tools by full name, `delete`
> deliberately withheld to keep its own confirmation path) and the
> `~/.claude/settings.json` snippet to add. Never blanket-approve the family
> wildcard, and never add the delete verb.

**Source the names from the SSoT, never inline them.** The concrete read-tool
names live in `${CLAUDE_PLUGIN_ROOT}/skills/protocol/ynab-tools.md` under
**## Read tools**; read them at runtime so a namespace change is a one-file edit:

```bash
TOOLS_FILE="${CLAUDE_PLUGIN_ROOT}/skills/protocol/ynab-tools.md"
# Lines under "## Read tools …" up to the next "## " heading that start with the
# plugin tool prefix — exactly the read-only tool names, no writes.
READ_TOOLS="$(awk '/^## Read tools/{f=1;next} /^## /{f=0} f' "$TOOLS_FILE" \
  | grep '^mcp__plugin_workbench-ynab_ynab__' || true)"
if [ -z "$READ_TOOLS" ]; then
  echo "⚠ Could not read the read-tool list from the SSoT — skipping pre-approval." >&2
fi
```

Offer the pre-approval (recommended **yes**) via `AskUserQuestion`:

```jsonc
AskUserQuestion({
  questions: [{
    question: "Auto-approve the read-only YNAB tools? (recommended — stops the permission dialog on routine budget reads; write tools are NOT included)",
    header: "Permissions",
    multiSelect: false,
    options: [
      { label: "Yes — auto-approve reads",
        description: "Adds the read-only YNAB tool names to ~/.claude/settings.json permissions.allow. Write tools stay gated (Sprint 4)." },
      { label: "No — keep prompting",
        description: "Each YNAB read continues to show the permission dialog." }
    ]
  }]
})
```

On **Yes**, add each read-tool name idempotently — re-running produces no
duplicates (mirrors the bujo-setup pre-approval snippet):

```bash
SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

while IFS= read -r tool; do
  [ -z "$tool" ] && continue
  jq --arg p "$tool" '
    .permissions //= {} |
    .permissions.allow //= [] |
    if .permissions.allow | index($p) then . else .permissions.allow += [$p] end
  ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
done <<< "$READ_TOOLS"
echo "✅ Read-only YNAB tools pre-approved (write tools remain gated until Sprint 4)"
```

On **No**, skip silently — the user can re-run setup later to enable it.

## Step 6 — Verify the MCP boots and lists budgets

With the token and config in place, prove the vendored MCP actually launches and
answers a **read-only** call. Use the budgets-list read tool — it is the first
entry under **## Read tools** in
`${CLAUDE_PLUGIN_ROOT}/skills/protocol/ynab-tools.md` (the `list_budgets`
operation, under the `mcp__plugin_workbench-ynab_ynab__` prefix). It is strictly
read-only — **no YNAB data is mutated during setup.**

1. **Resolve its concrete name** from the SSoT (the first read-tool line), and
   **load its schema if deferred**:
   `ToolSearch(query="select:<that concrete tool name>")`.
2. **Call it** with no arguments.
3. **Be patient with cold-start.** The vendored bundle + `node` spawn can lag on
   first launch, so retry with backoff — e.g. up to ~5 attempts at 2s, 4s, 8s,
   16s — before declaring failure (mirrors the boot-patience pattern in the
   bujo-orchestrator).

- **On success** → echo the returned **budget names** so the user sees it works:
  `✅ MCP reachable — budgets: <name>, <name>, …`.
- **On failure after the retries** → report it and point at the likely culprits:
  > "❌ The YNAB MCP didn't answer. Most likely the launcher
  > (`${CLAUDE_PLUGIN_ROOT}/bin/launcher.sh`) or the Keychain token
  > (`ynab-mcp / access-token`). Confirm the token is valid and re-run
  > /workbench-ynab:setup."

## Step 7 — Deploy the monitoring scheduled task (M6)

The proactive between-run monitor runs on its **own** recurring schedule,
distinct from the weekly review. This step deploys — or removes — the
`ynab-monitor` scheduled task straight from config, following the unified-task
pattern in `workbench-bujo` (one task, cadence from config). It is **idempotent**:
a re-run syncs an existing task instead of duplicating it.

**Gate:** only run this step when the scheduled-tasks MCP was reachable in
Step 1b (`SCHEDULING_AVAILABLE == true`). If it was not, skip the whole step —
say `⚠ Skipping ynab-monitor deployment (scheduled-tasks MCP not reachable) — re-run /workbench-ynab:setup once it is.` — and continue to Step 8.

1. **Read the monitor schedule from config** (cadence is config-driven — never
   hardcode the cron here). Apply the documented defaults when the block or a
   field is absent: `cron = "0 8 * * *"` (daily 08:00), `enabled = true`:

   ```bash
   MON_ENABLED="$(jq -r 'if .schedules.monitor.enabled == false then "false" else "true" end' "$CONFIG_FILE" 2>/dev/null)"
   MON_CRON="$(jq -r '.schedules.monitor.cron // "0 8 * * *"' "$CONFIG_FILE" 2>/dev/null)"
   ```

   The `enabled` gate must **not** use `jq`'s `//` operator: `//` is the
   *alternative* operator, falling through on `null` **and on `false`**, so
   `.schedules.monitor.enabled // true` collapses a literal `false` back to
   `true` and the disable branch (Step 7.4) becomes dead code. Comparing
   `== false` directly is what keeps that branch reachable, and it still
   defaults absent/null to enabled (`null == false` is `false` → `"true"`),
   mirroring the repo's own `rule.enabled !== false` idiom
   (`lib/tax/classifyTransaction.mjs`). Only a literal `false` disables.

2. **Resolve the task prompt** from the template at
   `${CLAUDE_PLUGIN_ROOT}/assets/prompt-templates/ynab-monitor.prompt.md` (read it
   at runtime — never inline the prompt so a template edit is a one-file change).
   If the file is somehow missing, fall back to this inline prompt:

   ```text
   Invoke /workbench-ynab:ynab-monitor — run one proactive between-run
   monitoring pass. Pause at the first interactive prompt if no user is present
   (never fabricate, never auto-complete), and exit silently when nothing changed.
   ```

3. **When `MON_ENABLED` is `true` — deploy or sync.** Look for an existing task
   with id `ynab-monitor` in the Step 1b task list:

   - **Not present** → call `mcp__scheduled-tasks__create_scheduled_task` with:
     - `taskId`: `ynab-monitor`
     - `description`: `YNAB proactive between-run monitoring poll`
     - `cronExpression`: `$MON_CRON`
     - `prompt`: the resolved template
   - **Already present** → call `mcp__scheduled-tasks__update_scheduled_task` for
     `taskId: ynab-monitor` to sync its `cronExpression` and `prompt`. Re-running
     setup never creates a duplicate — this is the idempotent path.

   Report `✅ ynab-monitor scheduled — cron "<MON_CRON>"`.

4. **When `MON_ENABLED` is `false` — remove or disable.** If a task with id
   `ynab-monitor` exists, call `mcp__scheduled-tasks__delete_scheduled_task` with
   `taskId: ynab-monitor` (or disable it if delete is unavailable) and report
   `✅ ynab-monitor task removed (schedules.monitor.enabled: false)`. If none
   exists, do nothing and report `✅ ynab-monitor not scheduled (schedules.monitor.enabled: false)` —
   never claim "removed" when nothing was deleted.

5. **Never touch the weekly review.** `ynab-monitor` is a **distinct** task id;
   this step never creates, updates, or deletes the `ynab-review` task (or any
   other task). Only `taskId: ynab-monitor` is ever passed to a mutating call
   here.

## Step 8 — Final summary

Print a clean summary block:

```text
═══════════════════════════════════════════
  workbench-ynab setup complete
═══════════════════════════════════════════

  Config file:     ~/.claude/plugins/data/workbench-ynab-claude-workbench/config.json
  Keychain:        ynab-mcp / access-token   ✅ confirmed
  Tools approved:  read-only YNAB tools (writes gated until Sprint 4)
  Budgets seen:    <name>, <name>, …
  Monitor task:    ynab-monitor — cron "<MON_CRON>"   (or "disabled" / "skipped")

  Re-run /workbench-ynab:setup any time — it is idempotent and the
  recommended step after a plugin update.
═══════════════════════════════════════════
```

Substitute the actual budget names from Step 6 (or note the MCP wasn't reachable
if Step 6 failed), and the monitor line from Step 7 (`cron "<MON_CRON>"` when
deployed, `disabled` when `schedules.monitor.enabled: false`, or `skipped` when
the scheduled-tasks MCP was unreachable).

## Notes — idempotency & boundaries

- **Idempotent throughout.** Every step checks state first: the token check
  (Step 2) skips the prompt when present, the config read (Step 3) pre-fills
  defaults, the config write (Step 4) merges rather than overwrites, the
  pre-approval (Step 5) de-dupes, and the monitor-task deploy (Step 7) syncs an
  existing `ynab-monitor` task via `update_scheduled_task` rather than creating a
  duplicate. Re-running after a plugin update is the intended refresh path.
- **Token vs. config split.** The Keychain holds the token; `config.json` holds
  budget / business / tax / persona / report settings. The vendored MCP receives
  only the token (via `bin/launcher.sh`) — it never reads `config.json`.
- **No YNAB writes.** The only YNAB MCP call setup makes is the budgets-list
  read in Step 6 — setup never moves money or mutates YNAB data. The other MCP
  it touches is the scheduled-tasks MCP in Step 7, and only to deploy/sync/remove
  the plugin's own `ynab-monitor` task; the `ynab-review` task is never touched.
- **macOS-only.** Token storage uses the macOS `security` Keychain CLI.
