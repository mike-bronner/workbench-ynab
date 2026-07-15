// tests/unit/classify-transaction.test.mjs — unit tests for the payee/category →
// tax-line mapping engine (lib/tax/classifyTransaction.mjs, issue #23 / M3-4).
//
// Runs under the built-in node:test runner with NO node_modules present (only
// node: built-ins and repo-local files), per docs/testing.md.
//
// Covers the issue #23 AC matrix: substring + regex keyword match, case-
// insensitivity, categoryName / categoryGroup / accountName matches, amountSign
// and amountThresholdDollars (with milliunit→dollar conversion), match-type
// precedence, priority ordering, the user overlay (add / disable / re-prioritize
// by id) taking precedence over bundled defaults, documented tie-breaking, the
// unclassified no-match sentinel, business-entity ($profile) scoping, purity,
// and that the bundled defaults validate against the ruleset schema.
//
// Also covers the reason-template contract (issue #25 / M3-6, surfaced reviewing
// PR #128): every {placeholder} in a rule's reason string substitutes correctly
// in the classify() reason output, and an unrecognized {token} is left intact
// rather than substituted or thrown on. renderReason() is module-private, so —
// like the existing {businessEntityId} assertion below — the contract is pinned
// through the public classify() call.
//
// Also covers the bounded ReDoS surface (issue #170): catastrophic-backtracking
// regex keywords (nested quantifiers, overlapping alternation, backreferences,
// and flat/grouped runs of sequential overlapping quantifiers — PR #201 review)
// and over-long patterns/haystacks degrade to a prompt non-match, while normal
// regex keywords — including safe quantified and non-overlapping-run shapes —
// keep matching.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  classify,
  buildRuleset,
  DEFAULT_RULES,
  UNCLASSIFIED,
} from '../../lib/tax/classifyTransaction.mjs';
import { validateAgainstSchema } from '../../lib/tax/loadProfile.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const RULES_JSON = JSON.parse(readFileSync(join(ROOT, 'assets', 'tax', 'mapping-rules.json'), 'utf8'));
const RULES_SCHEMA = JSON.parse(readFileSync(join(ROOT, 'assets', 'tax', 'mapping-rules.schema.json'), 'utf8'));

// A YNAB transaction is in MILLIUNITS; outflow (expense) is negative. -$9.00.
const tx = (over = {}) => ({ payee_name: 'Anon', amount: -9000, ...over });

// --- AC #2: bundled defaults classify the five canonical US categories ------

test('(defaults) GitHub outflow → Schedule C other expenses', () => {
  const r = classify(tx({ payee_name: 'GitHub Inc' }), null);
  assert.equal(r.taxLineId, 'schedC.27a');
  assert.equal(r.matchedRuleId, 'dev-tools-saas-hosting');
  assert.ok(r.confidence > 0);
});

test('(defaults) pharmacy → Schedule A medical', () => {
  assert.equal(classify(tx({ payee_name: 'Corner Pharmacy' }), null).taxLineId, 'schedA.medical');
});

test('(defaults) mortgage → Schedule A interest', () => {
  assert.equal(classify(tx({ payee_name: 'Acme Mortgage Servicing' }), null).taxLineId, 'schedA.interest');
});

test('(defaults) property tax → Schedule A SALT', () => {
  assert.equal(classify(tx({ payee_name: 'County Property Tax' }), null).taxLineId, 'schedA.salt');
});

test('(defaults) tithing → Schedule A charitable', () => {
  assert.equal(classify(tx({ payee_name: 'Weekly Tithe' }), null).taxLineId, 'schedA.charitable');
});

// --- AC #6: substring, regex, case-insensitive keyword matching -------------

const KW = (keywords) => [{
  id: 'kw', priority: 50, taxLineId: 'schedC.27a', reason: 'kw',
  match: { payeeKeywords: keywords },
}];

test('substring keyword match', () => {
  const r = classify(tx({ payee_name: 'DigitalOcean LLC' }), null, { rules: KW(['digitalocean']) });
  assert.equal(r.taxLineId, 'schedC.27a');
  assert.equal(r.matchedRuleId, 'kw');
});

test('regex keyword match (slash-wrapped pattern)', () => {
  const r = classify(tx({ payee_name: 'GCP Billing' }), null, { rules: KW(['/^(aws|gcp)\\b/']) });
  assert.equal(r.taxLineId, 'schedC.27a');
});

test('regex that should NOT match → unclassified', () => {
  const r = classify(tx({ payee_name: 'Grocery Store' }), null, { rules: KW(['/^(aws|gcp)\\b/']) });
  assert.equal(r.taxLineId, 'unclassified');
});

test('keyword matching is case-insensitive (substring and regex)', () => {
  assert.equal(classify(tx({ payee_name: 'AWS' }), null, { rules: KW(['aws']) }).taxLineId, 'schedC.27a');
  assert.equal(classify(tx({ payee_name: 'aws' }), null, { rules: KW(['AWS']) }).taxLineId, 'schedC.27a');
  assert.equal(classify(tx({ payee_name: 'CLOUDFLARE' }), null, { rules: KW(['/cloudflare/']) }).taxLineId, 'schedC.27a');
});

test('a malformed regex keyword is swallowed to a non-match, never thrown', () => {
  assert.doesNotThrow(() => classify(tx({ payee_name: 'x' }), null, { rules: KW(['/([/']) }));
  assert.equal(classify(tx({ payee_name: 'x' }), null, { rules: KW(['/([/']) }).taxLineId, 'unclassified');
});

// --- AC #6: categoryName / categoryGroup / accountName matches --------------

test('categoryName match (case-insensitive exact)', () => {
  const rules = [{ id: 'c', priority: 50, taxLineId: 'schedA.medical', reason: 'c', match: { categoryName: 'Health' } }];
  assert.equal(classify(tx({ category_name: 'health' }), null, { rules }).taxLineId, 'schedA.medical');
  assert.equal(classify(tx({ category_name: 'Healthy' }), null, { rules }).taxLineId, 'unclassified');
});

test('categoryGroup match', () => {
  const rules = [{ id: 'g', priority: 50, taxLineId: 'schedC.27a', reason: 'g', match: { categoryGroup: 'Biz Expenses' } }];
  assert.equal(classify(tx({ category_group_name: 'biz expenses' }), null, { rules }).taxLineId, 'schedC.27a');
});

test('accountName match', () => {
  const rules = [{ id: 'a', priority: 50, taxLineId: 'schedC.27a', reason: 'a', match: { accountName: 'Business Checking' } }];
  assert.equal(classify(tx({ account_name: 'business checking' }), null, { rules }).taxLineId, 'schedC.27a');
});

// --- AC #7: amountSign + amountThresholdDollars with milliunit conversion ----

test('amountSign distinguishes outflow from inflow', () => {
  const rules = [{ id: 's', priority: 50, taxLineId: 'schedC.27a', reason: 's', match: { amountSign: 'outflow' } }];
  assert.equal(classify(tx({ amount: -5000 }), null, { rules }).taxLineId, 'schedC.27a'); // outflow
  assert.equal(classify(tx({ amount: 5000 }), null, { rules }).taxLineId, 'unclassified'); // inflow
  assert.equal(classify(tx({ amount: 0 }), null, { rules }).taxLineId, 'unclassified');    // neither
});

test('a dev-tools refund (inflow) is NOT classified as an expense', () => {
  assert.equal(classify(tx({ payee_name: 'GitHub Inc', amount: 9000 }), null).taxLineId, 'unclassified');
});

test('amountThresholdDollars compares DOLLARS, not raw milliunits', () => {
  const rules = [{ id: 't', priority: 50, taxLineId: 'schedC.27a', reason: 't', match: { amountThresholdDollars: 50 } }];
  // -100000 milliunits = -$100 → |100| >= 50 → matches.
  assert.equal(classify(tx({ amount: -100000 }), null, { rules }).taxLineId, 'schedC.27a');
  // -40000 milliunits = -$40 → |40| < 50 → no match. (If it compared raw
  // milliunits, 40000 >= 50 would wrongly match — this proves the /1000.)
  assert.equal(classify(tx({ amount: -40000 }), null, { rules }).taxLineId, 'unclassified');
});

// --- AC #4 + #6: priority ordering and match-type precedence ----------------

test('lower priority number is evaluated first and wins', () => {
  const rules = [
    { id: 'low', priority: 10, taxLineId: 'schedC.27a', reason: 'low', match: { payeeKeywords: ['shop'] } },
    { id: 'high', priority: 90, taxLineId: 'schedA.medical', reason: 'high', match: { payeeKeywords: ['shop'] } },
  ];
  assert.equal(classify(tx({ payee_name: 'The Shop' }), null, { rules }).matchedRuleId, 'low');
});

test('match-type precedence: categoryName beats payeeKeywords at equal priority/source', () => {
  const rules = [
    { id: 'by-payee', priority: 50, taxLineId: 'schedA.medical', reason: 'p', match: { payeeKeywords: ['acme'] } },
    { id: 'by-category', priority: 50, taxLineId: 'schedC.27a', reason: 'c', match: { categoryName: 'Software' } },
  ];
  const r = classify(tx({ payee_name: 'Acme', category_name: 'Software' }), null, { rules });
  assert.equal(r.matchedRuleId, 'by-category');
});

// --- AC #9: user overlay precedence (add / disable / re-prioritize by id) ----

test('a user rule with a NEW id is added to the ruleset', () => {
  const profile = { mappingRules: [{ id: 'u', priority: 5, taxLineId: 'schedC.18', reason: 'u', match: { payeeKeywords: ['staples'] } }] };
  assert.equal(classify(tx({ payee_name: 'Staples' }), profile).taxLineId, 'schedC.18');
});

test('a user rule REPLACES a same-id default (disable a default)', () => {
  const profile = { mappingRules: [{ id: 'dev-tools-saas-hosting', enabled: false, priority: 50, taxLineId: 'schedC.27a', reason: 'off', match: { payeeKeywords: ['github'] } }] };
  assert.equal(classify(tx({ payee_name: 'GitHub Inc' }), profile).taxLineId, 'unclassified');
});

test('a user rule REPLACES a same-id default (re-route it)', () => {
  const profile = { mappingRules: [{ id: 'dev-tools-saas-hosting', priority: 50, taxLineId: 'schedC.18', reason: 'moved', match: { payeeKeywords: ['github'], amountSign: 'outflow' } }] };
  assert.equal(classify(tx({ payee_name: 'GitHub Inc' }), profile).taxLineId, 'schedC.18');
});

test('at equal priority a user-sourced rule outranks a default (tie-break)', () => {
  const rules = [{ id: 'd', priority: 50, taxLineId: 'schedA.medical', reason: 'd', match: { payeeKeywords: ['acme'] } }];
  const userRules = [{ id: 'u', priority: 50, taxLineId: 'schedC.27a', reason: 'u', match: { payeeKeywords: ['acme'] } }];
  const r = classify(tx({ payee_name: 'Acme' }), null, { rules, userRules });
  assert.equal(r.matchedRuleId, 'u');
});

// --- AC #5: explicit unclassified sentinel, never a wrong guess --------------

test('no rule matches → the UNCLASSIFIED sentinel', () => {
  const r = classify(tx({ payee_name: 'Mystery Vendor', amount: -1234 }), null);
  assert.equal(r.taxLineId, 'unclassified');
  assert.equal(r.confidence, 0);
  assert.equal(r.matchedRuleId, null);
  assert.equal(r.businessEntityId, undefined);
});

test('options.minConfidence below the best match → unclassified', () => {
  const rules = [{ id: 'weak', priority: 50, confidence: 0.3, taxLineId: 'schedC.27a', reason: 'w', match: { payeeKeywords: ['acme'] } }];
  assert.equal(classify(tx({ payee_name: 'Acme' }), null, { rules, minConfidence: 0.5 }).taxLineId, 'unclassified');
  assert.equal(classify(tx({ payee_name: 'Acme' }), null, { rules, minConfidence: 0.2 }).taxLineId, 'schedC.27a');
});

// --- AC #8: business-entity ($profile) structural scoping --------------------

const bizProfile = () => ({
  businessEntities: [{
    id: 'biz-a', displayName: 'Business A', schedule: 'C',
    scheduleLineMap: { categoryGroups: ['Acme Ops'], accounts: ['Biz Checking'] },
  }],
});

test('a transaction in a business category-group → Schedule C scoped to the owning entity', () => {
  const r = classify(tx({ category_group_name: 'Acme Ops' }), bizProfile());
  assert.equal(r.taxLineId, 'schedC.27a');
  assert.equal(r.matchedRuleId, 'business-category-or-account');
  assert.equal(r.businessEntityId, 'biz-a');
  assert.match(r.reason, /biz-a/); // template substitution of {businessEntityId}
});

test('a transaction in a business account → Schedule C scoped to the owning entity', () => {
  const r = classify(tx({ account_name: 'Biz Checking' }), bizProfile());
  assert.equal(r.businessEntityId, 'biz-a');
});

test('$profile resolves to the sole business entity for a non-structural (payee) match', () => {
  const r = classify(tx({ payee_name: 'GitHub Inc' }), bizProfile());
  assert.equal(r.taxLineId, 'schedC.27a');
  assert.equal(r.matchedRuleId, 'dev-tools-saas-hosting');
  assert.equal(r.businessEntityId, 'biz-a');
});

test('$profile stays unset when the entity is ambiguous (no structural match, >1 entity)', () => {
  const profile = {
    businessEntities: [
      { id: 'biz-a', displayName: 'A', schedule: 'C', scheduleLineMap: {} },
      { id: 'biz-b', displayName: 'B', schedule: 'C', scheduleLineMap: {} },
    ],
  };
  const r = classify(tx({ payee_name: 'GitHub Inc' }), profile);
  assert.equal(r.taxLineId, 'schedC.27a');
  assert.equal(r.businessEntityId, undefined);
});

// --- AC #11: purity ----------------------------------------------------------

test('classify does not mutate its transaction or profile arguments', () => {
  const transaction = tx({ payee_name: 'GitHub Inc' });
  const before = JSON.stringify(transaction);
  const profile = bizProfile();
  const profBefore = JSON.stringify(profile);
  classify(transaction, profile);
  assert.equal(JSON.stringify(transaction), before);
  assert.equal(JSON.stringify(profile), profBefore);
});

test('classify is deterministic for the same inputs', () => {
  const a = classify(tx({ payee_name: 'GitHub Inc' }), bizProfile());
  const b = classify(tx({ payee_name: 'GitHub Inc' }), bizProfile());
  assert.deepEqual(a, b);
});

// --- AC #1/#2/#3: the bundled defaults and their schema ----------------------

test('the bundled mapping-rules.json validates against mapping-rules.schema.json', () => {
  const { valid, errors } = validateAgainstSchema(RULES_JSON, RULES_SCHEMA);
  assert.equal(valid, true, `defaults should validate; got: ${JSON.stringify(errors)}`);
});

test('the bundled defaults cover the five required US categories', () => {
  const lines = new Set(DEFAULT_RULES.map((r) => r.taxLineId));
  for (const id of ['schedC.27a', 'schedA.medical', 'schedA.interest', 'schedA.salt', 'schedA.charitable']) {
    assert.ok(lines.has(id), `expected a default rule for ${id}`);
  }
});

test('no bundled default hard-codes an owner-specific businessEntityId', () => {
  for (const r of DEFAULT_RULES) {
    if ('businessEntityId' in r) assert.equal(r.businessEntityId, '$profile', `rule ${r.id} must use the $profile sentinel`);
  }
});

test('buildRuleset drops disabled rules and orders by priority', () => {
  const base = [
    { id: 'a', priority: 90, taxLineId: 'x', reason: 'a', match: { payeeKeywords: ['x'] } },
    { id: 'b', priority: 10, taxLineId: 'x', reason: 'b', match: { payeeKeywords: ['x'] } },
    { id: 'c', enabled: false, priority: 1, taxLineId: 'x', reason: 'c', match: { payeeKeywords: ['x'] } },
  ];
  const ids = buildRuleset(null, { rules: base }).map((t) => t.rule.id);
  assert.deepEqual(ids, ['b', 'a']);
});

// UNCLASSIFIED is a shared frozen constant; classify must return a fresh copy so
// a caller can never mutate the sentinel for everyone else.
test('UNCLASSIFIED sentinel is frozen and classify returns a distinct object', () => {
  assert.ok(Object.isFrozen(UNCLASSIFIED));
  const r = classify(tx({ payee_name: 'Nothing' }), null);
  assert.notEqual(r, UNCLASSIFIED);
  assert.equal(r.taxLineId, UNCLASSIFIED.taxLineId);
});

// --- issue #25: reason-template placeholder substitution --------------------
//
// The reason string is user-facing (the review skill shows it for a suggested
// tax line), so each {placeholder} is part of the contract and pinned with its
// own focused assertion. renderReason() is module-private; each case injects a
// single matching rule whose reason is exactly the placeholder under test and
// reads back classify()'s reason output — the same public-API path the
// {businessEntityId} scoping test above uses. All fixtures are synthetic.

// Classify `transaction` under one injected rule whose reason is `template`,
// matched by `match`, and return the rendered reason string. `extra` patches the
// rule (e.g. a literal businessEntityId or taxLineId).
const reasonFor = (template, match, transaction, extra = {}) =>
  classify(transaction, null, {
    rules: [{ id: 'r', priority: 50, taxLineId: 'schedC.27a', reason: template, match, ...extra }],
  }).reason;

test('reason template substitutes {payee}', () => {
  assert.equal(reasonFor('{payee}', { payeeKeywords: ['widgets'] }, tx({ payee_name: 'Acme Widgets LLC' })), 'Acme Widgets LLC');
});

test('reason template substitutes {categoryName}', () => {
  assert.equal(reasonFor('{categoryName}', { categoryName: 'Office Supplies' }, tx({ category_name: 'Office Supplies' })), 'Office Supplies');
});

test('reason template substitutes {categoryGroup}', () => {
  assert.equal(reasonFor('{categoryGroup}', { categoryGroup: 'Business Expenses' }, tx({ category_group_name: 'Business Expenses' })), 'Business Expenses');
});

test('reason template substitutes {accountName}', () => {
  assert.equal(reasonFor('{accountName}', { accountName: 'Business Checking' }, tx({ account_name: 'Business Checking' })), 'Business Checking');
});

test('reason template substitutes {matchedKeyword}', () => {
  assert.equal(reasonFor('{matchedKeyword}', { payeeKeywords: ['widgets'] }, tx({ payee_name: 'Acme Widgets LLC' })), 'widgets');
});

test('reason template substitutes {taxLineId}', () => {
  assert.equal(reasonFor('{taxLineId}', { payeeKeywords: ['acme'] }, tx({ payee_name: 'Acme' }), { taxLineId: 'schedA.medical' }), 'schedA.medical');
});

test('reason template substitutes {businessEntityId}', () => {
  assert.equal(reasonFor('{businessEntityId}', { payeeKeywords: ['acme'] }, tx({ payee_name: 'Acme' }), { businessEntityId: 'ent-42' }), 'ent-42');
});

// An unrecognized {token} is passed through verbatim — no substitution, and no
// throw — while a known placeholder in the same string still substitutes.
test('reason template leaves an unknown {token} intact and does not throw', () => {
  let reason;
  assert.doesNotThrow(() => {
    reason = reasonFor('{payee} at {nope}', { payeeKeywords: ['acme'] }, tx({ payee_name: 'Acme' }));
  });
  assert.equal(reason, 'Acme at {nope}');
});

// --- issue #170: bounded ReDoS surface in user-rule regex matching -----------
//
// A pathological user regex against a crafted haystack must never hang
// classify(). Unmitigated, /(a+)+$/ against 'a'.repeat(32) + 'b' backtracks
// ~2^32 times — many seconds to minutes — so the timing assertion below fails
// loudly (rather than hanging the run forever) if the bound regresses.

test('a catastrophic-backtracking regex keyword returns promptly as a non-match, never a crash', () => {
  const adversarial = tx({ payee_name: `${'a'.repeat(32)}b` });
  const started = process.hrtime.bigint();
  let r;
  assert.doesNotThrow(() => {
    r = classify(adversarial, null, { rules: KW(['/(a+)+$/']) });
  });
  const elapsedMs = Number(process.hrtime.bigint() - started) / 1e6;
  assert.equal(r.taxLineId, 'unclassified');
  assert.ok(elapsedMs < 1000, `expected a bounded match, took ${elapsedMs}ms`);
});

// The backreference pattern /(a+)\1/ WOULD match this haystack quickly if
// compiled ('a'×16 + 'a'×16), so the unclassified assertion proves the
// scanner's backreference rejection is load-bearing, not a coincidental
// non-match. The timing bound makes a guard regression on the catastrophic
// shapes fail loudly rather than hang the run (scripts/test.sh sets no
// node:test timeout).
test('other high-risk regex shapes (non-capture nesting, overlapping alternation, backreference) → no match', () => {
  const adversarial = tx({ payee_name: `${'a'.repeat(32)}b` });
  const started = process.hrtime.bigint();
  for (const evil of ['/(?:a+)*$/', '/(a|aa)+$/', '/(a+)\\1/']) {
    assert.equal(classify(adversarial, null, { rules: KW([evil]) }).taxLineId, 'unclassified', `expected ${evil} to be rejected`);
  }
  const elapsedMs = Number(process.hrtime.bigint() - started) / 1e6;
  assert.ok(elapsedMs < 1000, `expected bounded rejection, took ${elapsedMs}ms`);
});

// PR #201 review blocker: a FLAT run of sequential overlapping quantifiers —
// no grouping at all, or sibling groups — is the same catastrophic family as
// (a+)+ (each added atom multiplies the backtracking degree) and slipped past
// the original nesting-only scanner. Unmitigated, each of these is a
// many-second-to-minutes evaluation against this haystack, so the timing
// assertion fails loudly if the sequential-run rejection regresses.
test('a flat or grouped run of sequential overlapping quantifiers → prompt non-match', () => {
  const adversarial = tx({ payee_name: `${'a'.repeat(40)}!` });
  const started = process.hrtime.bigint();
  for (const evil of ['/^a*a*a*a*a*a*a*a*a*a*b$/', '/.*.*.*.*.*.*.*.*zzz/', '/a+a+a+a+a+a+a+a+a+a+b/', '/(a+)(a+)/']) {
    assert.equal(classify(adversarial, null, { rules: KW([evil]) }).taxLineId, 'unclassified', `expected ${evil} to be rejected`);
  }
  const elapsedMs = Number(process.hrtime.bigint() - started) / 1e6;
  assert.ok(elapsedMs < 1000, `expected bounded rejection, took ${elapsedMs}ms`);
});

// The caps are the reason these don't match: each pattern WOULD match its
// haystack if compiled and tested unbounded.
test('an over-long regex pattern or haystack yields no match; the substring path stays uncapped', () => {
  const longPattern = `/${'a'.repeat(300)}/`;
  assert.equal(classify(tx({ payee_name: 'a'.repeat(400) }), null, { rules: KW([longPattern]) }).taxLineId, 'unclassified');
  assert.equal(classify(tx({ payee_name: 'x'.repeat(2000) }), null, { rules: KW(['/x/']) }).taxLineId, 'unclassified');
  // Substring matching is linear — an over-long haystack still substring-matches.
  assert.equal(classify(tx({ payee_name: 'x'.repeat(2000) }), null, { rules: KW(['xxx']) }).taxLineId, 'schedC.27a');
});

// The bound must not break legitimate regex rules (per the issue #170 AC).
test('a normal regex keyword still matches under the ReDoS bound', () => {
  const r = classify(tx({ payee_name: 'AWS Cloud Services' }), null, { rules: KW(['/aws|gcp/i']) });
  assert.equal(r.taxLineId, 'schedC.27a');
  assert.equal(r.matchedRuleId, 'kw');
});

// PR #201 review follow-up: every other positive case is alternation-only, so
// pin the safe/unsafe discrimination from the QUANTIFIED side too — a single
// flexible quantifier (bare, on a class-free group, on an escape class) is
// exactly what the scanner must keep admitting.
test('a safe QUANTIFIED regex keyword still matches under the ReDoS bound', () => {
  assert.equal(classify(tx({ payee_name: 'ababab store' }), null, { rules: KW(['/(ab)+/']) }).taxLineId, 'schedC.27a');
  assert.equal(classify(tx({ payee_name: 'AWS42 invoice' }), null, { rules: KW(['/aws\\d+/']) }).taxLineId, 'schedC.27a');
  assert.equal(classify(tx({ payee_name: 'Amazon Prime video' }), null, { rules: KW(['/amazon( prime)?/']) }).taxLineId, 'schedC.27a');
});

// The sequential-run rejection is only for OVERLAPPING alphabets: adjacent
// quantifiers over disjoint atoms (a+b+) have an unambiguous repetition
// boundary, backtrack linearly, and must keep matching.
test('adjacent quantifiers over non-overlapping atoms (a+b+) still match', () => {
  assert.equal(classify(tx({ payee_name: 'xxaabbyy' }), null, { rules: KW(['/a+b+/']) }).taxLineId, 'schedC.27a');
  assert.equal(classify(tx({ payee_name: 'nothing here' }), null, { rules: KW(['/a+b+/']) }).taxLineId, 'unclassified');
});
