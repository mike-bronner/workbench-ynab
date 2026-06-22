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
