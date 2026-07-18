---
description: Prune old generated YNAB review reports under the retention policy — reports are unencrypted plaintext financial records that otherwise accumulate unbounded. Previews by default (dry-run); deletes only after you approve, via bin/ynab-prune.sh --apply. Age threshold defaults to 30 days, overridable via .report.retention_days or --days N.
---

The user invoked `/workbench-ynab:ynab-prune` to remove old generated review
reports. Reports are **unencrypted, plaintext financial records** (see the
[Generated Artifacts](../SECURITY.md#generated-artifacts) section of
`SECURITY.md`), so pruning old ones keeps financial history from accumulating on
disk indefinitely.

## Execution

1. **Preview first (always).** Run the prune helper in its default dry-run mode
   and show the user the output verbatim:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/ynab-prune.sh"
   ```

   It resolves the report directory (`.report.output_dir`, default
   `~/Documents/Claude/Reports`) and the age threshold (`.report.retention_days`,
   default **30 days**) from `config.json`, lists exactly which report files it
   *would* delete, and removes nothing. Pass `--days N` to override the threshold
   or `--output-dir DIR` to override the directory for this run.

2. **Confirm before deleting.** Show the candidate list and ask the user to
   approve. Deletion is irreversible.

3. **Apply on approval only.** When (and only when) the user approves, re-run with
   `--apply`:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/ynab-prune.sh" --apply
   ```

   Carry through any `--days` / `--output-dir` the user chose in step 1 so the
   apply matches the preview.

## Hard rules

- **Never delete without an explicit preview + approval.** The default (no
  `--apply`) is dry-run; only add `--apply` after the user has seen the list and
  said yes.
- **Only reports are pruned.** The helper only ever removes files matching the
  report writer's `YNAB-*-Review-*.html` naming pattern, directly in the report
  directory. It never touches the audit log, monitor state, tax tracker, config,
  or any sub-directory.
- **Retention is config-driven.** The threshold comes from
  `.report.retention_days` (default 30) — never hardcode a different value here.
