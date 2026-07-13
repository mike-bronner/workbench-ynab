'use strict';

/**
 * Write-path error classification for the M4 apply executor (GAP-8, issue #50).
 *
 * When a write-path port (the auth preflight, `readLiveState`, or `applyOp`)
 * throws, the executor must decide TWO things from the failure:
 *   1. WHAT class of failure it is — so the audit trail records a precise
 *      `error_class`, and the executor knows whether to ABORT the whole batch
 *      (an auth failure means the token itself is bad) or record a per-op error
 *      and CONTINUE (a single-op data error, a rate limit, an indeterminate 5xx).
 *   2. WHETHER the mutation landed — so a later idempotent resume (#48) can tell
 *      a definitely-not-applied op (YNAB rejected it, safe to re-apply) from an
 *      indeterminate one (a network timeout mid-mutation — must re-verify against
 *      live YNAB before touching it).
 *
 * The classification is derived from an HTTP-like status pulled off the thrown
 * value. The executor's ports are INJECTED by the agent runtime (the MCP wiring),
 * and a thrown MCP/HTTP error can surface its status in several shapes, so the
 * extractor is deliberately defensive — a thrown value crossing back from an
 * external API is a trust boundary. Structured fields are authoritative; a status
 * token in the message is only a last resort.
 *
 * Dependency-free by design (no Ajv, no MCP coupling): it is pure and so gates in
 * CI as `tests/unit/write-error.test.mjs`, unlike the Ajv-backed executor whose
 * integration tests need `npm --prefix assets install` and run only locally.
 */

/**
 * The four failure classes an errored write op is stamped with in the audit log.
 * Exactly these four values — the contract the idempotent-resume design (#48)
 * reasons against.
 * @type {Readonly<Record<string, string>>}
 */
const ERROR_CLASS = Object.freeze({
  AUTH_REVOKED: 'auth_revoked', // HTTP 401 — token revoked, expired, or invalid.
  INSUFFICIENT_SCOPE: 'insufficient_scope', // HTTP 403 — token lacks write scope.
  RATE_LIMITED: 'rate_limited', // HTTP 429 — too many requests.
  UNKNOWN: 'unknown', // anything else: a 4xx data error, a 5xx, or a statusless network failure.
});

/**
 * Whether the mutation is known NOT to have applied, or whether that is
 * indeterminate. A definite client-side rejection (4xx) means YNAB received and
 * refused the call, so nothing changed → `not_applied`. A 5xx or a statusless
 * network/timeout error is indeterminate — the mutation may have landed
 * server-side before the failure surfaced → `unknown`.
 * @type {Readonly<Record<string, string>>}
 */
const APPLIED_STATE = Object.freeze({
  NOT_APPLIED: 'not_applied',
  UNKNOWN: 'unknown',
});

/**
 * The two classes that mean the TOKEN itself is bad — continuing the batch would
 * just fail every remaining op the same way, and each retry is a wasted call
 * against a dead credential. These trigger the abort-whole-batch policy.
 * @type {ReadonlyArray<string>}
 */
const AUTH_FAILURE_CLASSES = Object.freeze([
  ERROR_CLASS.AUTH_REVOKED,
  ERROR_CLASS.INSUFFICIENT_SCOPE,
]);

/** Whether an `error_class` is an auth failure (→ abort the whole batch). */
function isAuthFailure(errorClass) {
  return AUTH_FAILURE_CLASSES.includes(errorClass);
}

/** JSON.stringify that never throws (a circular envelope yields ''), for text scanning. */
function safeStringify(value) {
  try {
    return JSON.stringify(value);
  } catch {
    return '';
  }
}

/**
 * Recover an HTTP status (100–599) from a free-text blob — the last resort when no
 * structured field carries one. Two passes, most-confident first:
 *   1. an explicit HTTP-adjacent token — `(HTTP 401)`, `HTTP/500` — which the vendored
 *      MCP embeds in its error envelope, so it is authoritative here.
 *   2. a bare 4xx/5xx token, but ONLY when it is NOT part of a money amount: a leading
 *      currency symbol / digit / dot, or a trailing `.<digit>`, disqualifies it — so a
 *      coincidental "$450.00" is never misread as HTTP 450 (a false `not_applied` on the
 *      resume path, #48). Real vendor prose like "429 Too Many Requests" still resolves.
 * @param {string} text
 * @returns {number|null}
 */
function statusFromText(text) {
  const http = text.match(/\bHTTP[\s/]?(\d{3})\b/i);
  if (http) {
    const n = Number(http[1]);
    if (n >= 100 && n <= 599) return n;
  }
  const bare = text.match(/(?<![$\d.])\b([45]\d\d)\b(?!\.\d)/);
  return bare ? Number(bare[1]) : null;
}

/**
 * Pull an integer HTTP status (100–599) off a thrown value, or null when none is
 * present (a network/timeout error carries no status). Structured fields win, in
 * priority order; then a status token in the error MESSAGE; then — for an error
 * thrown by throwOnErrorResult — one embedded in the retained MCP envelope
 * (`err.mcpResult`), so the status survives even when it is not the message's text.
 * @param {unknown} err
 * @returns {number|null}
 */
function extractStatus(err) {
  if (err == null || typeof err !== 'object') return null;
  const response = err.response && typeof err.response === 'object' ? err.response : {};
  const candidates = [err.status, err.statusCode, response.status, response.statusCode, err.code];
  for (const candidate of candidates) {
    const n = typeof candidate === 'string' ? Number(candidate) : candidate;
    if (Number.isInteger(n) && n >= 100 && n <= 599) return n;
  }
  const message = typeof err.message === 'string' ? err.message : '';
  const fromMessage = statusFromText(message);
  if (fromMessage != null) return fromMessage;
  return err.mcpResult != null ? statusFromText(safeStringify(err.mcpResult)) : null;
}

/**
 * Classify a thrown port error into the audit-trail shape.
 * @param {unknown} err
 * @returns {{error_class:string, applied_state:string, status:number|null}}
 */
function classifyError(err) {
  const status = extractStatus(err);
  let error_class;
  if (status === 401) error_class = ERROR_CLASS.AUTH_REVOKED;
  else if (status === 403) error_class = ERROR_CLASS.INSUFFICIENT_SCOPE;
  else if (status === 429) error_class = ERROR_CLASS.RATE_LIMITED;
  else error_class = ERROR_CLASS.UNKNOWN;

  const applied_state = status != null && status >= 400 && status < 500
    ? APPLIED_STATE.NOT_APPLIED
    : APPLIED_STATE.UNKNOWN;

  return { error_class, applied_state, status };
}

/**
 * The exact, human-facing remediation per error class (AC #6c). Auth classes name
 * the concrete fix; the rest name how to safely resume.
 * @type {Readonly<Record<string, string>>}
 */
const REMEDIATION = Object.freeze({
  [ERROR_CLASS.AUTH_REVOKED]: 're-issue token via /workbench-ynab:setup',
  [ERROR_CLASS.INSUFFICIENT_SCOPE]: 'token requires write scope',
  [ERROR_CLASS.RATE_LIMITED]: 'wait for the rate-limit window to reset, then re-run apply to resume',
  [ERROR_CLASS.UNKNOWN]: 're-run apply to resume; already-applied ops are skipped via the audit log',
});

/** The remediation string for an `error_class` (falls back to the resume guidance). */
function remediation(errorClass) {
  return REMEDIATION[errorClass] || REMEDIATION[ERROR_CLASS.UNKNOWN];
}

/**
 * Unwrap a resolved MCP tool result, THROWING when it is an error envelope. The
 * vendored YNAB MCP surfaces auth / rate-limit / 5xx failures as a RESOLVED
 * `{ isError: true, content: [{ type: 'text', text }] }` result — NOT a rejected
 * promise — so a port wrapper that returns it verbatim fails OPEN: a 401 preflight
 * would silently "pass" and a mid-batch 401 would look like a success. Every
 * write-path port wrapper runs its `callTool` result through this before returning
 * to the executor, whose classify / auth-abort machinery only runs inside a `catch`.
 * The thrown Error preserves the envelope's error text — which carries the
 * `(HTTP <status>)` the vendored MCP embeds — so `classifyError` recovers the status.
 * @template T
 * @param {T} result the resolved MCP tool result.
 * @returns {T} the same result, unchanged, when it is not an error envelope.
 */
function throwOnErrorResult(result) {
  if (result && typeof result === 'object' && result.isError) {
    const text = Array.isArray(result.content)
      && result.content[0] && typeof result.content[0].text === 'string'
      ? result.content[0].text
      : JSON.stringify(result);
    const err = new Error(`YNAB MCP returned an error result: ${text}`);
    err.mcpResult = result;
    throw err;
  }
  return result;
}

module.exports = {
  ERROR_CLASS,
  APPLIED_STATE,
  AUTH_FAILURE_CLASSES,
  isAuthFailure,
  extractStatus,
  classifyError,
  remediation,
  throwOnErrorResult,
};
