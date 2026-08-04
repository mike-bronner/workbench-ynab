'use strict';

/**
 * Shared, fail-closed write-tool resolution for the M4 write paths (issue #216).
 *
 * Every write path resolves its namespaced YNAB tool from the guardrail's exported
 * `ALLOWED_TOOLS` by SUFFIX rather than hard-coding a concrete
 * `mcp__plugin_workbench-ynab_ynab__*` name — that is the swap-ready
 * single-source-of-truth invariant (issue #87, `bin/check-tool-name-sources.sh`).
 * Suffix resolution is the right call, but the obvious spelling of it is unsafe:
 *
 *     const tool = ALLOWED_TOOLS.find((t) => t.endsWith('_update_transaction'));
 *
 * `.find()` returns the FIRST match and `undefined` for none. So a future allow-list
 * entry that happens to share a suffix (`..._bulk_update_transaction` shares
 * `_update_transaction`) would silently route a WRITE to whichever tool sorted first,
 * and an allow-list that lost the entry entirely would resolve `undefined` — both
 * fail-OPEN failures on the paths that mutate the user's ledger. Issue #151 closed
 * that hole on the irreversible delete path; this module is the same assertion
 * promoted to a shared primitive so every handler resolves under one contract
 * instead of re-deriving (or forgetting) it per site.
 *
 * FAIL-CLOSED, ALWAYS. `resolveUniqueTool` returns a tool name only when the suffix
 * matches EXACTLY ONE entry. Zero matches and two-or-more matches both throw — an
 * ambiguous or missing write tool is never resolved to a guess, and the throw names
 * the suffix plus every colliding tool so the allow-list edit that caused it is
 * obvious from the message alone.
 *
 * EXACT SUFFIX, NOT SUBSTRING. Matching is `String.prototype.endsWith`, which is an
 * anchored suffix test — NOT a substring scan. That distinction is load-bearing for
 * the categorize path, whose two suffixes nest: `_update_transaction` is a substring
 * of `_update_transactions`. A substring (`includes`) match would make the singular
 * suffix match the plural tool too, and the collision would then either throw
 * spuriously or — with `.find()` — resolve a BULK tool for a single-transaction
 * write. `endsWith` matches only the singular, because the plural ends in `s`. Tests
 * pin both directions on an allow-list holding both tools, in both array orders, so
 * a future switch to a substring match fails loudly instead of quietly mis-routing.
 *
 * DEPENDENCY-FREE by design (like `write-error.js` / `transaction-shape.js`): pure
 * string inspection, no Ajv, no MCP coupling, no I/O. It can never itself be the
 * thing that fails open, and it gates offline in CI as
 * `tests/unit/resolve-tool.test.mjs`.
 *
 * Usage (a write path, at module load or per registration call):
 *   const { resolveUniqueTool } = require('./resolve-tool');
 *   const { ALLOWED_TOOLS } = require('./write-safety-guardrail');
 *   const TOOL = resolveUniqueTool(ALLOWED_TOOLS, '_delete_transaction', {
 *     context: 'delete-duplicate',
 *     subject: 'the destructive delete tool',
 *   });
 */

/**
 * Resolve the ONE tool on an allow-list whose name ends with `suffix`, asserting
 * uniqueness and failing closed on anything else.
 *
 * @param {readonly string[]} allowedTools the guardrail's exported allow-list. A
 *   non-array (including `undefined`) is treated as empty — which means zero
 *   matches, which throws; it is never silently tolerated.
 * @param {string} suffix the anchored suffix identifying the tool, e.g.
 *   `'_delete_transaction'`. Must be a non-empty string: an empty suffix would
 *   `endsWith`-match every entry, so it is rejected outright rather than allowed to
 *   masquerade as an ordinary ambiguity.
 * @param {{context?: string, subject?: string}} [labels] diagnostic labels for the
 *   thrown message — `context` is the calling module (message prefix), `subject`
 *   names what could not be resolved. Defaults keep the message intelligible when a
 *   caller omits them.
 * @returns {string} the single matching tool name.
 * @throws {Error} when `suffix` is not a non-empty string, or when it matches zero
 *   or more than one tool.
 */
function resolveUniqueTool(allowedTools, suffix, labels = {}) {
  const { context = 'tool resolution', subject = 'the write tool' } = labels;

  // A bad suffix is a programming error, not an allow-list problem — say so
  // distinctly instead of reporting it as "found 5" and sending the reader to the
  // wrong file.
  if (typeof suffix !== 'string' || suffix === '') {
    throw new Error(
      `${context}: tool suffix must be a non-empty string, got ${JSON.stringify(suffix)}`
      + ` — refusing to resolve ${subject} (fail-closed).`,
    );
  }

  const matches = (Array.isArray(allowedTools) ? allowedTools : [])
    .filter((t) => typeof t === 'string' && t.endsWith(suffix));

  if (matches.length !== 1) {
    throw new Error(
      `${context}: expected exactly ONE *${suffix} tool on the guardrail allow-list, found ${matches.length}`
      + `${matches.length > 0 ? ` (${matches.join(', ')})` : ''} — refusing to resolve ${subject} (fail-closed).`,
    );
  }

  return matches[0];
}

module.exports = {
  resolveUniqueTool,
};
