# Uninstall / teardown — by hand

> ⚠️ Estimates only — not tax advice. Consult a qualified professional before filing or paying.

Removing the plugin does **not** remove the system state
`/workbench-ynab:setup` created outside the plugin directory. Four things stay
behind: the scheduled tasks, the Keychain token, the `settings.json`
pre-approvals, and the plaintext data directory.

**Run `/workbench-ynab:uninstall` if you still have the plugin installed** — it
does everything below, asks before touching your financial records, and is safe
to re-run. This page is the by-hand equivalent for the case where the plugin is
already gone.

Every step here is idempotent: if a component is already gone, the step is a
no-op. Work through them in order.

## Checklist

- [ ] **1. Inventory what is present** (nothing is removed by this step)
- [ ] **2. Remove the scheduled tasks** — `ynab-review` and `ynab-monitor`
- [ ] **3. Remove the Keychain entry** — `ynab-mcp` / `access-token`
- [ ] **4. Remove the pre-approval entries** from `~/.claude/settings.json`
- [ ] **5. Decide on the data directory** — keep (default) or delete
- [ ] **6. Revoke the YNAB token at the YNAB web UI** — nothing local can do this
- [ ] **7. Remove the plugin itself**

## Constants

```bash
DATA_DIR="$HOME/.claude/plugins/data/workbench-ynab-claude-workbench"
SETTINGS="$HOME/.claude/settings.json"
KEYCHAIN_SERVICE="ynab-mcp"
KEYCHAIN_ACCOUNT="access-token"
TOOL_PREFIX="mcp__plugin_workbench-ynab_ynab__"
```

## 1. Inventory what is present

See what the teardown will touch before you touch it:

```bash
security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1 \
  && echo "Keychain entry: present" || echo "Keychain entry: absent"
jq -r --arg p "$TOOL_PREFIX" \
  '[.permissions.allow // [] | .[] | select(type == "string" and startswith($p))] | length' \
  "$SETTINGS" 2>/dev/null || echo "settings.json: missing or unreadable"
[ -d "$DATA_DIR" ] && echo "Data dir: present" || echo "Data dir: absent"
```

## 2. Remove the scheduled tasks

Setup deploys exactly two task ids — `ynab-review` (the unified review) and
`ynab-monitor` (the between-run monitor). Remove both through the
scheduled-tasks MCP that created them:

```text
mcp__scheduled-tasks__list_scheduled_tasks           # confirm which exist
mcp__scheduled-tasks__delete_scheduled_task          # taskId: ynab-review
mcp__scheduled-tasks__delete_scheduled_task          # taskId: ynab-monitor
```

Skip any id the list does not contain. Leave every other task alone — in
particular `ynab-financial-review` and `ynab-cleanup-remaining`, which belong to
the legacy prototype and are `/workbench-ynab:ynab-migrate`'s job.

## 3. Remove the Keychain entry

```bash
security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT"
```

A `The specified item could not be found in the keychain.` error means it is
already gone — nothing to do. If the command fails for any other reason, the
entry is still there: unlock your login keychain and retry, or delete the
`ynab-mcp` password in **Keychain Access.app**.

This removes the token from **this machine only**. It does not revoke it at
YNAB — that is step 6, and it is not optional.

## 4. Remove the pre-approval entries from settings.json

Setup added the read-tool names to `permissions.allow`. Remove only the entries
carrying the plugin prefix, and leave every other entry and key alone:

```bash
SETTINGS_MODE="$(stat -L -c '%a' "$SETTINGS" 2>/dev/null || stat -L -f '%Lp' "$SETTINGS" 2>/dev/null)" \
  && ( umask 077; jq --arg p "$TOOL_PREFIX" \
    '.permissions.allow |= map(select((type == "string" and startswith($p)) | not))' \
    "$SETTINGS" > "$SETTINGS.tmp" ) \
  && jq -e . "$SETTINGS.tmp" >/dev/null \
  && chmod "$SETTINGS_MODE" "$SETTINGS.tmp" \
  && mv "$SETTINGS.tmp" "$SETTINGS" \
  || { rm -f "$SETTINGS.tmp"; echo "settings.json left untouched — fix it by hand"; }
```

The `&&` chain is what keeps this safe: the rewrite is staged in a temp file and
re-validated as JSON before it replaces the original, so a failure anywhere
leaves `settings.json` exactly as it was. If no entry matches, the filter is a
no-op and the file is rewritten identically.

The chain also preserves the file's **permission mode**. `mv` on one filesystem
is a `rename(2)`, so the published file carries the *staged* file's mode, not the
original's — staging under the ambient umask would reset a `settings.json` you
hardened to `600` back to the umask default (commonly `644`, world-readable).
`stat` reads the mode first (GNU `-c '%a'`, BSD/macOS `-f '%Lp'`), the `umask
077` subshell keeps the staged copy owner-only while it exists, and `chmod`
restores your mode before the swap. A failure at any of those links — including
a mode that cannot be read — drops the temp file and leaves `settings.json`
alone.

`stat -L` follows symlinks on purpose. If your `settings.json` is a symlink into
a dotfiles repo (chezmoi, Stow, dotbot), the mode that matters is the *target's*
— without `-L` you would read the link's own mode instead (`755` on macOS, a
fixed `777` on Linux) and hand that to `chmod`, widening the file you hardened.
Note that `mv` still replaces the link with a regular file, so re-link it from
your dotfiles repo afterwards.

## 5. Decide on the data directory

`$DATA_DIR` holds **unencrypted, plaintext financial records**:

| File | Contains |
|---|---|
| `config.json` | Budget ids, business identity, tax profile |
| `audit/audit-<YYYY-MM>.jsonl` | Your write-back audit trail — every applied ledger write |
| `proposals/changeset-<stamp>.json` | Pending proposed change-sets |
| `monitor-state.json` | Latest between-run monitoring snapshot |
| `alert-log.jsonl` | Monitoring alerts |
| `tax-profile.json` | Filing status, rates, thresholds |
| `tax-tracker.json` | Running estimated-tax totals |

Full detail in [`../SECURITY.md`](../SECURITY.md) → *Generated Artifacts*.

**Keeping it is the recommended default.** The audit trail is the record of every
change this plugin made to your ledger, and deletion is irreversible — there is
no backup and it cannot be reconstructed. Keep it unless you are certain.

To delete it, and only then:

```bash
rm -rf "$DATA_DIR"
[ -d "$DATA_DIR" ] && echo "NOT fully removed — remove it by hand" || echo "Deleted"
```

The re-check matters: `rm -rf` exits 0 on a directory it could not fully clear,
so its exit status alone would report success on a partial delete.

**Reports are separate.** Generated reports live in `.report.output_dir`
(default `~/Documents/Claude/Reports/`), outside `$DATA_DIR`. That is a
user-chosen directory that may hold unrelated files, so nothing here deletes it
— prune it with `bash bin/ynab-prune.sh --apply`, or delete the report files by
hand.

## 6. Revoke the YNAB token — always

Deleting the Keychain entry removed the token from this machine. It does **not**
revoke it at YNAB: the token still grants full access to your budget from
anywhere it has been copied.

1. Open <https://app.ynab.com/settings/developer>
2. **Account Settings → Developer Settings**
3. Delete the Personal Access Token you issued for this plugin

Until you do this, the token remains live.

## 7. Remove the plugin itself

```bash
claude plugin uninstall workbench-ynab@claude-workbench
```
