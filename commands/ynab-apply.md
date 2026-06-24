---
description: The human-in-the-loop approval gate for YNAB write-back. Loads the pending change-set the weekly review proposed, groups it into typed batches, dry-runs each batch through the apply executor and shows a before → after diff with rationale + risk, then runs the workbench three-options decision protocol per batch — apply-as-is / apply-a-subset / reject — and only on explicit approval re-invokes the executor with dry_run=false for the approved ops, behind the write-safety guardrail and an append-only audit trail. The ONLY interactive path that performs a real YNAB write.
---

The user has invoked `/workbench-ynab:ynab-apply`. This is the **human-in-the-loop
gate** for write-back (Sprint 4 / M4-5). The weekly review (M4-10) emits a proposed
change-set but writes **nothing**; this command is where Mike reviews that proposal,
sees exactly what would change, approves (or subsets / rejects) **batch by batch**,
and only then applies. It is the command embodiment of the locked decision: **every
change batch is gated by explicit human approval.**

It implements the workbench **three-options decision protocol** for the one real
fork it contains — *what to do with each batch* — presenting three explicit options
with a recommendation and letting the human decide; the command only executes the
chosen option.

## ⚠️ This is the only path that writes — and how config is split

- **Exclusive write path.** `/workbench-ynab:ynab-apply` is the **only** interactive
  path that ever sets `dry_run=false` on the M4-4 apply executor. **No other skill,
  hook, or scheduled task may call the write executor with `dry_run=false`** — the
  review, the orchestrator, and every read path run dry-run-only or read-only. Every
  real write in this plugin flows through the approval loop below.
- **Config split — the command reads config; the MCP gets only the token.** This
  command reads plugin config (budget id, proposal path, etc.) from
  `~/.claude/plugins/data/workbench-ynab-claude-workbench/config.json` via the
  sourced loader `${CLAUDE_PLUGIN_ROOT}/bin/config.sh`. The vendored YNAB MCP
  **never** reads `config.json` — `bin/launcher.sh` resolves only the Keychain
  token and `exec`s `node` on the bundle. Keeping the MCP launch path config-free is
  an intentional architectural boundary (see [`docs/config-loader.md`](../docs/config-loader.md)).

## Constants

```text
Config dir:     $HOME/.claude/plugins/data/workbench-ynab-claude-workbench
Config file:    $CONFIG_DIR/config.json
Proposal dir:   $CONFIG_DIR/proposals               (default; override .apply.proposal_path)
Audit dir:      $CONFIG_DIR/audit                   (one audit-YYYY-MM.jsonl per UTC month)
Tool SSoT:      ${CLAUDE_PLUGIN_ROOT}/skills/protocol/ynab-tools.md
Tool prefix:    mcp__plugin_workbench-ynab_ynab__   (NB: plugin-namespaced — the
                bare mcp__<key>__ form never resolves against the vendored MCP)
Executor:       skills/apply-executor.md            (assets/apply-executor.js, M4-4)
Guardrail:      skills/write-safety-guardrail.md    (assets/write-safety-guardrail.js, M4-2)
Audit log:      bin/audit-log.sh                    (M4-3)
Contract:       assets/changeset-contract.md        (M4-1)
```

Resolve the paths once at the top of the run, and load the config (hard-stop if it
is missing — this command cannot proceed without a budget id):

```bash
CONFIG_DIR="$HOME/.claude/plugins/data/workbench-ynab-claude-workbench"
source "${CLAUDE_PLUGIN_ROOT}/bin/config.sh"
_require_config || exit 1     # points the user at /workbench-ynab:setup

ACTIVE_BUDGET_ID="$(_cfg '.budget.id')"
PROPOSAL_DIR="$(_cfg '.apply.proposal_path')"
PROPOSAL_DIR="${PROPOSAL_DIR:-$CONFIG_DIR/proposals}"   # caller's default
```

## Step 1 — Load the pending change-set

Read the proposal the review wrote. **Coordinate with M4-10:** the review writes its
emitted change-set under the plugin **data** dir (so it survives plugin updates and
never lands in the repo), at `$PROPOSAL_DIR` — the canonical default
`~/.claude/plugins/data/workbench-ynab-claude-workbench/proposals/`, overridable with
the `.apply.proposal_path` config key. The most recent `*.json` there is the pending
proposal.

```bash
PROPOSAL="$(ls -t "$PROPOSAL_DIR"/*.json 2>/dev/null | head -1)"
if [ -z "$PROPOSAL" ]; then
  echo "✅ No pending proposal — nothing to apply."
  echo "   The weekly review writes a change-set to $PROPOSAL_DIR; run it first."
  exit 0
fi
echo "📄 Pending proposal: $PROPOSAL"
```

**No proposal file → exit cleanly** with the "no pending proposal" message above and
do **not** proceed. Otherwise, schema-validate the envelope before touching anything
(the executor validates again, fail-closed, but catching a malformed proposal here
gives the human a clear message instead of a raw abort):

```bash
node "${CLAUDE_PLUGIN_ROOT}/assets/validate-changeset.js" "$PROPOSAL" >/dev/null \
  || { echo "❌ The pending proposal is not a valid change-set — refusing to proceed." >&2; exit 1; }
```

The envelope shape (provenance + ordered `operations[]`, each with `id`, `type`,
`before`, `after`, `rationale`, `risk`, and `money_movement: false`) is the M4-1
contract — see [`assets/changeset-contract.md`](../assets/changeset-contract.md).
Every monetary field is a **raw milliunit integer**; divide by 1000 only for display.

## Step 1b — Idempotency guard (cross-reference the audit log)

Before any user interaction, drop operations that were **already applied** on a prior
run. The M4-3 audit log is the source of truth: every real apply appended a record
carrying the operation's `id` and `result_status`. Read the applied op-ids and
exclude them from the loaded set, so **re-running after a partial apply never
re-applies an already-applied op** (the change-set `id` is stable precisely to make
apply idempotent on resume — contract §1).

```bash
# Applied op-ids = audit records for THIS proposal where the apply was real
# (dry_run=false) and the executor reported `applied` — its ONLY success status
# (assets/apply-executor.js STATUS.APPLIED; the rest are skipped-stale / blocked /
# error, so a "success" match would catch nothing). The proposal's `source` (its
# provenance run id) is the stable key every audit record for this proposal carries
# as run_id (the executor maps run_id := changeset.source), and `audit-log.sh run`
# scans EVERY monthly file — so a partial apply that straddled a month boundary
# (e.g. Jun 30 → Jul 1) is still seen. The `last` path reads only the current UTC
# month and would silently miss the prior month's applied ops.
RUN_ID="$(jq -r '.source' "$PROPOSAL")"
APPLIED_IDS="$(bash "${CLAUDE_PLUGIN_ROOT}/bin/audit-log.sh" run "$RUN_ID" 2>/dev/null \
  | jq -r 'select(.dry_run == false and .result_status == "applied") | .operation_id')"
```

Partition the proposal's operations into **already-applied** (id ∈ `$APPLIED_IDS`)
and **to-apply** (everything else). Show the human a one-line summary of what is being
skipped as already-applied **before** any prompt:

```text
↪︎ Skipping 3 op(s) already applied on a previous run (op-categorize-0007, op-allocate-0002, op-dedupe-0001).
   12 op(s) remain to review.
```

If **every** op is already applied, report "Everything in this proposal is already
applied — nothing to do." and exit. Otherwise continue with the to-apply set only.

## Step 2 — Group the operations into typed batches

Group the to-apply operations into coherent batches **by operation type** —
`categorize`, `allocate`, `delete_duplicate` (dedupe), `reconcile` — so the human
reviews them **one batch at a time, not as a 40-item flat list**. Preserve array
order within each batch (apply runs in array order; contract §1). Present the batch
roster up front:

```text
This proposal has 4 batches to review:
  1. Categorize   — 18 op(s)
  2. Allocate     —  6 op(s)
  3. Dedupe       —  3 op(s)   🚨 destructive (deletes)
  4. Reconcile    —  1 op(s)
```

Then walk the batches **one at a time** (Steps 3–6 per batch). **One approval = one
batch = one apply.** Never present an all-batches-at-once gate.

## Step 3 — Dry-run the batch and present the diff

For the current batch, run the M4-4 apply executor in **dry-run** (`dryRun: true`)
**before asking the human anything**, then render its result.

### 3a. Load the deferred YNAB tool schemas (boot-patience)

The YNAB MCP tools are almost always delivered as **deferred schemas**. Before the
first executor call (which uses the read tools for drift detection and, later, the
write tools for apply), load them with `ToolSearch`, using the family glob from the
SSoT — never an inlined concrete name:

```text
ToolSearch(query="select:mcp__plugin_workbench-ynab_ynab__ynab_*")
```

An `InputValidationError` means the schema **isn't loaded yet**, not that the server
is down — retry with brief sleeps (up to ~5 attempts at 2s, 4s, 8s, 16s) before
concluding failure. The MCP may take ~10s to boot (boot-patience, mirroring the
bujo-orchestrator). All YNAB calls use the plugin-namespaced
`mcp__plugin_workbench-ynab_ynab__` prefix; the concrete read/write tool names are
resolved at runtime from the single source of truth
[`skills/protocol/ynab-tools.md`](../skills/protocol/ynab-tools.md) — **never paste a
concrete `mcp__plugin_workbench-ynab_ynab__ynab_…` name into this command.**

### 3b. Invoke the executor in dry-run

Import the executor as a library and wire its ports to the real MCP + audit log (see
[`skills/apply-executor.md`](../skills/apply-executor.md) "Wiring the ports"). The
`toolMap` (op-type → namespaced mutating tool) is built by resolving each write-tool
name from the SSoT per the contract's operation → apply-tool table
([`assets/changeset-contract.md`](../assets/changeset-contract.md) §3) — resolved,
not inlined:

```js
const { applyChangeset } = require('<plugin-root>/assets/apply-executor');

const dry = await applyChangeset(batchChangeset, {
  activeBudgetId: ACTIVE_BUDGET_ID,
  dryRun: true,                 // SIMULATE — nothing mutates
  toolMap,                      // op-type → tool, resolved from the SSoT
  readLiveState,                // namespaced YNAB read ports
  applyOp,                      // namespaced YNAB write ports (unused in dry-run)
  audit,                        // bin/audit-log.sh append — dry-runs are audited too
});
// dry.results: [{ op_id, status, dry_run, detail: { simulated: true, diff: { before, after } } }, ...]
```

### 3c. Render the per-op diff table

For each op in the batch, present a readable **before → after** table. **Divide every
milliunit by 1000 for display** (`250000` → `$250.00`); the raw record keeps the
integer. Show the op's `rationale` and `risk` tag on each row, and flag the
executor's `status`:

| Op | Target | Before | After | Rationale | Risk |
|----|--------|--------|-------|-----------|------|
| op-categorize-0001 | txn `abc…` | _(uncategorized)_ | Groceries | matches grocery payee | low |
| op-allocate-0002 | Dining `2026-06` | $200.00 | $250.00 | overspent last month | medium |

- A `skipped-stale` op (drift detected by the executor — live state no longer matches
  the op's `before` snapshot) is shown **labelled `⏳ stale`**. Stale ops are excluded
  from the "apply the whole batch" option by default (Step 4b).
- **Step 3b — destructive ops** (`delete_duplicate`, `risk: destructive`) are visually
  flagged with a **🚨** prefix and listed separately. They require the stronger
  confirmation in Step 4 before any delete runs (M4-8 design intent).

## Step 4 — Three-options decision protocol (per batch)

### Step 4.0 — Guardrail gate (fail-closed; runs before the choice)

The M4-2 write-safety guardrail is **fail-closed** and runs **before** the human is
offered the choice below — and before any apply (Step 5). Run the **whole batch**
through it first, so any blocked op is surfaced *before* a choice is offered:

```js
const { evaluateChangeset } = require('<plugin-root>/assets/write-safety-guardrail');
const verdict = evaluateChangeset(batchChangeset, { activeBudgetId: ACTIVE_BUDGET_ID });
// verdict.verdict === 'pass' | 'block';  verdict.blocks === [ <block verdict>, ... ]
```

- If `verdict.verdict === 'block'`, **surface each blocked op with its full verdict**
  (`op_id`, `op_type`, `rule`, `reason`) so the human sees exactly what was refused and
  why, and **abort the apply for the blocked op(s)** — a batch with any block is **not**
  offered for approval as-is. Money-movement (a transfer signal, a proposed payee
  repoint, or a denied create/transfer tool) and any non-ledger operation are hard
  blocks: writes are **ledger-only** (categorize / allocate / dedupe / reconcile) and
  **never move real money**.
- **The command never calls the executor with `dry_run=false` past a guardrail block.**
  The executor enforces the same gate independently (it guardrails the batch and runs
  `evaluateTool` on every tool before dispatch, aborting the whole batch on any block),
  so the safety promise holds even if this surface is bypassed — but this command
  surfaces the verdict to the human rather than letting them approve into an abort.

### Step 4.1 — Present the three options

With the batch cleared by the guardrail (Step 4.0), present **exactly three options**
with a recommendation, and let the human decide — the command executes the chosen
option; no write happens before a choice is made:

```jsonc
AskUserQuestion({
  questions: [{
    question: "Batch 1 — Categorize (18 ops, 1 stale excluded). How do you want to apply it?",
    header: "Approve batch",
    multiSelect: false,
    options: [
      { label: "a) Apply the whole batch as-is [recommended]",
        description: "Apply all non-stale, non-blocked ops in this batch. Recommended when every op is low-risk and current. Stale ops are excluded by default." },
      { label: "b) Apply a subset / skip flagged ops",
        description: "Choose which ops to apply — e.g. skip the 🚨 destructive deletes or the medium-risk rows. I'll confirm the exact subset before applying." },
      { label: "c) Reject the batch",
        description: "Apply nothing from this batch and move to the next one. Nothing is written." }
    ]
  }]
})
```

**Recommend (a)** only when every op in the batch is low-risk and non-stale;
otherwise recommend (b) and name what to scrutinise. On **(b)**, gather the exact
op-id subset from the human (a second `AskUserQuestion` listing each op) and apply
only those. On **(c)**, write nothing and advance to the next batch.

### Step 4b — Stale ops are excluded from (a) by default

Ops the executor flagged `skipped-stale` are shown in the diff (Step 3c, labelled
`⏳ stale`) but are **excluded from option (a)'s apply set by default** — applying a
stale op would clobber a value that changed since the proposal was generated. The
human sees them labelled stale before deciding and can pull a specific one back in
only via the explicit subset of option (b).

### Step 4c — Stronger confirmation for destructive ops

If the approved set (from (a) or (b)) contains any **destructive** op (a
`delete_duplicate`), require a **second, explicit** confirmation naming the exact
records to be deleted before proceeding — batch approval alone is not enough (M4-8):

```jsonc
AskUserQuestion({
  questions: [{
    question: "🚨 This will DELETE 3 duplicate transaction(s): <list txn ids + amounts>. Deletes are irreversible. Confirm?",
    header: "Confirm delete",
    multiSelect: false,
    options: [
      { label: "Yes — delete these duplicates", description: "Permanently delete the listed duplicate transactions." },
      { label: "No — skip the deletes",         description: "Apply the rest of the approved set but skip every delete." }
    ]
  }]
})
```

On **No**, drop the destructive ops from the approved set and continue with the
remainder.

## Step 5 — Apply the approved ops (the only `dry_run=false` call)

Re-invoke the executor with **`dryRun: false`** for the **approved ops only** — never
the whole proposal, never the stale or skipped ops. This is the single place in the
entire plugin that performs a real YNAB write:

```js
const live = await applyChangeset(approvedChangeset, {
  activeBudgetId: ACTIVE_BUDGET_ID,
  dryRun: false,                // REAL apply — approved ops only
  toolMap, readLiveState, applyOp, audit,
});
```

The executor re-checks drift per op (a now-stale op is skipped, not clobbered),
dispatches the namespaced mutating tool for each clean op, and appends an audit record
for every attempt. After it returns, display the **audit-log summary** of what
**actually** applied (M4-3) — read it back from the log so the human sees the durable
record, not just the in-memory result:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/bin/audit-log.sh" last <N>   # the N ops just applied
```

Show, per op: `applied` / `skipped-stale` / `error`, with before → after (÷1000).

## Loop or finish

After resolving a batch (applied / subset / rejected), **loop to the next batch** and
repeat Steps 3–5 (the guardrail gate runs first, as Step 4.0). When every batch is
resolved, exit.

## Final summary

Print a clean summary across all batches:

```text
═══════════════════════════════════════════
  /workbench-ynab:ynab-apply — done
═══════════════════════════════════════════
  Proposal:          <proposal filename>
  Already applied:   3 op(s) skipped (idempotency guard)
  Batch 1 Categorize: 17 applied, 1 stale-skipped
  Batch 2 Allocate:    6 applied
  Batch 3 Dedupe:      rejected by user (0 applied)
  Batch 4 Reconcile:   1 applied
  Blocked by guardrail: 0
  Audit log:         ~/.claude/plugins/data/workbench-ynab-claude-workbench/audit/
═══════════════════════════════════════════
```

## Notes — boundaries & invariants

- **Exclusive write path.** This command is the **only** interactive path that sets
  `dry_run=false`. No other skill, hook, or scheduled task may call the write executor
  with `dry_run=false`. Every real write flows through the approval loop above.
- **Config split.** The Keychain holds the token; `config.json` (read here via
  `bin/config.sh`) holds budget id, proposal path, and the rest. The vendored MCP
  receives **only** the token via `bin/launcher.sh` — it never reads `config.json`.
- **Money is always milliunits.** Every monetary value flows through verbatim as a raw
  integer; only the **display** divides by 1000. The audit log keeps the exact integer.
- **One approval = one batch = one apply.** Approval is per-batch; re-running after a
  partial apply detects already-applied ops via the audit log (Step 1b) and never
  re-applies them.
- **Fail-closed safety.** The schema makes a money-moving change-set unrepresentable
  and the guardrail makes a money-moving apply impossible — both hold, and a guardrail
  block aborts before any `dry_run=false` call.
