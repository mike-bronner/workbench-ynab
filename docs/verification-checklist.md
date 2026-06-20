# End-to-end verification checklist

> **Type:** Release gate (human-run). Run this **once** before cutting `1.0.0`
> (Sprint 5 / M5). It is the manual companion to the automated offline-boot
> proof in [`tests/offline-boot.sh`](../tests/offline-boot.sh) — the script
> guarantees the bundle *boots*; this checklist confirms the whole plugin
> *behaves*, end to end, on a real machine with a real token.

Work top to bottom on a clean install. Tick each box only when its **Pass when**
condition holds. If any step fails, stop and file an issue — do not cut the
release.

**Before you start**

- macOS with a system `node`, `jq`, and `security(1)` on `PATH` (see the README
  Prerequisites).
- A real YNAB Personal Access Token to hand (you will paste it once, in step 2).
- A throwaway or non-critical budget is fine — step 5 onward proposes writes, but
  nothing is applied without your explicit approval.

---

## 0. Automated pre-flight — the offline-boot proof

Before any manual step, run the automated gate. It must be green or the build is
not releasable.

```bash
bash tests/offline-boot.sh
```

- [ ] **Pass when:** the script prints `N passed, 0 failed` and exits `0` — the
      committed bundle's checksum matches `vendored.json`, it boots from a
      node_modules-free sandbox, stdout is pure JSON-RPC, and `tools/list`
      includes the full required tool set.

---

## 1. Setup runs clean from a fresh install

Start from a clean checkout with **no** prior plugin config or Keychain entry.

```bash
/workbench-ynab:setup
```

- [ ] **Pass when:** setup completes without error, reports the vendored MCP
      launches, and creates no token file on disk (the token goes to the
      Keychain in the next step, never to a file in the repo or config dir).

## 2. Keychain token read — no plaintext token anywhere

During setup you paste your YNAB Personal Access Token; it is stored in the macOS
Keychain (service `workbench-ynab`, account `YNAB_ACCESS_TOKEN`) and read by the
launcher at MCP start — never written to disk, never echoed.

```bash
# The token is present in the Keychain:
security find-generic-password -s workbench-ynab -a YNAB_ACCESS_TOKEN -w >/dev/null && echo "token present"
# …and the launcher reads it without leaking it. Inspect any logs/output:
grep -rIi "$(security find-generic-password -s workbench-ynab -a YNAB_ACCESS_TOKEN -w)" run/ *.log 2>/dev/null && echo "LEAK" || echo "no leak"
```

- [ ] **Pass when:** the token is present in the Keychain, the launcher starts
      the MCP using it, and the token value appears in **no** log, terminal
      output, or error message (the `grep` prints `no leak`).

## 3. Read-only review produces an HTML report

Run the weekly review (read-only path — it pulls budget, accounts, transactions
and renders a report; it proposes nothing yet).

- [ ] **Pass when:** the review completes and writes a polished, tax-aware
      **HTML** report (Schedule C / A / SE awareness, medical-threshold and
      quarterly-estimate signals), and the run made **no** writes to YNAB.

## 4. The report ships the `@media print` CSS

Open the report's HTML source and inspect its `<style>` block. The frozen v1
template must include the print stylesheet the prototype only *promised* (the
prototype's actual output was missing it — this is the known bug v1 fixes).

```bash
# Point at the report just produced:
grep -c "@media print" path/to/report.html
```

- [ ] **Pass when:** the report's `<style>` block contains an `@media print`
      rule (the `grep` count is `≥ 1`), and the report prints/paginates cleanly
      in a browser's print preview.

## 5. Write-back is proposed and BLOCKS on approval

Run a review on a budget with categorizable activity so the assistant surfaces a
change-set (categorizations, Ready-to-Assign allocations, duplicate fixes,
reconciliation).

- [ ] **Pass when:** the assistant presents the changes as a **proposed**
      change-set and **stops**, waiting for explicit human approval — nothing is
      written to YNAB before you approve. Declining leaves the budget untouched.

## 6. Approving applies ledger-only changes — never money movement

Approve the proposed batch from step 5.

- [ ] **Pass when:** approval applies **only** ledger-only changes — categorize,
      allocate (move `budgeted` between categories), de-duplicate, reconcile — and
      initiates **no** transfers or payments. No money moves; only the ledger's
      organization changes. Verify the applied edits in YNAB match exactly what
      you approved (no extras).

## 7. The MCP tools invoked are the namespaced plugin tools

Confirm the review and write-back exercise the vendored MCP under the plugin
namespace, not some other server.

- [ ] **Pass when:** every YNAB tool call is namespaced
      `mcp__plugin_workbench-ynab_ynab__*` — e.g.
      `mcp__plugin_workbench-ynab_ynab__ynab_list_transactions`,
      `…__ynab_update_transactions`, `…__ynab_reconcile_account`. (The bundle's
      own tool names already carry an `ynab_` stem, so namespaced they read
      `mcp__plugin_workbench-ynab_ynab__ynab_*`.)

## 8. No token in any log, report, or error — at any step

A final sweep across everything steps 1–7 produced.

```bash
TOKEN="$(security find-generic-password -s workbench-ynab -a YNAB_ACCESS_TOKEN -w)"
grep -rIl "$TOKEN" . run/ *.log path/to/report.html 2>/dev/null && echo "LEAK FOUND" || echo "clean"
```

- [ ] **Pass when:** the token value appears in **no** log, report, config file,
      or error message anywhere — the sweep prints `clean`. The token lives only
      in the Keychain.

---

When every box above is ticked, the release gate is satisfied. Record the run
(date + commit SHA) in the release notes / CHANGELOG before tagging `1.0.0`.

> **Not tax advice.** This checklist verifies plugin behaviour only. The plugin
> organizes financial data and surfaces tax-relevant signals; it is not a
> substitute for professional tax advice.
