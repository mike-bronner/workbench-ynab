---
description: Tear down every piece of system state /workbench-ynab:setup created — the scheduled tasks, the Keychain token, the settings.json pre-approvals, and (only if you say so) the plaintext data directory. Idempotent — safe to re-run after a partial teardown.
---

The user has invoked `/workbench-ynab:uninstall`. Remove the residual system
state this plugin created, in the reverse order setup built it.

This command is the mirror of [`setup.md`](setup.md). Setup creates four things
outside the plugin directory, and removing the plugin removes none of them:

| Setup created | Where it lives | This command |
|---|---|---|
| Scheduled tasks `ynab-review`, `ynab-monitor` | scheduled-tasks MCP | Step 2 — deletes both |
| Keychain token | service `ynab-mcp`, account `access-token` | Step 3 — deletes it |
| Pre-approved tool entries | `~/.claude/settings.json` → `permissions.allow` | Step 4 — removes only ours |
| Data directory | `~/.claude/plugins/data/workbench-ynab-claude-workbench/` | Step 5 — **asks first, keeps by default** |

**Every step is independently idempotent.** Each one checks state first and
reports `already clean` for anything that is gone, so a re-run after a partial
teardown never errors. No step aborts the run because an earlier component was
missing.

**This command never touches YNAB.** It makes no YNAB MCP call and moves no
money. It also cannot revoke your token server-side — that is a manual web-UI
step (Step 6).

## Constants

```bash
DATA_DIR="$HOME/.claude/plugins/data/workbench-ynab-claude-workbench"
SETTINGS="$HOME/.claude/settings.json"
KEYCHAIN_SERVICE="ynab-mcp"
KEYCHAIN_ACCOUNT="access-token"
TOOL_PREFIX="mcp__plugin_workbench-ynab_ynab__"
```

`TOOL_PREFIX` is the plugin-namespaced prefix every tool entry setup wrote
carries — the read globs, the explicitly-named reads, and any write tool added
by hand from `docs/mcp-capability-map.md`. Matching on the prefix is what makes
Step 4 remove all of them and nothing else.

## Step 1 — Inventory before you remove

Report what is actually present, so the user sees the blast radius before any
removal. Nothing is deleted in this step.

```bash
echo "workbench-ynab teardown — what is present:"
security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1 \
  && echo "  • Keychain entry $KEYCHAIN_SERVICE / $KEYCHAIN_ACCOUNT" \
  || echo "  • Keychain entry — absent"
if [ -f "$SETTINGS" ] && jq -e . "$SETTINGS" >/dev/null 2>&1; then
  echo "  • settings.json pre-approvals: $(jq -r --arg p "$TOOL_PREFIX" \
    '[.permissions.allow // [] | .[] | select(type == "string" and startswith($p))] | length' "$SETTINGS")"
else
  echo "  • settings.json pre-approvals — no readable $SETTINGS"
fi
[ -d "$DATA_DIR" ] \
  && echo "  • Data directory $DATA_DIR ($(find "$DATA_DIR" -type f | wc -l | tr -d ' ') files)" \
  || echo "  • Data directory — absent"
```

Then list the scheduled tasks (Step 2 reuses this list):

```
mcp__scheduled-tasks__list_scheduled_tasks
```

If that MCP is unreachable, say
`⚠ scheduled-tasks MCP not reachable — the ynab-review / ynab-monitor tasks can't be removed here; see the manual checklist in docs/uninstall.md.`
and **continue** to Step 3. An unreachable MCP never stops the rest of the
teardown.

## Step 2 — Remove the scheduled tasks

Setup deploys exactly two task ids: `ynab-review` (Step 8) and `ynab-monitor`
(Step 7). Remove each **that the Step 1 list actually contains**:

```
mcp__scheduled-tasks__delete_scheduled_task   # taskId: ynab-review
mcp__scheduled-tasks__delete_scheduled_task   # taskId: ynab-monitor
```

- **Present** → delete it and report `✅ scheduled task <id> removed`.
- **Absent** → report `✅ no scheduled task <id> found — skipping` and continue.
  Never call delete for a task that is not in the list, and never claim
  "removed" when nothing was deleted.
- **Neither present** → report `✅ no scheduled tasks found — skipping`.

**Only these two ids.** The deprecated prototype tasks
(`ynab-financial-review`, `ynab-cleanup-remaining`) belong to
`/workbench-ynab:ynab-migrate`; this command never passes any other task id to a
delete call.

## Step 3 — Remove the Keychain entry

Check first, then delete — the same check-first shape setup Step 2 uses. The
four branches are distinct on purpose: a delete that **fails while the entry is
still there** is reported loudly as a remaining manual step, never swallowed as
"already clean".

```bash
if ! command -v security >/dev/null 2>&1; then
  KEYCHAIN_RESULT="manual"
  echo "⚠ security CLI not on PATH — cannot reach the Keychain. Remove $KEYCHAIN_SERVICE / $KEYCHAIN_ACCOUNT by hand (Keychain Access.app)." >&2
elif ! security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1; then
  KEYCHAIN_RESULT="skipped"
  echo "✅ Keychain entry not found — skipping (already clean)"
elif security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1; then
  KEYCHAIN_RESULT="removed"
  echo "✅ Keychain entry removed ($KEYCHAIN_SERVICE / $KEYCHAIN_ACCOUNT)"
else
  KEYCHAIN_RESULT="manual"
  echo "❌ Keychain entry $KEYCHAIN_SERVICE / $KEYCHAIN_ACCOUNT exists but could not be deleted (locked keychain?). Remove it by hand — the token is still stored." >&2
fi
```

Deleting the entry stops **this machine** from using the token. It does **not**
revoke the token at YNAB — see Step 6.

## Step 4 — Remove the pre-approval entries from settings.json

Setup Step 5 appends the read-tool names to `permissions.allow`. Remove every
entry carrying `$TOOL_PREFIX` and leave every other entry — and every other key
in the file — byte-for-byte alone.

The filter is surgical in both directions: `map(select(...))` rewrites only the
`permissions.allow` array, and the `type == "string"` test means a non-string
element is preserved rather than crashing the filter. Every gate fails **closed**
— a file that cannot be parsed, rewritten, or re-moded is left untouched and
reported, never overwritten.

The rewrite also preserves the file's **permission mode** (issue #280). `mv` on
one filesystem is a `rename(2)`: it replaces the destination inode outright, so
the published file carries the *staged* file's mode. Staging under the ambient
umask would silently reset a settings.json the user hardened to `600` back to
the umask default (commonly `644`, world-readable). So the mode is captured
before staging and re-applied to the `.tmp` before the swap, and the `.tmp`
itself is born owner-only so the pending rewrite never sits world-readable. The
capture dereferences symlinks (`stat -L`): a settings.json symlinked into a
dotfiles repo would otherwise report the *link's* mode (`755` on macOS, `777` on
Linux) and publish that over the hardened target.

```bash
SETTINGS_RESULT="skipped"
if [ ! -f "$SETTINGS" ]; then
  echo "✅ No $SETTINGS — glob not present, skipping"
elif ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
  SETTINGS_RESULT="manual"
  echo "❌ $SETTINGS is not valid JSON — refusing to touch it. Remove the $TOOL_PREFIX entries from permissions.allow by hand." >&2
else
  MATCHED="$(jq -r --arg p "$TOOL_PREFIX" \
    '[.permissions.allow // [] | .[] | select(type == "string" and startswith($p))] | length' "$SETTINGS")"
  # GNU `stat -c '%a'` is probed FIRST: on GNU, `stat -f` means "filesystem
  # status" and prints something unrelated instead of erroring. BSD/macOS
  # `stat -f '%Lp'` is the fallback. `-L` (accepted by both dialects) follows the
  # symlink: without it the read returns the LINK's own mode (0755 on macOS, a
  # fixed 0777 on GNU), which the `chmod` below would publish over a target the
  # user hardened — settings.json symlinked into a dotfiles repo is common.
  SETTINGS_MODE="$(stat -L -c '%a' "$SETTINGS" 2>/dev/null || stat -L -f '%Lp' "$SETTINGS" 2>/dev/null || true)"
  if [ "$MATCHED" -eq 0 ]; then
    echo "✅ glob not present — skipping (already clean)"
  elif [ -z "$SETTINGS_MODE" ]; then
    SETTINGS_RESULT="manual"
    echo "❌ Could not read the permission mode of $SETTINGS — refusing to rewrite it, because the swap would reset the mode. Remove the $TOOL_PREFIX entries by hand." >&2
  elif ! ( umask 077; jq --arg p "$TOOL_PREFIX" \
      '.permissions.allow |= map(select((type == "string" and startswith($p)) | not))' \
      "$SETTINGS" > "$SETTINGS.tmp" ); then
    rm -f "$SETTINGS.tmp"
    SETTINGS_RESULT="manual"
    echo "❌ jq rewrite failed — $SETTINGS left untouched. Remove the $TOOL_PREFIX entries by hand." >&2
  elif ! jq -e . "$SETTINGS.tmp" >/dev/null 2>&1; then
    rm -f "$SETTINGS.tmp"
    SETTINGS_RESULT="manual"
    echo "❌ Rewritten settings is empty or invalid JSON — $SETTINGS left untouched. Remove the $TOOL_PREFIX entries by hand." >&2
  elif ! chmod "$SETTINGS_MODE" "$SETTINGS.tmp"; then
    rm -f "$SETTINGS.tmp"
    SETTINGS_RESULT="manual"
    echo "❌ Could not restore mode $SETTINGS_MODE on the staged settings — $SETTINGS left untouched. Remove the $TOOL_PREFIX entries by hand." >&2
  else
    mv "$SETTINGS.tmp" "$SETTINGS"
    SETTINGS_RESULT="removed"
    echo "✅ Removed $MATCHED workbench-ynab pre-approval entries from $SETTINGS — all other entries untouched"
  fi
fi
```

## Step 5 — The data directory: ask, and keep by default

`$DATA_DIR` holds **unencrypted, plaintext financial records** — see the artifact
inventory in [`../SECURITY.md`](../SECURITY.md) → *Generated Artifacts*. Deleting
it destroys the write-back audit trail. So this step **never deletes silently**:
it asks, and the default answer is **Keep**.

Skip the prompt entirely when the directory is already gone:

```bash
if [ ! -d "$DATA_DIR" ]; then
  DATA_RESULT="skipped"
  echo "✅ Data directory not present — skipping (already clean)"
fi
```

Otherwise ask, naming every record class the directory contains:

```jsonc
AskUserQuestion({
  questions: [{
    question: "Delete the workbench-ynab data directory (~/.claude/plugins/data/workbench-ynab-claude-workbench/)? It holds UNENCRYPTED plaintext financial records: config.json (budget, business identity, tax profile), audit/audit-<YYYY-MM>.jsonl (your write-back audit trail), proposals/ (pending change-sets), monitor-state.json, alert-log.jsonl, tax-profile.json, and tax-tracker.json. Deletion is IRREVERSIBLE — there is no backup and the audit trail cannot be reconstructed.",
    header: "Data dir",
    multiSelect: false,
    options: [
      { label: "Keep it (recommended)",
        description: "Default. Nothing is touched. The directory stays at its current path and keeps its owner-only 0700 permissions; delete it yourself later if you want to." },
      { label: "Delete it permanently",
        description: "Irreversibly removes the directory and every financial record listed above, including the audit trail." }
    ]
  }]
})
```

Offer **Keep first** — it is the default, and the answer to take on any
ambiguous, empty, or absent reply. Only an explicit choice of *Delete it
permanently* sets `DATA_CHOICE=delete`.

```bash
if [ "$DATA_CHOICE" = "delete" ]; then
  rm -rf "$DATA_DIR"
  if [ -d "$DATA_DIR" ]; then
    DATA_RESULT="manual"
    echo "❌ Could not fully remove $DATA_DIR — it still exists. Remove it by hand." >&2
  else
    DATA_RESULT="deleted"
    echo "✅ Deleted $DATA_DIR — every financial record it held is gone"
  fi
else
  DATA_RESULT="kept"
  echo "✅ Kept $DATA_DIR — no files were touched. Delete it yourself when you're ready."
fi
```

The post-`rm` `[ -d ]` re-check is the confirmation the deletion actually
happened: `rm -rf` exits 0 on a directory it could not fully clear, so its exit
status alone would report success on a partial delete.

**Reports live elsewhere and are never touched here.** Generated reports go to
`.report.output_dir` (default `~/Documents/Claude/Reports/`), outside
`$DATA_DIR`. That is a user-chosen directory that may hold unrelated files, so
this command never deletes it. Print its path and point at
`/workbench-ynab:ynab-prune` (or a manual delete) in the summary.

## Step 6 — Remind the user to revoke the token

Print this block verbatim, whatever happened in Step 3. It is the one part of
the teardown no command can do for the user:

```text
═══════════════════════════════════════════
  ⚠️  REVOKE YOUR YNAB TOKEN — MANUAL STEP
═══════════════════════════════════════════

  Deleting the Keychain entry removed the token from THIS MACHINE.
  It does NOT revoke it at YNAB — the token still grants full access
  to your budget from anywhere it has been copied.

  Revoke it now:
    1. Open https://app.ynab.com/settings/developer
    2. Account Settings → Developer Settings
    3. Delete the Personal Access Token you issued for this plugin

  Until you do this, the token remains live.
═══════════════════════════════════════════
```

## Step 7 — Teardown summary

Close with one summary listing every component and its outcome, using the
`$KEYCHAIN_RESULT` / `$SETTINGS_RESULT` / `$DATA_RESULT` values the steps set —
never a generic "done". Report what was **removed**, what was **not found /
skipped**, what was **deliberately kept**, and what **manual steps remain**.

```text
═══════════════════════════════════════════
  workbench-ynab teardown summary
═══════════════════════════════════════════

  Scheduled task ynab-review:    removed | not found — skipped | MCP unreachable
  Scheduled task ynab-monitor:   removed | not found — skipped | MCP unreachable
  Keychain (ynab-mcp):           removed | not found — skipped | remove by hand
  settings.json pre-approvals:   removed N entries | glob not present — skipped | remove by hand
  Data directory:                deleted | KEPT at <path> | not present — skipped
  Report directory:              kept at <path> — never touched by uninstall

  Manual steps remaining:
    • Revoke the YNAB token at https://app.ynab.com/settings/developer   ← always
    • <any component reported "remove by hand" above>
    • Remove the plugin itself: claude plugin uninstall workbench-ynab@claude-workbench
    • <if kept> Delete <data-dir> yourself when you no longer need the records
    • <if reports exist> Prune reports with /workbench-ynab:ynab-prune, or delete <report-dir>

  Re-run /workbench-ynab:uninstall any time — every step is idempotent and
  reports "already clean" for what is already gone.
═══════════════════════════════════════════
```

Substitute the real paths and the real per-component outcomes. Never print a
"removed" line for a component that was absent.

## Manual checklist

A user who removed the plugin before running this command has no
`/workbench-ynab:uninstall` left to run. The equivalent by-hand checklist —
one entry per automated step above — lives in
[`../docs/uninstall.md`](../docs/uninstall.md). Keep the two in step: a change to
any step here needs the matching checklist entry updated in the same commit.
