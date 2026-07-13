// tests/unit/write-error.test.mjs — the write-path error classifier (GAP-8 / #50).
//
// The classifier (assets/write-error.js) is dependency-free, so — unlike the
// Ajv-backed apply executor whose integration tests live in assets/test/ and need
// `npm --prefix assets install` — its unit tests gate in CI here, with NO
// node_modules present (only node: built-ins + the repo-local CJS module).
//
// It imports a CommonJS module from ESM via the default import (the whole
// module.exports object), which needs no cjs-named-export detection and always works.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const require = createRequire(import.meta.url);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const {
  ERROR_CLASS,
  APPLIED_STATE,
  AUTH_FAILURE_CLASSES,
  isAuthFailure,
  extractStatus,
  classifyError,
  remediation,
} = require(join(ROOT, 'assets', 'write-error.js'));

// --- extractStatus: pull an HTTP status off the many shapes a port error takes --

test('extractStatus reads status from the common structured fields', () => {
  assert.equal(extractStatus({ status: 401 }), 401);
  assert.equal(extractStatus({ statusCode: 403 }), 403);
  assert.equal(extractStatus({ response: { status: 429 } }), 429);
  assert.equal(extractStatus({ response: { statusCode: 422 } }), 422);
  assert.equal(extractStatus({ code: 500 }), 500);
});

test('extractStatus accepts a numeric-string status', () => {
  assert.equal(extractStatus({ status: '403' }), 403);
});

test('structured fields win over the message; the message is only a fallback', () => {
  // A structured 401 must win even though the message mentions a different 500.
  assert.equal(extractStatus({ status: 401, message: 'gateway said 500' }), 401);
  // With no structured field, a 4xx/5xx token in the message is the last resort.
  assert.equal(extractStatus(new Error('YNAB responded 429 Too Many Requests')), 429);
});

test('extractStatus returns null for a statusless (network/timeout) error', () => {
  assert.equal(extractStatus(new Error('socket hang up')), null);
  assert.equal(extractStatus({ code: 'ETIMEDOUT' }), null); // non-numeric code → no status
  assert.equal(extractStatus(null), null);
  assert.equal(extractStatus('a bare string'), null);
});

test('extractStatus ignores an out-of-range number in the message', () => {
  // Only 4xx/5xx tokens are HTTP statuses; a stray "200 transactions" is not one.
  assert.equal(extractStatus(new Error('read 200 transactions, wrote 12')), null);
});

test('a coincidental money amount is NOT misread as an HTTP status', () => {
  // The bare-token fallback rejects a 4xx/5xx run that is part of a money amount — a
  // leading `$`/digit/`.` or a trailing `.<digit>` disqualifies it — so "$450.00" never
  // classifies as HTTP 450 (which would be a false not_applied on the resume path, #48).
  assert.equal(extractStatus(new Error('Transaction amount $450.00 exceeds the limit')), null);
  assert.equal(classifyError(new Error('a charge of $503.20 was declined')).status, null);
});

test('an explicit HTTP-adjacent status wins even when a money amount is also present', () => {
  assert.equal(extractStatus(new Error('POST failed (HTTP 401) after charging $450.00')), 401);
  assert.equal(extractStatus(new Error('gateway error HTTP/503')), 503);
});

test('extractStatus recovers a status from the retained mcpResult envelope when the message has none', () => {
  // throwOnErrorResult stashes the vendored error envelope on err.mcpResult; its embedded
  // `(HTTP <status>)` is recoverable even when it is not the error message's leading text.
  const err = new Error('YNAB MCP returned an error result');
  err.mcpResult = { isError: true, content: [{ type: 'text', text: '{"error":{"message":"revoked (HTTP 401)"}}' }] };
  assert.equal(extractStatus(err), 401);
  assert.equal(classifyError(err).error_class, ERROR_CLASS.AUTH_REVOKED);
});

// --- classifyError: status → { error_class, applied_state } ---------------------

test('401 → auth_revoked / not_applied', () => {
  assert.deepEqual(classifyError({ status: 401 }), {
    error_class: ERROR_CLASS.AUTH_REVOKED, applied_state: APPLIED_STATE.NOT_APPLIED, status: 401,
  });
});

test('403 → insufficient_scope / not_applied', () => {
  assert.deepEqual(classifyError({ status: 403 }), {
    error_class: ERROR_CLASS.INSUFFICIENT_SCOPE, applied_state: APPLIED_STATE.NOT_APPLIED, status: 403,
  });
});

test('429 → rate_limited / not_applied', () => {
  assert.deepEqual(classifyError({ status: 429 }), {
    error_class: ERROR_CLASS.RATE_LIMITED, applied_state: APPLIED_STATE.NOT_APPLIED, status: 429,
  });
});

test('a 422 data error → unknown class but not_applied (YNAB rejected the call)', () => {
  assert.deepEqual(classifyError({ status: 422 }), {
    error_class: ERROR_CLASS.UNKNOWN, applied_state: APPLIED_STATE.NOT_APPLIED, status: 422,
  });
});

test('a 5xx → unknown class AND unknown applied_state (may have landed server-side)', () => {
  assert.deepEqual(classifyError(new Error('YNAB 500 internal error')), {
    error_class: ERROR_CLASS.UNKNOWN, applied_state: APPLIED_STATE.UNKNOWN, status: 500,
  });
});

test('a statusless network/timeout error → unknown class, unknown applied_state, null status', () => {
  assert.deepEqual(classifyError(new Error('socket hang up')), {
    error_class: ERROR_CLASS.UNKNOWN, applied_state: APPLIED_STATE.UNKNOWN, status: null,
  });
});

// --- isAuthFailure: only 401/403 abort the whole batch --------------------------

test('isAuthFailure is true for the two auth classes only', () => {
  assert.equal(isAuthFailure(ERROR_CLASS.AUTH_REVOKED), true);
  assert.equal(isAuthFailure(ERROR_CLASS.INSUFFICIENT_SCOPE), true);
  assert.equal(isAuthFailure(ERROR_CLASS.RATE_LIMITED), false);
  assert.equal(isAuthFailure(ERROR_CLASS.UNKNOWN), false);
  assert.equal(isAuthFailure(undefined), false);
});

test('AUTH_FAILURE_CLASSES is exactly the two token-bad classes', () => {
  assert.deepEqual([...AUTH_FAILURE_CLASSES].sort(), ['auth_revoked', 'insufficient_scope']);
});

// --- remediation: the exact user-facing fix per class (AC #6c) -------------------

test('remediation names the concrete fix per class', () => {
  assert.equal(remediation(ERROR_CLASS.AUTH_REVOKED), 're-issue token via /workbench-ynab:setup');
  assert.equal(remediation(ERROR_CLASS.INSUFFICIENT_SCOPE), 'token requires write scope');
  assert.match(remediation(ERROR_CLASS.RATE_LIMITED), /rate-limit window/);
  assert.match(remediation(ERROR_CLASS.UNKNOWN), /re-run apply to resume/);
  // An unrecognized class falls back to the safe resume guidance, never undefined.
  assert.equal(remediation('nonsense'), remediation(ERROR_CLASS.UNKNOWN));
});
