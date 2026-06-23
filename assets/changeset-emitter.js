'use strict';

/**
 * Change-set proposal emitter for workbench-ynab write-back (M4-10).
 *
 * The post-processing step the read-only review runs AFTER its 12-section
 * analysis and BEFORE it exits: it turns the review's findings into a validated,
 * guardrail-checked change-set (assets/changeset-schema.json) and writes it as a
 * *proposal* file that `/ynab-apply` (M4-5) reads by default. Emitting a proposal
 * is a LOCAL FILE WRITE, never a YNAB mutation — the review stays strictly
 * read-only toward YNAB; this module calls no MCP tool at all.
 *
 * Pipeline (the AC order): assemble envelope from findings → schema-validate the
 * assembled change-set → assert `money_movement: false` → run every operation
 * through the M4-2 write-safety guardrail in CHECK-ONLY mode, DROPPING (with a
 * per-op note) any operation the guardrail would block → write the surviving
 * operations to the derived proposal path. A schema failure, a money_movement
 * failure, or an all-operations-blocked result writes NO file and is reported in
 * the structured result so the review can surface it.
 *
 * Design rules (mirroring assets/apply-executor.js, its M4 sibling):
 *  - PURE ORCHESTRATOR, INJECTED I/O. This module owns the mapping + validation +
 *    guardrail control flow but holds no filesystem coupling: the file write is an
 *    injected `writeFile(absPath, contents)` port, and the guardrail's
 *    per-operation check is injected too (default: the real M4-2 guardrail). That
 *    keeps every branch — including the drop and all-blocked paths — unit-testable
 *    offline with synthetic findings and a spy writer, never a real YNAB API and
 *    never the real filesystem.
 *  - IDS, NOT NAMES. The emitter maps findings whose YNAB ids the review already
 *    resolved (transaction / category / account); it never resolves an id itself,
 *    so the proposal a downstream apply handler reads carries resolved ids only.
 *  - MILLIUNITS THROUGHOUT. Monetary fields (`budgeted`, `amount`, balances) pass
 *    through verbatim as integer milliunits; the emitter never does arithmetic on
 *    an amount, so no float conversion can occur.
 *  - MONEY-SAFE BY CONSTRUCTION. `money_movement` is hard-set false and re-asserted;
 *    operation objects are built field-by-field against the schema's
 *    `additionalProperties: false` shapes, so a stray finding key can never smuggle
 *    a transfer signal into the emitted change-set.
 *
 * Usage as a library (the review skill wires the real writer via its file tool):
 *   const { emitProposal } = require('./assets/changeset-emitter');
 *   const result = await emitProposal(findings, {
 *     budgetId, budgetName, source,        // envelope provenance
 *     generatedAt, schemaVersion,          // optional; sensible defaults
 *     outDir,                              // resolved proposals dir (from config; not hard-coded here)
 *     date,                                // 'YYYY-MM-DD' → changeset-<date>.json
 *     writeFile: async (absPath, contents) => { ... },  // injected I/O
 *   });
 *   // result.written: boolean; result.path / result.reason / result.dropped / result.notes
 *
 * Usage as a CLI (real fs write; verdict JSON on stdout, diagnostics on stderr,
 * non-zero exit when no proposal is written):
 *   node assets/changeset-emitter.js --findings <findings.json> --out-dir <dir> \
 *     --date 2026-06-19 [--budget-id <id> --budget-name <name> --source <run>]
 */

const fs = require('fs');
const path = require('path');

const { validateChangeset } = require('./validate-changeset');
const { evaluateOperation: guardrailEvaluateOperation } = require('./write-safety-guardrail');

/** The change-set schema version this emitter produces (see changeset-contract.md §7). */
const SCHEMA_VERSION = '1.0.0';

/** The four finding buckets, in the order operations are emitted (matches the schema oneOf). */
const FINDING_TYPES = Object.freeze(['categorize', 'allocate', 'delete_duplicate', 'reconcile']);

/** Default risk per operation type. delete_duplicate is always destructive (schema const). */
const DEFAULT_RISK = Object.freeze({
  categorize: 'low',
  allocate: 'low',
  reconcile: 'medium',
});

/**
 * Top-level outcome reasons. `written` is true only for WRITTEN.
 * @type {Readonly<Record<string, string>>}
 */
const OUTCOME = Object.freeze({
  WRITTEN: 'written',
  NO_OPERATIONS: 'no_operations',
  SCHEMA_INVALID: 'schema_invalid',
  MONEY_MOVEMENT: 'money_movement_assertion_failed',
  ALL_BLOCKED: 'all_operations_blocked',
});

/** Copy only the named keys that are actually present on `src` (own keys), nulls included. */
function pick(src, keys) {
  const out = {};
  if (src === null || typeof src !== 'object') return out;
  for (const key of keys) {
    if (Object.prototype.hasOwnProperty.call(src, key)) out[key] = src[key];
  }
  return out;
}

/** A stable per-operation id: a finding's own `id`, else `op-<kebab-type>-NNNN`. */
function operationId(finding, type, seq) {
  if (typeof finding.id === 'string' && finding.id.length > 0) return finding.id;
  return `op-${type.replace(/_/g, '-')}-${String(seq).padStart(4, '0')}`;
}

/** Build a single typed operation from a finding, shaped to the schema (additionalProperties:false). */
function buildOperation(type, finding, budgetId, seq) {
  const base = { id: operationId(finding, type, seq), type, budget_id: budgetId };

  if (type === 'categorize') {
    const before = pick(finding.before, ['category_id', 'category_name']);
    if (!Object.prototype.hasOwnProperty.call(before, 'category_id')) before.category_id = null;
    return {
      ...base,
      transaction_id: finding.transaction_id,
      before,
      after: pick(finding.after, ['category_id', 'category_name']),
      rationale: finding.rationale,
      risk: finding.risk || DEFAULT_RISK.categorize,
    };
  }

  if (type === 'allocate') {
    return {
      ...base,
      category_id: finding.category_id,
      month: finding.month,
      before: pick(finding.before, ['budgeted']),
      after: pick(finding.after, ['budgeted']),
      rationale: finding.rationale,
      risk: finding.risk || DEFAULT_RISK.allocate,
    };
  }

  if (type === 'delete_duplicate') {
    return {
      ...base,
      transaction_id: finding.transaction_id,
      before: pick(finding.before, ['amount', 'date', 'payee_name', 'category_name', 'import_id']),
      after: { deleted: true },
      rationale: finding.rationale,
      risk: 'destructive', // schema const — never taken from the finding.
    };
  }

  // reconcile
  const op = {
    ...base,
    account_id: finding.account_id,
    before: pick(finding.before, ['cleared_balance', 'reconciled_balance', 'cleared']),
    after: pick(finding.after, ['reconciled_balance', 'cleared']),
    rationale: finding.rationale,
    risk: finding.risk || DEFAULT_RISK.reconcile,
  };
  if (Array.isArray(finding.transaction_ids)) op.transaction_ids = finding.transaction_ids;
  return op;
}

/**
 * Map a findings object to an ordered array of typed operations. Findings are read
 * from the four buckets (`categorize` / `allocate` / `delete_duplicate` /
 * `reconcile`) in schema order; each entry carries the ids the review already
 * resolved. Per-type sequence numbers drive deterministic operation ids.
 * @param {object} findings
 * @param {string} budgetId
 * @returns {Array<object>}
 */
function mapFindingsToOperations(findings, budgetId) {
  const operations = [];
  for (const type of FINDING_TYPES) {
    const bucket = findings == null ? undefined : findings[type];
    if (!Array.isArray(bucket)) continue;
    bucket.forEach((finding, i) => {
      operations.push(buildOperation(type, finding || {}, budgetId, i + 1));
    });
  }
  return operations;
}

/**
 * Assemble the change-set envelope from findings. `money_movement` is hard-set
 * false; the operations array is built by mapFindingsToOperations.
 * @returns {object} the assembled change-set (not yet validated or guardrail-checked).
 */
function assembleChangeset(findings, { budgetId, budgetName, source, generatedAt, schemaVersion } = {}) {
  return {
    schema_version: schemaVersion || SCHEMA_VERSION,
    generated_at: generatedAt || new Date().toISOString(),
    budget_id: budgetId,
    budget_name: budgetName,
    source,
    money_movement: false,
    operations: mapFindingsToOperations(findings, budgetId),
  };
}

/** The proposal filename for a given date. Rejects a malformed date fail-closed. */
function proposalFilename(date) {
  if (typeof date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(date)) {
    throw new TypeError(`emitProposal requires a YYYY-MM-DD date for the proposal filename, got ${JSON.stringify(date)}`);
  }
  return `changeset-${date}.json`;
}

/**
 * Emit a validated change-set proposal from review findings.
 *
 * Dry toward YNAB by definition: calls no MCP tool, only the injected `writeFile`
 * port (and only when a non-empty, valid, fully-passing change-set survives the
 * pipeline). Returns a structured result the review surfaces in its report.
 *
 * @param {object} findings the four finding buckets (categorize/allocate/delete_duplicate/reconcile).
 * @param {object} options
 * @param {string} options.budgetId   envelope budget id (every op targets it).
 * @param {string} options.budgetName envelope budget name (display/audit).
 * @param {string} options.source     provenance: the review run id, or "manual".
 * @param {string} [options.generatedAt] ISO timestamp; defaults to now.
 * @param {string} [options.schemaVersion] defaults to SCHEMA_VERSION.
 * @param {string} options.outDir     resolved proposals directory (from config; never hard-coded here).
 * @param {string} options.date       'YYYY-MM-DD' → changeset-<date>.json.
 * @param {(absPath:string, contents:string)=>(void|Promise<void>)} options.writeFile injected I/O port.
 * @param {(op:object, ctx:{activeBudgetId:string})=>{verdict:string}} [options.evaluateOperation]
 *   the per-op guardrail check; defaults to the real M4-2 guardrail. Injected so the
 *   drop / all-blocked branches are unit-testable in isolation.
 * @returns {Promise<{written:boolean, reason:string, path?:string, changeset:object,
 *   dropped:Array<{op_id:string|null, op_type:string|null, rule:string, reason:string}>,
 *   notes:string[], validation?:object}>}
 */
async function emitProposal(findings, options = {}) {
  const {
    budgetId, budgetName, source, generatedAt, schemaVersion,
    outDir, date, writeFile,
    evaluateOperation = guardrailEvaluateOperation,
  } = options;

  // Fail fast on a misconfigured caller — these are mechanical preconditions
  // independent of the findings (budget/name/source are data and flow through to
  // schema validation instead).
  if (typeof writeFile !== 'function') {
    throw new TypeError('emitProposal requires a writeFile(absPath, contents) function');
  }
  if (typeof outDir !== 'string' || outDir.length === 0) {
    throw new TypeError('emitProposal requires a non-empty outDir (the resolved proposals directory)');
  }
  const filename = proposalFilename(date); // throws on a malformed date.
  const notes = [];

  const changeset = assembleChangeset(findings, { budgetId, budgetName, source, generatedAt, schemaVersion });

  // No findings produced any operation — a valid "nothing to propose" outcome.
  if (changeset.operations.length === 0) {
    notes.push('No review findings produced any operations; no proposal written.');
    return { written: false, reason: OUTCOME.NO_OPERATIONS, changeset, dropped: [], notes };
  }

  // 1. Schema-validate the assembled change-set BEFORE any file is written.
  const validation = validateChangeset(changeset);
  if (!validation.valid) {
    notes.push(`Assembled change-set failed M4-1 schema validation (${validation.errors.length} error(s)); no proposal written.`);
    return { written: false, reason: OUTCOME.SCHEMA_INVALID, changeset, dropped: [], notes, validation };
  }

  // 2. Assert the money_movement invariant on the validated change-set.
  if (changeset.money_movement !== false) {
    notes.push(`money_movement is not false (got ${JSON.stringify(changeset.money_movement)}); no proposal written.`);
    return { written: false, reason: OUTCOME.MONEY_MOVEMENT, changeset, dropped: [], notes };
  }

  // 3. Guardrail, check-only: drop every operation the M4-2 guardrail would block,
  //    each with a per-op note; keep the rest.
  const kept = [];
  const dropped = [];
  for (const op of changeset.operations) {
    const verdict = evaluateOperation(op, { activeBudgetId: budgetId });
    if (verdict && verdict.verdict === 'block') {
      const record = { op_id: op.id == null ? null : op.id, op_type: op.type == null ? null : op.type, rule: verdict.rule, reason: verdict.reason };
      dropped.push(record);
      notes.push(`Dropped operation ${record.op_id} (${record.op_type}): ${verdict.reason}`);
    } else {
      kept.push(op);
    }
  }

  // 4. Every operation was blocked — write no file (nothing safely appliable).
  if (kept.length === 0) {
    notes.push('Every proposed operation was blocked by the write-safety guardrail; no proposal written.');
    return { written: false, reason: OUTCOME.ALL_BLOCKED, changeset, dropped, notes };
  }

  // 5. Write the surviving operations to the derived proposal path.
  const finalChangeset = { ...changeset, operations: kept };
  const absPath = path.join(outDir, filename);
  await writeFile(absPath, `${JSON.stringify(finalChangeset, null, 2)}\n`);
  notes.push(`Proposal written to ${absPath}${dropped.length ? ` (${dropped.length} operation(s) dropped by the guardrail)` : ''}.`);
  return { written: true, reason: OUTCOME.WRITTEN, path: absPath, changeset: finalChangeset, dropped, notes };
}

module.exports = {
  SCHEMA_VERSION,
  FINDING_TYPES,
  DEFAULT_RISK,
  OUTCOME,
  mapFindingsToOperations,
  assembleChangeset,
  proposalFilename,
  emitProposal,
};

// CLI entry point: read a findings JSON file, emit the proposal to a real file,
// print the structured result JSON on stdout, diagnostics on stderr, and exit
// non-zero when no proposal is written.
if (require.main === module) {
  const USAGE =
    'usage: node changeset-emitter.js --findings <file> --out-dir <dir> --date <YYYY-MM-DD> ' +
    '[--budget-id <id>] [--budget-name <name>] [--source <run>] [--generated-at <iso>] [--schema-version <v>]\n';
  const argv = process.argv.slice(2);
  const flags = {};
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i];
    if (!key.startsWith('--')) { process.stderr.write(USAGE); process.exit(2); }
    const value = argv[i + 1];
    if (value === undefined || value.startsWith('--')) { process.stderr.write(USAGE); process.stderr.write(`error: ${key} requires a value.\n`); process.exit(2); }
    flags[key.slice(2)] = value;
    i += 1;
  }

  if (!flags.findings || !flags['out-dir'] || !flags.date) {
    process.stderr.write(USAGE);
    process.stderr.write('error: --findings, --out-dir, and --date are required.\n');
    process.exit(2);
  }

  let findingsFile;
  try {
    findingsFile = JSON.parse(fs.readFileSync(flags.findings, 'utf8'));
  } catch (err) {
    process.stderr.write(`could not read/parse ${flags.findings}: ${err.message}\n`);
    process.exit(2);
  }

  // The findings file may carry a `meta` block; explicit flags override it.
  const meta = (findingsFile && typeof findingsFile.meta === 'object' && findingsFile.meta) || {};
  const writeFile = (absPath, contents) => {
    fs.mkdirSync(path.dirname(absPath), { recursive: true });
    fs.writeFileSync(absPath, contents);
  };

  emitProposal(findingsFile, {
    budgetId: flags['budget-id'] || meta.budget_id,
    budgetName: flags['budget-name'] || meta.budget_name,
    source: flags.source || meta.source,
    generatedAt: flags['generated-at'] || meta.generated_at,
    schemaVersion: flags['schema-version'] || meta.schema_version,
    outDir: flags['out-dir'],
    date: flags.date,
    writeFile,
  }).then((result) => {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    if (result.written) {
      process.stderr.write(`WROTE: ${result.path}\n`);
      process.exit(0);
    }
    process.stderr.write(`NO PROPOSAL (${result.reason}): see notes.\n`);
    process.exit(1);
  }).catch((err) => {
    process.stderr.write(`emit failed: ${err.message}\n`);
    process.exit(2);
  });
}
