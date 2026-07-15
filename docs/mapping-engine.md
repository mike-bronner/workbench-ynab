# Mapping engine — payee/category → tax line

The mapping engine ([`lib/tax/classifyTransaction.mjs`](../lib/tax/classifyTransaction.mjs),
issue #23 / M3-4) is the data-driven replacement for the prototype's inline prose
heuristics. Given an **already-fetched** YNAB transaction it returns a suggested
tax line, a confidence, a routing band, and a human-readable reason — or an
explicit `unclassified` result when nothing matches with sufficient confidence.

```js
import { classify } from '../lib/tax/classifyTransaction.mjs';
import { loadProfile } from '../lib/tax/loadProfile.mjs';

const { profile } = loadProfile();            // resolved, frozen tax profile
const suggestion = classify(transaction, profile);
// → { taxLineId: 'schedC.27a', businessEntityId: 'biz-a', confidence: 0.6,
//     band: 'medium', matchedRuleId: 'dev-tools-saas-hosting',
//     reason: "Payee 'GitHub Inc' …" }
```

Every result carries a `band` (`'high' | 'medium' | 'low' | 'unclassified'`)
assigned by the confidence policy ([`lib/tax/confidence.mjs`](../lib/tax/confidence.mjs),
issue #19). The band governs **proposal composition only** — the human approval
gate is mandatory and independent of confidence. Splits and transfer legs are
hard-coded to `band: 'unclassified'` regardless of the computed score. Pass
`options.thresholds` (from `loadThresholds()`) to honour the user's configured
thresholds; the full consumer contract lives in
[`docs/confidence-contract.md`](confidence-contract.md).

> **Not tax advice.** This organizes financial data and surfaces tax-relevant
> signals; it is not a substitute for professional tax advice.

## Who calls it, and the YNAB namespacing

Plugin **skills** call `classify`, never the vendored YNAB MCP. The transaction
is fetched first by the skill using the vendored MCP tools namespaced
`mcp__plugin_workbench-ynab_ynab__*` (e.g. `ynab_list_transactions`,
`ynab_list_payees`) — **not** `mcp__ynab__*`. `classify` is MCP-agnostic: it
reads a plain object and never touches the wire.

## Purity

`classify()` is **pure** — same inputs, same output, with no network, no MCP, no
file I/O, and no side effects. The only file read in the module is the one-time,
import-time load of the bundled defaults into the frozen `DEFAULT_RULES`
constant (analogous to importing a JSON asset); it is outside any `classify`
call. Tests that need zero-I/O purity inject `options.rules`.

## The transaction shape

`classify` reads these fields, accepting YNAB-native `snake_case` or
`camelCase`; any absent field is treated as "no value" (and never matches):

| Field | YNAB-native | Notes |
| --- | --- | --- |
| payee | `payee_name` | matched by `payeeKeywords` |
| category | `category_name` | matched by `categoryName` |
| category group | `category_group_name` | matched by `categoryGroup` and the business signal |
| account | `account_name` | matched by `accountName` and the business signal |
| amount | `amount` | **YNAB milliunits** — see below |

### Money units — milliunits → dollars

YNAB amounts are **milliunits** (1000 milliunits = $1). Every amount comparison
is done in **dollars**: the engine divides the milliunit amount by 1000 before
evaluating `amountSign` or `amountThresholdDollars`. So `amountThresholdDollars:
50` matches a `-100000` milliunit (`-$100`) transaction but not a `-40000`
(`-$40`) one. Sign convention: an **outflow** (expense) is negative, an
**inflow** (income/refund) is positive; a zero amount is neither.

## A rule

A ruleset is `{ rulesetVersion, rules: [...] }`; see the schema at
[`assets/tax/mapping-rules.schema.json`](../assets/tax/mapping-rules.schema.json).
Each rule:

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | ✓ | Stable id. A user rule replaces a same-id bundled rule. |
| `match` | ✓ | Criteria (≥1); **all present criteria must match (AND)**. |
| `taxLineId` | ✓ | Target line in the catalog (`us-tax-lines.json`), e.g. `schedC.27a`. |
| `priority` | ✓ | Integer; **ascending** — lowest is evaluated first and wins. |
| `reason` | ✓ | Template; `{payee}`, `{categoryName}`, `{categoryGroup}`, `{accountName}`, `{taxLineId}`, `{businessEntityId}`, `{matchedKeyword}` are substituted. |
| `businessEntityId` | | Schedule C scope; a literal id, or the `$profile` sentinel (resolved from the profile). |
| `confidence` | | `[0,1]`, default `0.5`. |
| `enabled` | | default `true`; `false` disables the rule. |

### Match criteria

| Criterion | Matches |
| --- | --- |
| `payeeKeywords: [...]` | ANY keyword against the payee. A plain string is a case-insensitive **substring**; a slash-wrapped string (`"/aws\|gcp/"`) is a case-insensitive **regex** (the `i` flag is always added). A malformed regex degrades to a non-match, never a throw — and so does a regex the ReDoS bound rejects (#170): a pattern over 256 chars, a haystack over 1024 chars, or a high-risk shape (nested quantifiers like `(a+)+`, alternation under a quantifier like `(a\|aa)+`, backreferences, or a run of two-plus flexible quantifiers over overlapping alphabets in one concatenation — grouped or bare, at any depth — like `a*a*`, `.*.*.*x`, or `(a+)(a+)`; non-overlapping runs like `a+b+` stay allowed). Substring keywords are unbounded (linear-time). |
| `categoryName` | case-insensitive **exact** match |
| `categoryGroup` | case-insensitive **exact** match |
| `accountName` | case-insensitive **exact** match |
| `amountSign` | `"outflow"` (negative) or `"inflow"` (positive) |
| `amountThresholdDollars` | `\|amount in dollars\| ≥ threshold` |
| `businessSignal: true` | the transaction posts to a business category-group/account (see below) |

## Evaluation order, precedence, and tie-breaking

1. Build the **effective ruleset**: bundled defaults overlaid by the user's
   rules (see below), with `enabled: false` rules dropped.
2. Sort **ascending**; the first matching rule wins. The sort key:
   1. `priority` (ascending)
   2. **source** — a user rule before a default (user wins a tie)
   3. **match-type strength** — `categoryName` > `categoryGroup` ≈ `businessSignal`
      > `accountName` > `payeeKeywords` > amount criteria
   4. **declaration order** (stable)
3. A rule matches when **every** criterion present in `match` matches.
4. No match — or the best match's `confidence` below `options.minConfidence`
   (default `0`) — returns the `unclassified` sentinel
   (`taxLineId: "unclassified"`, `confidence: 0`, `matchedRuleId: null`), never a
   wrong guess.

`options.minConfidence` lets the review skill raise the bar for what to
auto-suggest versus flag for human approval.

## User overlay — add, disable, re-prioritize

User rules live under `overrides.mappingRules` in the profile instance; the
M3-1 loader surfaces them at `profile.mappingRules`, and `classify` overlays
them **by `id`**:

- **Add** — a rule with a new `id` is appended.
- **Disable** — overlay a rule with a bundled `id` and `enabled: false`.
- **Re-route / re-prioritize / patch** — overlay a rule with a bundled `id`; it
  **replaces** the default wholesale (give it a lower `priority` to outrank
  other rules, or change its `taxLineId`).

Users never edit repo files to customize classification.

## Business-entity (`$profile`) scoping

The bundled defaults must not name anyone's business, so Schedule C rules carry
`businessEntityId: "$profile"` — a sentinel the engine resolves at classify
time:

- The **structural** rule (`businessSignal: true`) matches when the
  transaction's category-group or account is one the profile declares for a
  business entity, under that entity's open `scheduleLineMap`:

  ```json
  "scheduleLineMap": {
    "categoryGroups": ["Acme Ops"],
    "accounts": ["Biz Checking"]
  }
  ```

  On a match, `$profile` resolves to that owning entity's `id`.
- For a **non-structural** match (e.g. a dev-tools payee keyword) `$profile`
  resolves to the **sole** business entity when exactly one exists, and is left
  **unset** when the choice is ambiguous (zero or more than one entity) — the
  engine never guesses which business an expense belongs to.

This encodes the prototype's "a transaction in a business account/category-group,
or a tech/SaaS/hosting vendor not already in a business category, is a likely
Schedule C expense" signal entirely from profile data — no hard-coded names.
