---
name: ynab-monitor
description: Run one proactive between-run monitoring pass — read the monitor state store, fetch fresh YNAB account balances, incremental transactions, and current-month categories through the vendored MCP, run the four alert detectors (overdrawn, large/unusual transaction, budget overrun, bill due), dispatch any NEW findings, and persist the advanced snapshot + dedupe ledger. A pass where all four detectors find nothing produces no output beyond the state timestamp. Use for the scheduled ynab-monitor task or an on-demand /workbench-ynab:ynab-monitor pass.
---

# YNAB proactive-monitor pass (M6)

The weekly review (`/workbench-ynab:ynab-review`) runs once a week; between runs,
problems can go unnoticed for days. This skill runs a **single, cheap monitoring
pass** on a more frequent cadence (default daily). It advances the monitor state
store, runs the **four between-run detectors**, and dispatches any *new* finding
to the user. A pass where **nothing is alert-worthy produces no output at all**
beyond the state-store timestamp — no notification, no log append.

The moving parts live in three repo-local modules the pass invokes via `node`:

- state primitives (read / compute-next / write / dedupe ledger) —
  [`lib/monitor/state.mjs`](../../lib/monitor/state.mjs);
- the finding contract, threshold loader, and dispatch layer —
  [`lib/monitor/alerts.mjs`](../../lib/monitor/alerts.mjs);
- the four detectors + ledger reconciliation —
  [`lib/monitor/detectors.mjs`](../../lib/monitor/detectors.mjs).

Concrete YNAB tool names live **only** in
[`skills/protocol/ynab-tools.md`](../protocol/ynab-tools.md) — resolve them from
there, never inline a name (the one rule in
[`skills/protocol/SKILL.md`](../protocol/SKILL.md)).

## The state store

A single JSON snapshot, kept in the **plugin data dir** (NOT the repo) so it
survives plugin updates:

```
~/.claude/plugins/data/workbench-ynab-claude-workbench/monitor-state.json
```

It carries exactly these top-level fields (see `defaultState()` in the module):

| Field | Type | Meaning |
|---|---|---|
| `lastPollTimestamp` | ISO-8601 string \| null | When the last pass ran. |
| `accounts` | `{ [accountId]: { cleared, uncleared } }` | Per-account balances in **milliunits (integers)**. |
| `serverKnowledge` | integer \| null | YNAB delta cursor for cheap incremental transaction fetches. |
| `firedAlerts` | object keyed by stable `dedupe_key` | Dedupe ledger so a condition is announced **once**. The detectors **record** each fired key here (`recordFiredAlert`, which skips an existing key) and **expire** a key when its condition clears (`expireFiredAlerts`) so a recurrence re-alerts. |

**Money is stored in milliunits (integers); divide by 1000 only for display.**

## Thresholds, the finding contract, and dispatch

All alert behaviour is user-tunable **data**, read from the `alerts` block of
`config.json` — never hard-coded. `loadAlertsConfig()`
([`lib/monitor/alerts.mjs`](../../lib/monitor/alerts.mjs)) returns the sanitized,
zero-config-safe shape the detectors read, and it converts dollar thresholds to
**milliunits at that one boundary** (`largeTransactionMilliunits`) so detectors
only ever compare milliunits to milliunits. See
[`docs/alerts-config.md`](../../docs/alerts-config.md) for the full block,
the finding contract (`{ severity, title, detail, suggested_action, dedupe_key }`),
and the channel switch. `dispatchAlerts(findings)` is the delivery entry point;
an **empty** findings list is a complete no-op (no notification, no log append).

## The pass — step by step

1. **Read the prior snapshot.** Invoke `readState()` (`node` against
   `lib/monitor/state.mjs`). An absent file is a normal first run.

2. **Load the alerts config.** `loadAlertsConfig()` from
   `lib/monitor/alerts.mjs`. If `enabled` is `false`, still advance state
   (step 6) but skip detection + dispatch — the master switch silences alerts
   without freezing the snapshot.

3. **Fetch fresh YNAB data through the vendored MCP.** Resolve the concrete tool
   names from [`skills/protocol/ynab-tools.md`](../protocol/ynab-tools.md) — all
   under the `mcp__plugin_workbench-ynab_ynab__*` namespace (never `mcp__ynab__*`):
   - the **`list_accounts`** read tool → current `cleared`/`uncleared` balances
     (milliunits) and per-account `balance`, `on_budget`, `closed`, `deleted`;
   - the **`list_transactions`** read tool → the incremental transaction window:
     - when `serverKnowledge` is present, pass it as the delta cursor so the MCP
       returns only what changed, and **persist the new cursor it returns**;
     - on a **first run** (no state file) or when `serverKnowledge` is `null`,
       fall back to fetching transactions **since `lastPollTimestamp`** (or a
       recent window on the very first run);
   - the **`get_month`** (or **`list_categories`**) read tool → current-month
     categories with `budgeted` / `activity` (milliunits) for the overrun
     detector;
   - for the trailing-average baseline, also gather recent same-category
     transaction amounts (a modest history window from the same
     **`list_transactions`** read) keyed by `category_id`.

   The target budget comes from config (`budget.name` / `budget.id`) via
   `bin/config.sh`; monitor + alert settings are never passed through the MCP.

4. **Run the four detectors** (`lib/monitor/detectors.mjs`), each on the data it
   needs plus the loaded config — see **[The four detectors](#the-four-detectors)**
   below. Collect all findings into one array.

5. **Reconcile against the ledger and dispatch.** Call
   `reconcileFindings(nextState, findings)` (`lib/monitor/detectors.mjs`). It
   returns `toDispatch` — the findings whose `dedupe_key` is **not already** in
   the ledger — and the updated `state` (cleared keys expired, active keys
   recorded). Pass `toDispatch` to `dispatchAlerts()`; an empty list dispatches
   nothing. Persist the reconciled ledger in step 6.

6. **Compute + persist the next snapshot.** Build the observation
   `{ timestamp, accounts, serverKnowledge?, recentTransactionCount }`, call
   `computeNextState(prior, observation)`, merge in the reconciled `firedAlerts`
   from step 5, and `writeState(next)` — **always**, even on a no-op, so
   `lastPollTimestamp` and the cursor advance. The write is atomic (temp + rename).

7. **Decide output:**
   - No finding was new (`toDispatch` empty) → **no notification, no log append**;
     only the state snapshot + timestamp advanced. This is the silent no-op.
   - One or more new findings → `dispatchAlerts` renders them (most-severe first,
     capped at five) and delivers per the configured `channel`, appending the
     audit-log entry.

## The four detectors

Each detector is an independently-callable **pure** function in
[`lib/monitor/detectors.mjs`](../../lib/monitor/detectors.mjs): it takes
already-fetched YNAB data + the loaded config and returns zero or more findings
matching the M6-2 contract. All amounts arrive in **milliunits**; thresholds are
already milliunits (`largeTransactionMilliunits`), so comparisons are
integer-exact, and milliunits are converted to whole dollars only for the
human-facing finding text.

| Detector | Fires when | Severity | `dedupe_key` |
|---|---|---|---|
| `detectOverdrawn` | an **on-budget**, open, live account's balance is below the floor (**0** — YNAB has no separate floor field, so `overdrawn: true/false` is the on/off switch) | 🔴 `action` | `overdrawn:{account_id}` |
| `detectLargeUnusualTransactions` | a **new** transaction's magnitude ≥ `large_transaction_amount`, **or** > `unusual_multiplier` × the trailing mean of its category | 🟡 `attention`, 🔴 above the hard ceiling | `large_txn:{transaction_id}` |
| `detectBudgetOverrun` | a current-month category's `|activity| / budgeted` ≥ `budget_overrun_pct` % | 🟡 `attention` | `budget_overrun:{category_id}:{YYYY-MM}` |
| `detectBillsDue` | an upcoming bill is due within `bill_due_lookahead_days` | 🟡 `attention` | `bill_due:{scheduled_txn_id}:{due_date}` |

### The unusual-transaction algorithm (explainable by design)

"Unusual" is deliberately simple: a transaction is unusual when its **magnitude**
(`Math.abs`, so a large outflow counts) exceeds `unusual_multiplier` × the
**mean of the last `TRAILING_WINDOW` (= 10) transactions in the same category**
(matched by `category_id`, most-recent first). A transaction with **no category**
gets the amount-based large check only (no category ⇒ no trailing mean), and a
category with **no history or a zero mean** yields no unusual signal (never a
divide-by-zero). The severity **upgrades to 🔴** at or above
`HARD_CEILING_MULTIPLE` (= 10) × `large_transaction_amount` — a multiple of the
configured threshold, not an independent hard-coded figure.

### Bill due — history-derived fallback (scheduled-transactions unavailable)

**The vendored MCP exposes no scheduled-transactions tool** — this is the
verified, decided gap in
[`docs/decisions/GAP-3-scheduled-transactions.md`](../../docs/decisions/GAP-3-scheduled-transactions.md)
(28 registered `ynab_` tools, none for scheduled transactions). So there is no
direct "upcoming bills" read. `detectBillsDue` therefore consumes a list of
**upcoming bills derived from recurring history** — recurring/subscription
payees and prior-month transaction patterns from the same **`list_transactions`**
/ **`get_month`** reads (the GAP-3 §2 fallback contract). Each derived bill needs
a stable `id` (used in the dedupe key in the `scheduled_txn_id` slot), a `name`,
a `date` (`YYYY-MM-DD`), and an `amount`. **This is a history estimate, not
authoritative scheduled data — surface it as such**, and re-verify the gap on any
`@dizzlkheinz/ynab-mcpb` bump past `0.26.10` (re-run the GAP-3 §1 grep).

## Hard rules

- **Thresholds come from config only.** Every threshold the detectors apply is
  read from the `alerts` block via `loadAlertsConfig()` — no threshold value is
  hard-coded. The window size `N` and the hard-ceiling multiple are documented
  **algorithm parameters**, not tunable thresholds.
- **Milliunits everywhere in comparisons.** Compare milliunits to milliunits;
  divide by 1000 (`milliunitsToDollars`) only for display/log text.
- **Dedupe + expire.** Record every dispatched finding's `dedupe_key`
  (`recordFiredAlert`, skip-existing) so a still-true condition does not re-fire;
  expire a key when its condition clears (`expireFiredAlerts`) so a recurrence
  re-alerts. Point-event `large_txn` keys never auto-expire (a transaction does
  not un-happen); the full-domain conditions (overdrawn, budget overrun, bill
  due) do.
- **Zero output on a quiet pass.** No new finding ⇒ no notification and no
  alert-log append — only the state snapshot + timestamp advance.
- **stdout discipline.** Any helper invoked on an MCP/JSON-RPC path sends
  diagnostics to **stderr only** — one stray stdout byte corrupts the handshake.

## Scheduled deployment (setup step)

The recurring `ynab-monitor` task is deployed by the **setup step** — today a
`/workbench-ynab:setup` re-run, following the unified-task pattern in
`workbench-bujo` (one task, cadence from config). Cadence is **config-driven**:
read `schedules.monitor` from `config.json` via `bin/config.sh`, applying the
defaults `cron = "0 8 * * *"` (daily 08:00) and `enabled = true` when absent.

- **When `schedules.monitor.enabled` is `true`:** deploy via
  `mcp__scheduled-tasks__create_scheduled_task` with
  - `taskId`: `ynab-monitor`
  - `description`: `YNAB proactive between-run monitoring poll`
  - `cronExpression`: `schedules.monitor.cron`
  - `prompt`: the resolved
    [`assets/prompt-templates/ynab-monitor.prompt.md`](../../assets/prompt-templates/ynab-monitor.prompt.md)

  If a task with id `ynab-monitor` already exists, call
  `mcp__scheduled-tasks__update_scheduled_task` to sync the cron and prompt —
  **idempotent on re-runs.**

- **When `schedules.monitor.enabled` is `false`:** remove the task with
  `mcp__scheduled-tasks__delete_scheduled_task` (or disable it if delete is
  unavailable).

In **all** cases the weekly-review task (`ynab-review`) is **never touched** —
`ynab-monitor` is a distinct task id.
