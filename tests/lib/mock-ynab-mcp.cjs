'use strict';

/**
 * Mock / sandbox YNAB MCP for the M4 write-back test harness (issue #55, M4-12).
 *
 * An IN-PROCESS mock — deliberately NOT a stdio MCP server. The apply executor
 * (M4-4) and every write-path handler (M4-6..M4-9) take their I/O as injected
 * ports (`callTool`, `readLiveState`, `applyOp`, `authPreflight`), so tests wire
 * those ports straight to this module's `callTool(name, args)` — no JSON-RPC
 * transport, no child process, no stdout/stderr discipline to get wrong, and it
 * runs under the repo's no-`node_modules` constraint (docs/testing.md). Handler
 * and executor code is IDENTICAL in test and prod because the seam is the port,
 * and every tool id this mock speaks is the same fully NAMESPACED id the
 * vendored bundle exposes. How tests point the executor at the mock vs the
 * vendored bundle is documented in docs/testing.md ("Mock YNAB MCP").
 *
 * TOOL IDS ARE DERIVED, NEVER HARD-CODED (issue #87, bin/check-tool-name-sources.sh):
 * the namespace prefix is sliced off the guardrail's exported `ALLOWED_TOOLS`
 * (an allowlisted swap consumer), and read-tool ids are prefix + bare suffix.
 * A namespace swap that edits the SSoT + guardrail propagates here with no edit.
 *
 * WHAT IT IMPLEMENTS
 *  - Reads:  ynab_list_{budgets,transactions,categories,accounts,payees},
 *            ynab_get_{month,transaction,category,account} — served from an
 *            in-memory fixture budget (tests/fixtures/mock-budget.json).
 *  - Writes: ynab_update_transaction(s), ynab_update_category,
 *            ynab_delete_transaction, ynab_reconcile_account — each MUTATES the
 *            in-memory state, so a read after a write reflects the change
 *            (drift / idempotency assertions).
 *  - NEVER-ALLOW: every tool on the guardrail's DENIED_TOOLS list (the
 *            create/transfer/payment family) THROWS and records the attempt in
 *            `neverAllowAttempts` — the never-move-money invariant, end to end.
 *  - Call log: EVERY invocation (name + args) is recorded in `callLog` before
 *            dispatch — including unknown and never-allow tools — so tests can
 *            assert exactly which tools fired.
 *  - Drift injection: `injectDrift(mutate)` hands the raw in-memory budget to
 *            the test between proposal-generation and apply, so M4-4 drift
 *            detection and M4-8 stale-victim aborts are exercisable.
 *
 * FIDELITY NOTES
 *  - All monetary amounts are integer MILLIUNITS, compared/stored verbatim —
 *    the mock never does float arithmetic on an amount.
 *  - Account aggregate balances (cleared_balance etc.) are fixture-pinned
 *    fields, NOT recomputed from transactions; the fixture is a window onto a
 *    ledger, not the whole ledger. The two exceptions mirror the real tools:
 *    `ynab_update_category` moves the month's `to_be_budgeted` by the budgeted
 *    delta, and `ynab_reconcile_account` locks `reconciled_balance`.
 *  - Reads carry the SHAPE-EVIDENCE fields (`subtransactions`,
 *    `transfer_account_id`, `transfer_transaction_id`) verbatim, so the
 *    handlers' live-read hard blocks (#49) are exercisable even when an op's
 *    `before` snapshot omits them.
 *  - `ynab_reconcile_account` REFUSES a balance that differs from the account's
 *    live `cleared_balance`: the real tool would cover the gap by CREATING a
 *    balance-adjustment transaction, and creation is exactly what this sandbox
 *    hard-bans — the reconcile handler asserts equality before calling, so a
 *    mismatch here is a harness bug surfacing loudly, never silently.
 *
 * Usage:
 *   const { createMockYnab } = require('../../tests/lib/mock-ynab-mcp.cjs');
 *   const fixture = JSON.parse(fs.readFileSync('tests/fixtures/mock-budget.json', 'utf8'));
 *   const mock = createMockYnab(fixture);
 *   await mock.callTool(mock.tools.get_transaction, { budget_id, transaction_id });
 *   mock.callLog                    // [{ tool, args }, ...] every call, in order
 *   mock.callsTo(mock.tools.update_transaction)  // just that tool's calls
 *   mock.neverAllowAttempts         // recorded never-allow violations
 *   mock.injectDrift((budget) => { ... })        // mutate state between phases
 *
 * CommonJS (.cjs) on purpose: require()-able from the assets/test CJS suites and
 * import-able from the tests/unit ESM suites. Zero third-party dependencies.
 */

const { ALLOWED_TOOLS, DENIED_TOOLS } = require('../../assets/write-safety-guardrail.js');

// Derive the namespace prefix from the guardrail's allow-list (an allowlisted
// tool-name source) — never a hard-coded concrete name in this file.
const ANCHOR_SUFFIX = 'ynab_update_transaction';
const ANCHOR = ALLOWED_TOOLS.find((t) => t.endsWith(`_${ANCHOR_SUFFIX}`));
const NS_PREFIX = ANCHOR.slice(0, ANCHOR.lastIndexOf(ANCHOR_SUFFIX));

const ns = (suffix) => `${NS_PREFIX}${suffix}`;

/**
 * Every tool this mock serves, keyed by short name. Read ids are derived
 * (prefix + suffix); mutation ids are resolved from the guardrail allow-list so
 * they are string-identical to what the real dispatch path is permitted to call.
 * `list_budgets` is included beyond the executor's own reads because the
 * documented `authPreflight` wiring (skills/apply-executor.md) calls it.
 * @type {Readonly<Record<string, string>>}
 */
const TOOLS = Object.freeze({
  // reads
  list_budgets: ns('ynab_list_budgets'),
  list_transactions: ns('ynab_list_transactions'),
  list_categories: ns('ynab_list_categories'),
  list_accounts: ns('ynab_list_accounts'),
  list_payees: ns('ynab_list_payees'),
  get_month: ns('ynab_get_month'),
  get_transaction: ns('ynab_get_transaction'),
  get_category: ns('ynab_get_category'),
  get_account: ns('ynab_get_account'),
  // mutations (resolved from the guardrail allow-list by suffix)
  update_transaction: ALLOWED_TOOLS.find((t) => t.endsWith('_update_transaction')),
  update_transactions: ALLOWED_TOOLS.find((t) => t.endsWith('_update_transactions')),
  update_category: ALLOWED_TOOLS.find((t) => t.endsWith('_update_category')),
  delete_transaction: ALLOWED_TOOLS.find((t) => t.endsWith('_delete_transaction')),
  reconcile_account: ALLOWED_TOOLS.find((t) => t.endsWith('_reconcile_account')),
});

/** The read-tool ids. @type {ReadonlyArray<string>} */
const READ_TOOL_IDS = Object.freeze([
  TOOLS.list_budgets, TOOLS.list_transactions, TOOLS.list_categories,
  TOOLS.list_accounts, TOOLS.list_payees, TOOLS.get_month,
  TOOLS.get_transaction, TOOLS.get_category, TOOLS.get_account,
]);

/** The mutation-tool ids (the guardrail's ledger-only allow-list, verbatim). */
const MUTATION_TOOL_IDS = Object.freeze([
  TOOLS.update_transaction, TOOLS.update_transactions, TOOLS.update_category,
  TOOLS.delete_transaction, TOOLS.reconcile_account,
]);

/** The never-allow ids — the guardrail's deny-list, verbatim. */
const NEVER_ALLOW_TOOL_IDS = DENIED_TOOLS;

const clone = (x) => JSON.parse(JSON.stringify(x));

/** Throw an Error carrying an HTTP-ish status, the shape real MCP ports surface. */
function httpError(status, message) {
  return Object.assign(new Error(message), { status });
}

/** Fields ynab_update_transaction(s) may change in this mock — field-isolated. */
const UPDATABLE_TXN_FIELDS = ['category_id', 'memo', 'cleared', 'approved'];

/**
 * Build one mock instance around a deep-cloned fixture budget.
 * @param {object} fixture parsed tests/fixtures/mock-budget.json —
 *   `{ data: { budget: { id, name, accounts, categories, payees, months, transactions } } }`.
 */
function createMockYnab(fixture) {
  if (!fixture || !fixture.data || !fixture.data.budget) {
    throw new TypeError('createMockYnab requires a YNAB-shaped fixture: { data: { budget: { ... } } }');
  }
  const budget = clone(fixture.data.budget);
  const callLog = [];
  const neverAllowAttempts = [];

  const requireBudget = (args) => {
    if (!args || args.budget_id !== budget.id) {
      throw httpError(404, `unknown budget_id: ${args && args.budget_id} (mock serves ${budget.id})`);
    }
  };
  const findTxn = (id) => budget.transactions.find((t) => t.id === id);
  const findCategory = (id) => budget.categories.find((c) => c.id === id);
  const findAccount = (id) => budget.accounts.find((a) => a.id === id);
  const findMonth = (month) => budget.months.find((m) => m.month === month);
  const monthCategory = (month, categoryId) => {
    const m = findMonth(month);
    return m ? m.categories.find((c) => c.id === categoryId) : undefined;
  };

  /** Apply the field-isolated updatable fields of `patch` to a stored transaction. */
  const patchTxn = (txn, patch) => {
    for (const field of UPDATABLE_TXN_FIELDS) {
      if (!Object.prototype.hasOwnProperty.call(patch, field)) continue;
      txn[field] = patch[field];
      if (field === 'category_id') {
        const cat = patch.category_id == null ? null : findCategory(patch.category_id);
        if (patch.category_id != null && !cat) {
          throw httpError(404, `unknown category_id: ${patch.category_id}`);
        }
        txn.category_name = cat ? cat.name : null;
      }
    }
  };

  const handlers = {
    // --- reads --------------------------------------------------------------
    [TOOLS.list_budgets]: () => ({ budgets: [{ id: budget.id, name: budget.name }] }),
    [TOOLS.list_accounts]: (args) => {
      requireBudget(args);
      return { accounts: clone(budget.accounts) };
    },
    [TOOLS.list_categories]: (args) => {
      requireBudget(args);
      return { categories: clone(budget.categories) };
    },
    [TOOLS.list_payees]: (args) => {
      requireBudget(args);
      return { payees: clone(budget.payees) };
    },
    [TOOLS.list_transactions]: (args) => {
      requireBudget(args);
      return { transactions: clone(budget.transactions.filter((t) => !t.deleted)) };
    },
    [TOOLS.get_month]: (args) => {
      requireBudget(args);
      const m = findMonth(args.month);
      if (!m) throw httpError(404, `unknown month: ${args.month}`);
      return { month: clone(m) };
    },
    [TOOLS.get_transaction]: (args) => {
      requireBudget(args);
      const txn = findTxn(args.transaction_id);
      if (!txn) throw httpError(404, `unknown transaction_id: ${args.transaction_id}`);
      return { transaction: clone(txn) };
    },
    [TOOLS.get_category]: (args) => {
      requireBudget(args);
      const cat = findCategory(args.category_id);
      if (!cat) throw httpError(404, `unknown category_id: ${args.category_id}`);
      const out = clone(cat);
      if (args.month != null) {
        const mc = monthCategory(args.month, args.category_id);
        if (!mc) throw httpError(404, `category ${args.category_id} has no record for month ${args.month}`);
        out.budgeted = mc.budgeted;
      }
      return { category: out };
    },
    [TOOLS.get_account]: (args) => {
      requireBudget(args);
      const account = findAccount(args.account_id);
      if (!account) throw httpError(404, `unknown account_id: ${args.account_id}`);
      return { account: clone(account) };
    },

    // --- mutations (update in-memory state; reads-after-write reflect them) --
    [TOOLS.update_transaction]: (args) => {
      requireBudget(args);
      const txn = findTxn(args.transaction_id);
      if (!txn || txn.deleted) throw httpError(404, `unknown transaction_id: ${args.transaction_id}`);
      patchTxn(txn, args);
      return { transaction: clone(txn) };
    },
    [TOOLS.update_transactions]: (args) => {
      requireBudget(args);
      const entries = Array.isArray(args.transactions) ? args.transactions : [];
      // The REAL vendored bulk shape: per-entry results keyed by request_index;
      // a resolved call is not proof every entry applied (fail-closed reading).
      const results = entries.map((entry, i) => {
        const txn = entry && findTxn(entry.id);
        if (!txn || txn.deleted) {
          return { request_index: i, status: 'failed', transaction_id: entry ? entry.id : null, error: 'unknown transaction id' };
        }
        patchTxn(txn, entry);
        return { request_index: i, status: 'updated', transaction_id: txn.id };
      });
      const failed = results.filter((r) => r.status === 'failed').length;
      return {
        success: failed === 0,
        summary: { total_requested: entries.length, updated: entries.length - failed, failed },
        results,
      };
    },
    [TOOLS.update_category]: (args) => {
      requireBudget(args);
      const cat = findCategory(args.category_id);
      if (!cat) throw httpError(404, `unknown category_id: ${args.category_id}`);
      const mc = monthCategory(args.month, args.category_id);
      if (!mc) throw httpError(404, `category ${args.category_id} has no record for month ${args.month}`);
      if (!Number.isInteger(args.budgeted)) {
        throw httpError(400, `budgeted must be integer milliunits, got: ${args.budgeted}`);
      }
      // Mirror real YNAB month math: funding a category draws down Ready-to-Assign.
      const m = findMonth(args.month);
      m.to_be_budgeted -= (args.budgeted - mc.budgeted);
      mc.budgeted = args.budgeted;
      return { category: { ...clone(cat), budgeted: mc.budgeted } };
    },
    [TOOLS.delete_transaction]: (args) => {
      requireBudget(args);
      const txn = findTxn(args.transaction_id);
      if (!txn || txn.deleted) throw httpError(404, `unknown transaction_id: ${args.transaction_id}`);
      txn.deleted = true;
      return { transaction: clone(txn) };
    },
    [TOOLS.reconcile_account]: (args) => {
      const account = findAccount(args.account_id);
      if (!account) throw httpError(404, `unknown account_id: ${args.account_id}`);
      if (args.balance !== account.cleared_balance) {
        // The real tool would CREATE a balance-adjustment transaction to cover
        // the gap — creation is banned in this sandbox, so refuse loudly.
        throw httpError(
          409,
          `reconcile balance ${args.balance} != live cleared_balance ${account.cleared_balance}; `
          + 'the real tool would create a balance-adjustment transaction, which this sandbox never allows',
        );
      }
      let reconciled = 0;
      for (const txn of budget.transactions) {
        if (txn.account_id === account.id && !txn.deleted && txn.cleared === 'cleared') {
          txn.cleared = 'reconciled';
          reconciled += 1;
        }
      }
      account.reconciled_balance = args.balance;
      return { account: clone(account), reconciled_transaction_count: reconciled };
    },
  };

  /**
   * Invoke a tool by its fully namespaced id. Records EVERY call (name + args)
   * before dispatch; throws for a never-allow tool (recording the attempt) and
   * for any unknown id — a bare / mis-namespaced name never resolves here.
   */
  async function callTool(name, args) {
    callLog.push({ tool: name, args: args === undefined ? undefined : clone(args) });
    if (NEVER_ALLOW_TOOL_IDS.includes(name)) {
      neverAllowAttempts.push({ tool: name, args: args === undefined ? undefined : clone(args) });
      throw new Error(`never-allow tool invoked in the sandbox: ${name} — the never-move-money invariant forbids every create/transfer/payment tool`);
    }
    const handler = handlers[name];
    if (!handler) throw new Error(`unknown tool: ${name} — the mock speaks only the namespaced ids the vendored bundle exposes`);
    return handler(args);
  }

  return {
    tools: TOOLS,
    callTool,
    callLog,
    neverAllowAttempts,
    /** All recorded calls to one tool id. */
    callsTo: (toolId) => callLog.filter((c) => c.tool === toolId),
    /** Mutate the in-memory budget between phases (drift / stale-victim tests). */
    injectDrift: (mutate) => { mutate(budget); },
    /** Direct read access to the live in-memory budget for state assertions. */
    budget,
  };
}

module.exports = {
  NS_PREFIX,
  TOOLS,
  READ_TOOL_IDS,
  MUTATION_TOOL_IDS,
  NEVER_ALLOW_TOOL_IDS,
  createMockYnab,
};
