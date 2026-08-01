---
description: Retire the legacy hand-run YNAB setup — detect the old Claude Desktop connector and prototype scheduled tasks, migrate the token (post-rotation) and config into the plugin, and offer to remove the deprecated connector, tasks, and directories. Idempotent and order-enforced; safe to re-run.
---

The user has invoked `/workbench-ynab:ynab-migrate`. Walk them through retiring the
pre-plugin YNAB setup so the plugin becomes the single source of truth. Two legacy
surfaces are retired:

1. The **standalone Desktop `ynab` connector** in
   `~/Library/Application Support/Claude/claude_desktop_config.json` — an
   `mcpServers.ynab` entry running `npx -y @dizzlkheinz/ynab-mcpb@latest` with a
   **plaintext** `YNAB_ACCESS_TOKEN`. This is the source of the leak handled in
   issue #73.
2. The **prototype scheduled tasks** `ynab-financial-review` and
   `ynab-cleanup-remaining` (scheduled-tasks MCP store `~/.claude/scheduled-tasks/`)
   and their directories under `~/Documents/Claude/Scheduled/`.

This ceremony mirrors the legacy-cleanup pattern in `bujo-setup.md` Step 7: detect,
list exactly, confirm, then remove.

## Rules for this whole command

- **Idempotent.** Every step below is individually skippable. Run the command
  against a fully-migrated state and it makes **zero changes** — each step prints
  an "already done / nothing to do" line and moves on. Always detect-then-act;
  never act blind.
- **Order is enforced — do not reorder:**
  - **Keychain seeding (Step 3) is never offered before the user confirms the token
    has been rotated** (issue #73). The leaked token must be dead first.
  - **Legacy connector removal (Step 8) is never offered before plugin verification
    (Step 4) succeeds.** Never strip the user's working YNAB access until the
    vendored plugin is proven to work.
- **Never echo a token value** in any output, ever.
- **Never blind-overwrite a JSON file.** Use the provided `jq`/helper paths, which
  write to a temp file and validate before replacing the original.

The deterministic file mutations (Desktop-connector detect/remove, task-dir
detect/remove) are done by the tested helper `${CLAUDE_PLUGIN_ROOT}/bin/ynab-migrate.sh`
— call it rather than hand-rolling `jq`. The plaintext-token check is done by
`${CLAUDE_PLUGIN_ROOT}/bin/scrub-leaked-token.sh --detect`.

## Step 1 — Detect the legacy Desktop connector

```bash
bash "${CLAUDE_PLUGIN_ROOT}/bin/ynab-migrate.sh" detect-connector
```

- **Exit 0** → the legacy connector is present (`mcpServers.ynab` running
  `@dizzlkheinz/ynab-mcpb`). Continue with the connector steps (2, 3, 4, 8).
- **Exit 1** → no legacy connector. Tell the user "No legacy Desktop connector
  found — skipping connector migration," and **skip Steps 2, 3, 4, and 8**. Go
  straight to Step 5.
- **Exit 2** → the Desktop config exists but is unparseable. Stop the
  connector-related steps and tell the user to fix the JSON by hand (the helper
  fails closed here on purpose). Continue with Steps 5–7, which don't touch the
  Desktop config.

## Step 2 — Warn that the legacy token is compromised

A token that ever sat in the plaintext Desktop config is **permanently
compromised**. Check for one:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/bin/scrub-leaked-token.sh" --detect
```

- **Non-zero (plaintext token present)** → warn the user, clearly:
  > ⚠️ Your YNAB token is in plaintext in the Desktop config and is **compromised**.
  > You must **rotate** it before going further: revoke the old token and mint a new
  > one. See `docs/token-rotation.md` (issue #73). Then run
  > `${CLAUDE_PLUGIN_ROOT}/bin/scrub-leaked-token.sh` to scrub the on-disk copies.

  **Do NOT offer to copy the existing (leaked) token into the Keychain** — it is
  dead weight and re-storing a compromised secret is exactly the wrong move.
- **Zero (no plaintext token)** → say "No plaintext token in the Desktop config,"
  and continue.

## Step 3 — Seed the Keychain with the rotated token (post-rotation only)

**Order gate:** do this only after the user confirms rotation is complete. Ask:

```jsonc
AskUserQuestion({
  questions: [{
    question: "Have you already rotated the YNAB token (revoked the old one and minted a new one per docs/token-rotation.md)?",
    header: "Rotation",
    multiSelect: false,
    options: [
      { label: "Yes — rotated",  description: "I have a fresh token ready to store in the Keychain" },
      { label: "Not yet",        description: "Skip Keychain seeding for now — I'll rotate first" }
    ]
  }]
})
```

On **Not yet** → skip this step (and note that Step 8 connector removal will also
be held until the plugin is verified working). On **Yes — rotated**:

1. **Idempotency check** — skip if the Keychain entry already exists:

   ```bash
   if security find-generic-password -s "ynab-mcp" -a "access-token" >/dev/null 2>&1; then
     echo "Keychain entry already present (service ynab-mcp / account access-token) — already seeded."
   fi
   ```

   If it exists, print the "already seeded" line and move on.

2. Otherwise, **have the user seed the Keychain in their own terminal** — do NOT
   try to read the token here. The Bash this command runs in is **non-interactive**
   (no controlling TTY), so `read -rs` returns EOF immediately and would seed an
   *empty* entry (then Step 4 fails with no clue why); and passing the token as a
   `-w "$TOKEN"` argv value exposes it to any `ps`-watching process — the exact
   secret-in-the-clear hygiene this command exists to retire (#73). Instead, tell
   the user to run this in their own terminal and paste the **fresh** token at the
   hidden prompt:

   ```bash
   security add-generic-password -s "ynab-mcp" -a "access-token" -U -w
   ```

   The **bare trailing `-w`** (no value) makes `security` prompt for the password on
   its own controlled input — the token never touches argv, shell history, or this
   chat. Do NOT substitute a `-w "$TOKEN"` form, and never ask the user to paste the
   token into the conversation.

3. Once the user confirms they've run it, verify the entry exists — this only
   checks for presence and never prints the token:

   ```bash
   if security find-generic-password -s "ynab-mcp" -a "access-token" >/dev/null 2>&1; then
     echo "Keychain entry confirmed (service ynab-mcp / account access-token)."
   else
     echo "Keychain entry not found — the seed didn't take. Re-run the security command above in your terminal."
   fi
   ```

   `bin/launcher.sh` reads the token from this exact Keychain location at launch.

## Step 4 — Verify the vendored plugin works (gate for Step 8)

Before offering to remove the legacy connector, prove the vendored plugin can
actually reach YNAB. Call a plugin **read** tool:

- Call the `list_budgets` **read** tool, resolving its concrete namespaced name
  from `${CLAUDE_PLUGIN_ROOT}/skills/protocol/ynab-tools.md` (the #87 tool-name
  SSoT — never inline a concrete name here), or an equivalent read-only plugin
  tool.
- **Success** → record that the plugin is verified; Step 8 is now unlocked.
- **Failure** → abort the connector-removal path with a clear message: "The
  vendored plugin could not read YNAB (check the Keychain token from Step 3). Not
  removing the legacy connector until the plugin works." Still continue with
  Steps 5–7.

## Step 5 — Migrate the prototype config into the plugin

The prototype's context lives in
`~/Documents/Claude/Scheduled/ynab-financial-review/SKILL.md`. Migrate it into the
plugin's out-of-repo config so the user doesn't re-enter it.

1. If the SKILL.md is absent, say so and skip this step.
2. Read it and extract the equivalents of these `config.json` fields (see
   `docs/config-schema.md`): the budget name (which lands as the single entry of
   the schema-v2 `budgets` array), the side-business `business.name` /
   `business.accounts` / `business.category_group` / `business.expense_categories`,
   and the `tax_profile` (filing status, schedules, public rates/due dates).
3. **Idempotency** — read the existing config and only offer to fill fields that
   are **absent, null, empty, or still a `<PLACEHOLDER>`**. The budget counts as
   **already migrated** when the config holds a real budget in *either* shape — a
   `budgets` entry with a non-placeholder `budget_name`/`budget_id`, or a legacy
   v1 `budget.name` with a real value (the loader migrates that shape at read
   time; never write a `budgets` array next to it). If every target field
   already holds a real value, print "Config already migrated — nothing to write"
   and skip.

   ```bash
   CONFIG_DIR="$HOME/.claude/plugins/data/workbench-ynab-claude-workbench"
   CONFIG_FILE="$CONFIG_DIR/config.json"
   mkdir -p "$CONFIG_DIR"
   # Seed on first run via the tested helper: it copies the shipped example with
   # the placeholder `budgets` array, `default_budget`, and the example
   # `timezone` STRIPPED (so the real migrated values can land below —
   # migrate-config fills only blank fields, a placeholder budgets array is not
   # blank, and the example's concrete `America/Phoenix` would otherwise become
   # this user's silent baked-in zone, issue #31), writes temp→validate→mv, and
   # chmods the file 0600 (it holds budget/business/tax data). No-op when the
   # config already exists.
   bash "${CLAUDE_PLUGIN_ROOT}/bin/ynab-migrate.sh" seed-config "$CONFIG_FILE"
   ```

4. **Collect the timezone (issue #31).** The seed strips the example zone, so a
   migrated config carries none until you land it here — and the review loader
   (`bin/config.sh` `_cfg_timezone`) **fails closed** on a missing zone, so this
   step is required for reviews to run. Resolve the machine's zone as the
   **default to offer**, ask the user to confirm or change it, and **validate the
   value before it enters the config** — mirroring `commands/setup.md` Step 13.
   Never write an invalid or empty `.timezone`, and never fall back to
   "system local":

   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/bin/config.sh"   # for _is_valid_timezone
   SYS_TZ="$(readlink /etc/localtime 2>/dev/null | sed -n 's#.*/zoneinfo/##p')"
   [ -n "$SYS_TZ" ] && _is_valid_timezone "$SYS_TZ" || SYS_TZ="UTC"   # last-resort default
   # Offer $SYS_TZ as the default; the user may enter a different IANA zone.
   # Validate $COLLECTED_TZ and re-ask until it is a real IANA zone:
   _is_valid_timezone "$COLLECTED_TZ" || { echo "❌ '$COLLECTED_TZ' is not a valid IANA timezone (e.g. America/Phoenix, UTC)."; }
   ```

   Land the confirmed zone through the same blank-only helper as every other
   field (a config that already carries a real zone is left untouched):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/ynab-migrate.sh" migrate-config "$CONFIG_FILE" '["timezone"]' "$(jq -n --arg v "$COLLECTED_TZ" '$v')"
   ```

5. Show the user the exact fields you propose to write (their migrated values) and
   ask for confirmation. On **yes**, write each field through the tested helper —
   it fills a field **only** when the current value is absent, null, empty, or a
   `<PLACEHOLDER>`, and writes via a temp-file→validate→`mv`, so it can **never**
   blind-overwrite a value the user already set:

   ```bash
   # Each call takes the config file, the field as a JSON path array, and the
   # migrated value as a JSON literal. A field that already holds a real value is
   # left untouched and reported "already set".
   M="${CLAUDE_PLUGIN_ROOT}/bin/ynab-migrate.sh"
   # The migrated budget becomes the single schema-v2 `budgets` entry, mirroring
   # the loader's legacy synthesis (label = budget name, role = personal), plus
   # the matching `default_budget`. SKIP BOTH calls when Step 3 found the budget
   # already migrated in the legacy shape (real `.budget.name`) — writing
   # `budgets` next to a live legacy `budget` would leave a hybrid file.
   bash "$M" migrate-config "$CONFIG_FILE" '["budgets"]'        "$(jq -n --arg v "$BUDGET_NAME" '[{label: $v, role: "personal", budget_name: $v}]')"
   bash "$M" migrate-config "$CONFIG_FILE" '["default_budget"]' "$(jq -n --arg v "$BUDGET_NAME" '$v')"
   bash "$M" migrate-config "$CONFIG_FILE" '["business","name"]'            "$(jq -n --arg v "$BUSINESS_NAME" '$v')"
   bash "$M" migrate-config "$CONFIG_FILE" '["business","accounts"]'        "$BUSINESS_ACCOUNTS_JSON"      # a JSON array
   bash "$M" migrate-config "$CONFIG_FILE" '["business","category_group"]'  "$(jq -n --arg v "$CATEGORY_GROUP" '$v')"
   bash "$M" migrate-config "$CONFIG_FILE" '["business","expense_categories"]' "$EXPENSE_CATEGORIES_JSON"  # a JSON array
   bash "$M" migrate-config "$CONFIG_FILE" '["tax_profile"]'                "$TAX_PROFILE_JSON"            # a JSON object
   ```

   Build each VALUE as a JSON literal — `jq -n --arg v "$STR" '$v'` for a string, a
   `jq -n`-built array/object for the structured fields — so a value can never be
   misread as a jq program. Validate the final file against
   `${CLAUDE_PLUGIN_ROOT}/assets/config.schema.json` if a validator is available.

## Step 6 — Detect the prototype scheduled tasks and directories

1. List the scheduled tasks and check for the two prototype IDs:

   ```
   mcp__scheduled-tasks__list_scheduled_tasks
   ```

   Note whether `ynab-financial-review` and/or `ynab-cleanup-remaining` are
   present.

2. Detect the matching directories:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/ynab-migrate.sh" detect-task-dirs
   ```

If none of the tasks or directories exist, print "No prototype scheduled tasks or
directories found — already clean" and skip Step 7.

## Step 7 — Removal ceremony (explicit confirmation)

List **exactly** what will be removed — the task IDs found in Step 6 and the full
directory paths — then ask for one explicit confirmation:

```jsonc
AskUserQuestion({
  questions: [{
    question: "Remove these deprecated prototype items? <list the exact task IDs and full directory paths here>",
    header: "Remove",
    multiSelect: false,
    options: [
      { label: "Yes — remove them", description: "Delete the listed scheduled tasks and directories" },
      { label: "No — keep them",     description: "Make no changes" }
    ]
  }]
})
```

On **No** → make no changes. On **Yes**, for each item that actually exists:

1. Delete each present scheduled task:

   ```
   mcp__scheduled-tasks__delete_scheduled_task   # taskId: ynab-financial-review, then ynab-cleanup-remaining
   ```

2. Remove each present directory (the helper accepts only these two known names
   and is a no-op if already gone):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/ynab-migrate.sh" remove-task-dir ynab-financial-review
   bash "${CLAUDE_PLUGIN_ROOT}/bin/ynab-migrate.sh" remove-task-dir ynab-cleanup-remaining
   ```

## Step 8 — Remove the legacy Desktop connector

**Order gate:** run this step ONLY if Step 2's rotation was confirmed (Step 3) AND
Step 4 verified the plugin works. If either is unmet, skip and tell the user the
connector stays until rotation + verification are done.

Confirm with the user, then remove **only** the `mcpServers.ynab` block — every
other server is preserved, and the helper is a no-op if it's already gone:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/bin/ynab-migrate.sh" remove-connector
```

This uses `jq del(.mcpServers.ynab)` against a temp file, validated before
replacing the original — never a blind overwrite.

## Step 9 — Confirm

Summarize, per step, what happened — done now vs. already-done vs. skipped:

- Legacy connector: removed / already absent / left until rotation+verification.
- Token: rotation reminder shown? Keychain seeded / already seeded / skipped.
- Config: migrated fields written / already migrated / no prototype SKILL.md.
- Scheduled tasks + dirs: removed / already clean / kept by user choice.

Remind the user this command is safe to re-run — a second run will report
everything as already done.
