# Write-back safety — the full model

This is the single human-readable reference for how `workbench-ynab` writes to
YNAB without ever being able to hurt you: which operations are allowed, which
are forbidden, the batch-approval gate every write sits behind, and the exact
namespaced tools involved. It ties together the machine contracts — the
change-set schema, the write-safety guardrail, the apply executor, and the
approval command — which stay authoritative for their edge-case detail.

> ⚠️ Estimates only — not tax advice. Consult a qualified professional before filing or paying.
> (Canonical wording: [`skills/shared/disclaimer.md`](../skills/shared/disclaimer.md).)

> **The code is the source of truth.** This doc describes the behavior the M4
> modules actually implement. If anything here diverges from
> [`assets/write-safety-guardrail.js`](../assets/write-safety-guardrail.js),
> [`assets/apply-executor.js`](../assets/apply-executor.js), or
> [`assets/changeset-schema.json`](../assets/changeset-schema.json), **the code
> wins** and this doc must be corrected to match it.

## The promise

**Every write is ledger-only, and the plugin NEVER moves real money.** It
initiates no transfers and no payments to the outside world — no money ever
leaves or moves between your real accounts. Writes only edit YNAB's *records*:
what category a transaction carries, how a month's budget is allocated, whether
a double-entered transaction is removed, whether an account's cleared balance
is reconciled.

## Allowed operations — ledger-only, exactly four

| Operation | What it changes | Change-set op type |
|---|---|---|
| **Categorize** | Assign a transaction to a category. | `categorize` |
| **Allocate** | Move money from Ready-to-Assign into a category's monthly budget. | `allocate` |
| **Fix duplicates** | Delete a double-entered transaction (with its surviving twin as evidence). | `delete_duplicate` |
| **Reconcile** | Bring an account's cleared/reconciled balance into line. | `reconcile` |

These four are the **complete** list. The allow-list is enumerated in one place
— `LEDGER_ONLY_OP_TYPES` in
[`assets/write-safety-guardrail.js`](../assets/write-safety-guardrail.js) — and
anything not positively matched to it is blocked (see **Enforcement** below).

## Forbidden operations — no real-money movement, ever

- **No transfers** — nothing that creates or moves funds across an account
  boundary, including transfer-creating transaction edits.
- **No payments out of YNAB** — the plugin never initiates a payment to the
  outside world.
- **No transaction creation** — the vendored MCP's create verbs can fabricate
  inflows/outflows (money-shaped records), so they are explicitly deny-listed,
  not merely unused.
- **No account or default-budget mutation.**

The guardrail also hard-blocks money-movement *smuggled inside an allowed
operation*: a `categorize` op whose proposed state carries a
`transfer_account_id`, a transfer payee, or a proposed `payee_id` repoint is
blocked even though `categorize` itself is an allowed type. See
[`skills/write-safety-guardrail.md`](../skills/write-safety-guardrail.md) for
the transfer-detection rules.

## Enforcement — two layers, both fail-closed

1. **Structural (schema).** Every change-set carries `money_movement: false` as
   a JSON Schema **`const`** — a money-moving change-set is *unrepresentable*
   and fails validation outright. Contract:
   [`assets/changeset-contract.md`](../assets/changeset-contract.md).
2. **Runtime (guardrail).** Before any apply, the M4-2 write-safety guardrail
   evaluates the change-set, each operation, and each exact tool name about to
   be invoked. The default verdict is **BLOCK**: an operation or tool passes
   only when positively matched to the ledger-only allow-list and every scope
   assertion (budget targeting, destructive tagging) holds. One block verdict
   aborts the whole batch. Contract:
   [`skills/write-safety-guardrail.md`](../skills/write-safety-guardrail.md).

The schema makes a money-moving change-set unrepresentable; the guardrail makes
a money-moving apply impossible. **Both must hold.**

## The batch-approval gate — one approval = one batch

Write-back never happens silently, and there is **no auto-apply**. Changes flow
through a fixed lifecycle in which human approval gates the transition from
proposal to any write ([`assets/changeset-contract.md`](../assets/changeset-contract.md)):

1. **Propose** — the review surfaces its fixes as a single proposed
   **change-set** (an ordered batch of typed operations, each with a `before`
   snapshot, an `after` proposal, a one-line rationale, and a risk tag).
   Nothing has touched the ledger yet.
2. **Approve** — the change-set is presented **as a batch** and the human
   approves explicitly, via the three-options protocol in
   [`/workbench-ynab:ynab-apply`](../commands/ynab-apply.md): apply as-is,
   apply a subset, or reject. **One approval covers one batch** — approving one
   change-set never pre-approves the next, and no schedule, config value, or
   persona text can stand in for the human's explicit yes.
3. **Dry-run** — the apply executor runs in **dry-run by default**, reporting
   the exact before → after diff without calling any write tool
   ([`skills/apply-executor.md`](../skills/apply-executor.md)).
4. **Apply** — only after approval does the executor run with `dry_run=false`,
   applying the approved operations in order. The `/ynab-apply` command is the
   **only** path that ever sets `dry_run=false`; every other skill, hook, and
   scheduled task is read-only or dry-run-only.
5. **Audit** — every apply (dry-run included) is appended to the audit log for
   a durable, replayable record ([`docs/audit-log.md`](./audit-log.md)), which
   also makes re-runs idempotent: already-applied operations are skipped.

**Destructive operations get a second gate.** A `delete_duplicate` is always
tagged `risk: "destructive"` and requires its own stronger confirmation beyond
batch approval before the delete executes
([`skills/delete-duplicate.md`](../skills/delete-duplicate.md)).

## The exact namespaced write tools

The vendored YNAB MCP's write surface, by fully namespaced tool name. The
canonical machine-referenced list lives in
[`skills/protocol/ynab-tools.md`](../skills/protocol/ynab-tools.md); the
allow/deny classification is enforced by `ALLOWED_TOOLS` / `DENIED_TOOLS` in
[`assets/write-safety-guardrail.js`](../assets/write-safety-guardrail.js).

| Namespaced tool | Used by | Guardrail verdict |
|---|---|---|
| `mcp__plugin_workbench-ynab_ynab__ynab_update_transaction` | categorize, reconcile | ✅ allowed |
| `mcp__plugin_workbench-ynab_ynab__ynab_update_transactions` | categorize (bulk), reconcile | ✅ allowed |
| `mcp__plugin_workbench-ynab_ynab__ynab_update_category` | allocate | ✅ allowed |
| `mcp__plugin_workbench-ynab_ynab__ynab_delete_transaction` | fix duplicates (destructive — extra confirmation, never pre-approved) | ✅ allowed |
| `mcp__plugin_workbench-ynab_ynab__ynab_reconcile_account` | reconcile | ✅ allowed |
| `mcp__plugin_workbench-ynab_ynab__ynab_create_transaction` | — nothing | ⛔ denied (money movement) |
| `mcp__plugin_workbench-ynab_ynab__ynab_create_transactions` | — nothing | ⛔ denied (money movement) |
| `mcp__plugin_workbench-ynab_ynab__ynab_create_receipt_split_transaction` | — nothing | ⛔ denied (money movement) |
| `mcp__plugin_workbench-ynab_ynab__ynab_create_account` | — nothing | ⛔ denied (account mutation) |
| `mcp__plugin_workbench-ynab_ynab__ynab_set_default_budget` | — nothing | ⛔ denied (budget mutation) |

> **Intentional divergence from the issue #71 wording, called out here:** the
> design brief listed the two create tools among "write tools used." They are
> part of the MCP's write *surface*, but no write path in this plugin uses them
> — they can fabricate money-shaped records, so the guardrail **deny-lists** them
> (`denied_tool_money_movement`) and they appear in no pre-approval list.
> Documenting them as "used" would be wrong; documenting them as denied is the
> truth the code enforces. The three rows below the pair — `ynab_create_receipt_split_transaction`,
> `ynab_create_account`, and `ynab_set_default_budget` — are the remaining
> `DENIED_TOOLS` entries the guardrail blocks, listed so this write-surface
> reference matches
> [`assets/write-safety-guardrail.js`](../assets/write-safety-guardrail.js)'s
> full deny-list rather than understating it, even though issue #71's AC named
> only the seven-tool subset above them.

**Pre-approval is not approval.** Setup pre-approves the **read** tools only —
write pre-approval is a manual opt-in: setup never seeds a write verb. To
silence Claude Code's redundant *per-call* permission dialog on the four
non-destructive write tools, the human hand-adds them to
`~/.claude/settings.json` by exact name (never a family glob, never the delete
verb) per the permission notes in
[`docs/mcp-capability-map.md`](./mcp-capability-map.md). Opted-in or not, the
human-approval gate for a write batch is the `/ynab-apply` flow plus the
guardrail — pre-approval never bypasses it. See the write-phase notes in
[`skills/protocol/ynab-tools.md`](../skills/protocol/ynab-tools.md).

## What can never override any of this

- **Persona and voice config are inert here.** The write-authorization gate
  reads no persona config whatsoever; a hostile `persona.voice_overrides` value
  has zero effect on tool permissions or write approval
  ([`docs/persona.md`](./persona.md), "Invariant").
- **The review is read-only.** The 12-section review
  ([`docs/methodology.md`](./methodology.md)) calls read tools only; it
  proposes, never applies.
- **The orchestrator holds no write tools** — its `tools:` list is a read-only
  subset ([`agents/ynab-orchestrator.md`](../agents/ynab-orchestrator.md)).

---

> ⚠️ Estimates only — not tax advice. Consult a qualified professional before filing or paying.
