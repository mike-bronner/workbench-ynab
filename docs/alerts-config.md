# Alert rules config + notification dispatch (M6-2)

Proactive monitoring (M6-1, [`lib/monitor/state.mjs`](../lib/monitor/state.mjs))
is only useful if the user finds out. This contract defines **where alerts go**
and **how they are configured**: the `alerts` block of the out-of-repo
`config.json` (the thresholds that make a condition alert-worthy) and the
dispatch layer in [`lib/monitor/alerts.mjs`](../lib/monitor/alerts.mjs) (the
delivery channel for the resulting nudge). Keeping rules and dispatch separate
from the detectors (M6-3) means thresholds are **user-tunable data, not code**.

**The `alerts` block is read exclusively by the monitoring skill.** It is never
injected into the YNAB MCP launcher environment — `bin/launcher.sh` receives
only the Keychain token and native env, and cannot see this config (see
[`config-loader.md`](config-loader.md); pinned by a unit test).

## The `alerts` config block

Lives in `config.json` at the plugin data dir (see
[`config-schema.md`](config-schema.md) for the file's location and envelope).
**Zero-config:** omit the whole block and monitoring works — every field has a
shipped default. Invalid values fall back **per field**; a malformed block never
throws (user config is a trust boundary).

| Field | Type | Default | Units | Description |
|---|---|---|---|---|
| `enabled` | boolean | `true` | — | Master switch for alert dispatch. `false` silences all alerts; the monitor pass still advances its state snapshot. |
| `large_transaction_amount` | number > 0 | `500` | **whole dollars** | A single transaction at or above this amount is alert-worthy. |
| `unusual_multiplier` | number > 0 | `3` | ratio | A transaction this many times the category's typical spend counts as unusual. |
| `budget_overrun_pct` | number > 0 | `100` | percent | A category spent at or beyond this percentage of its budgeted amount is overrun. |
| `bill_due_lookahead_days` | integer ≥ 0 | `3` | days | How many days ahead an upcoming scheduled bill is worth flagging. |
| `overdrawn` | boolean | `true` | — | Whether a negative account balance is alert-worthy. |
| `channel` | string enum | `"macos-notification"` | — | Delivery-channel switch — see [Channels](#channels) below. |
| `tax` | object | *(see below)* | — | Quarterly estimated-tax reminders (M6-5) — see [Estimated-tax reminders](#estimated-tax-reminders-m6-5) below. |

```json
"alerts": {
  "enabled": true,
  "large_transaction_amount": 500,
  "unusual_multiplier": 3,
  "budget_overrun_pct": 100,
  "bill_due_lookahead_days": 3,
  "overdrawn": true,
  "channel": "macos-notification",
  "tax": { "lead_time_days": 7, "reminders_enabled": true }
}
```

### Dollars in, milliunits out

Config thresholds are entered in **whole dollars** (human-friendly); YNAB API
amounts are **milliunits** (integers, dollars × 1000). `loadAlertsConfig()` /
`sanitizeAlertsConfig()` convert **at the boundary** — the loaded shape exposes
`largeTransactionMilliunits` — so detectors only ever compare milliunits to
milliunits and nothing downstream mixes units.

| Config key (whole dollars) | Loaded key (milliunits) |
|---|---|
| `large_transaction_amount` | `largeTransactionMilliunits` |

## The finding contract (what M6-3 detectors emit)

Detectors emit **structured findings**; the dispatch layer renders them. A
finding is a plain object with exactly these fields:

| Field | Type | Allowed values / shape |
|---|---|---|
| `severity` | string enum | `'action'` (🔴 action required), `'attention'` (🟡 attention needed), `'info'` (🟢 good / informational) |
| `title` | string | The **bold one-line statement** — the finding itself as one sentence. |
| `detail` | string | Context for the audit trail. Carried into the alert-log entry; **not rendered** in the dispatch line. |
| `suggested_action` | string | 1–2 sentence recommended action, rendered after the title. |
| `dedupe_key` | string | `{type}:{account_or_category}:{period}` — see below. |

The severity taxonomy **must agree** with the frozen review-dispatch contract
([`dispatch-format.md`](dispatch-format.md)): 🔴 / 🟡 / 🟢 mean the same thing in
a monitor alert, a review dispatch, and a report badge.

### `dedupe_key` — the fired-alert ledger key

Format: **`{type}:{account_or_category}:{period}`** — e.g.
`large_transaction:acct-1:2026-06` or `budget_overrun:Groceries:2026-07`. Build
it with the exported `dedupeKey(type, accountOrCategory, period)` helper.

The key feeds the **M6-1 fired-alert ledger** — the `firedAlerts` field of
`monitor-state.json` ([`lib/monitor/state.mjs`](../lib/monitor/state.mjs)
`recordFiredAlert()`), which **skips a key that already exists** — so the same
condition is never re-announced on every poll. Detectors must record each
dispatched finding's `dedupe_key` there, and pick a `period` granularity that
matches how often re-announcing is acceptable (e.g. the month for a budget
overrun).

## Estimated-tax reminders (M6-5)

The quarterly estimated-tax reminder is a **detector** in the M6-3 sense — it
emits ordinary findings the dispatch layer above delivers unchanged — but it
lives with the tax code
([`lib/tax/estimatedTaxReminder.mjs`](../lib/tax/estimatedTaxReminder.mjs),
issue #83) because it reads the M6-4 tracker and the tax profile. It is a **thin
layer**: it invents no tax math and no delivery, only the decision of *when to
nudge*.

**Cadence — no new cron entry.** The reminder runs inside the **unified
`ynab-review` scheduled task** (M2-11 / `schedules.review`), keyed on the same
quarterly due-date window the read-only orchestrator's tier-routing already owns.
The review router computes today's date in the configured timezone, resolves the
due dates and tracker, calls the detector, and dispatches any findings through
`dispatchAlerts` — so estimated-tax reminders add **zero** scheduled tasks (they
piggy-back the review's cadence, mirroring bujo's one-task pattern).

`computeQuarterlyTaxReminders({ today, dueDates, tracker, leadTimeDays, remindersEnabled })`
returns zero or more findings:

| Condition | Result |
|---|---|
| `reminders_enabled` is `false` | No findings — the master switch. |
| `today` within `lead_time_days` calendar days **before** a due date | 🟡 `attention` lead-time reminder. |
| `today` **is** the due date and no payment recorded for that quarter | 🔴 `action` — escalated (overdue signal). |
| the quarter already has ≥1 payment in the tracker | Suppressed — no reminder (no nagging after payment). |
| `today` earlier than `lead_time_days` before, or after, the due date | No finding. |

- **Due dates come from config, never code.** The Apr 15 / Jun 15 / Sep 15 /
  Jan 15 dates are read from the tax profile
  (`loadProfile().getQuarterlyDueDates(year)`); the detector receives resolved
  `{ quarter, date, taxYear }` entries and hardcodes no quarter date. The
  router unions this tax year's and last tax year's quarters so a January run
  still sees the prior year's Q4 (due Jan 15).
- **Timezone.** All comparisons are civil-date arithmetic on `today`, which the
  router computes in the user's configured timezone — the same timezone key used
  everywhere else in the plugin.
- **Rendering** (each finding) includes the quarter label (e.g. `Q3 2026`), the
  due date, the current remaining-due estimate from the tracker, and the
  recommended payment amount, and carries the canonical compact not-tax-advice
  tag verbatim (`skills/shared/disclaimer.md`).
- **`dedupe_key`** is `estimated_tax_reminder:Q{n}-lead:{taxYear}` for the
  lead-time reminder and `…-due:…` for the due-day one — distinct so the due-day
  🔴 still fires on the deadline even after the lead-time 🟡 fired earlier.
- **stderr discipline.** The detector is pure and writes nothing; diagnostics on
  the surrounding path go to stderr only, never leaking into the dispatch channel.

## Rendering

`renderAlerts(findings)` renders one line per finding, **most-severe first**
(`action` → `attention` → `info`, stable within a severity), **capped at the
top 5** (`MAX_FINDINGS`, matching the review dispatch's fixed five):

```
{emoji} **{title}** {suggested_action}
```

`detail` is not rendered — it travels in the alert-log entry.

## Channels

`dispatchAlerts(findings)` is the entry point the monitor pass calls. The
`channel` config value is a **dispatch switch**:

| `channel` value | Delivery |
|---|---|
| `macos-notification` *(default)* | Best-effort macOS desktop notification (darwin-only, guarded `osascript` call) **plus** the alert log. |
| `log-only` | Alert log only. |

- **The alert log is unconditional.** Every dispatch appends the rendered
  alert(s) to `alert-log.jsonl` under the plugin data dir, regardless of the
  active channel — this is the audit trail. Each line is one JSON entry:
  `{ timestamp, channel, findings, rendered }`, with the **full** findings
  (`detail` and `dedupe_key` included). The file is written owner-only
  (dir `0700`, file `0600`), same sensitivity class as the monitor state —
  and the modes are re-enforced on every append (creation-time modes alone
  never tighten a pre-existing dir/file; `bin/audit-log.sh` keeps the same
  guarantee the same way).
- **Notification is best-effort by contract.** Off-darwin it is skipped; a
  missing or failing `osascript` returns `false` and logs to stderr — a failed
  notification **never** raises an exception or crashes the monitor pass.
  Finding text is passed to `osascript` as argv, never interpolated into
  AppleScript source, so alert content cannot inject script.
- **Adding a channel** (e.g. a notification MCP) requires only a new `channel`
  enum value (`CHANNELS` in the module + the JSON Schema) and a new branch in
  `dispatchAlerts` — **detector code never changes**.

## Test-harness seams

Mirroring the monitor state store: `options.configFile` → env
`YNAB_CONFIG_FILE` for the config read, and `options.logPath` → env
`YNAB_ALERT_LOG_FILE` → `YNAB_DATA_DIR` for the alert log. The notification
path stubs via `options.platform` / `options.spawnImpl`, so the suite passes on
non-darwin CI. See
[`tests/unit/monitor-alerts.test.mjs`](../tests/unit/monitor-alerts.test.mjs).
