# Confidence bands — the human-review routing contract

The confidence policy ([`lib/tax/confidence.mjs`](../lib/tax/confidence.mjs),
issue #19 / GAP-20) turns the mapping engine's confidence score (M3-4,
[`lib/tax/classifyTransaction.mjs`](../lib/tax/classifyTransaction.mjs)) into a
routing **band** that every downstream consumer acts on. This document is the
consumer contract: what each band means, who does what with it, and what can
never happen.

> **Nothing bypasses the human approval gate.** Confidence governs proposal
> composition only — whether an op is **pre-filled** into the apply proposal.
> The approval gate (per the project brief) is mandatory and independent of
> confidence; no band, threshold, or config value ever auto-applies a change.

> **Not tax advice.** This organizes financial data and surfaces tax-relevant
> signals; it is not a substitute for professional tax advice.

## The bands

Every `classify()` result carries `{ confidence: number, band: 'high' |
'medium' | 'low' | 'unclassified' }` alongside the tax-line assignment — one
object, one call. Band assignment is enforced by
`assignBand(confidence, thresholds)`:

| Band | Rule | Downstream behaviour |
| --- | --- | --- |
| `high` | `confidence ≥ highThreshold` | Eligible for a **pre-filled proposal op** in the M4-10 apply proposal — still subject to the human approval gate. |
| `medium` | `mediumThreshold ≤ confidence < highThreshold` | Rendered in the M2 report as a **"review suggested"** item. Never pre-fills a proposal op. |
| `low` | `0 < confidence < mediumThreshold` | **Flagged for human attention only.** No proposed change emitted. |
| `unclassified` | `confidence === 0`, or the unclassified sentinel | Same as `low`: human attention only, no proposed change. |

### Splits and transfer legs — always human-only

Split transactions (non-empty `subtransactions`, or YNAB's literal `Split`
category) and transfer legs (`transfer_account_id` set) are **ambiguous by
construction** (GAP-19). The mapping engine hard-codes them to
`band: 'unclassified'` regardless of the computed confidence score — no
exception path overrides this.

## Thresholds — conservative defaults, user-configurable

The defaults ship in `lib/tax/confidence.mjs` as documented public API:

```js
export const HIGH_THRESHOLD = 0.85;
export const MEDIUM_THRESHOLD = 0.6;
```

They are deliberately conservative: a fresh user errs toward flag-for-review
rather than a proposal full of speculative changes.

Users override them in their own `config.json` instance
([`docs/config-schema.md`](config-schema.md)) — never in repo files:

```json
"classification": {
  "highThreshold": 0.85,
  "mediumThreshold": 0.6
}
```

`loadThresholds()` reads the config (honouring the `YNAB_CONFIG_FILE` env seam,
like `bin/config.sh`) and falls back to the defaults when the file, the
`classification` block, or a value is missing or invalid. A contradictory pair
(`mediumThreshold ≥ highThreshold`) falls back to the defaults wholesale — the
loader never throws and never returns an unusable pair.

## Wiring — who calls what

```js
import { loadThresholds } from '../lib/tax/confidence.mjs';
import { classifyBatch } from '../lib/tax/index.mjs';

const thresholds = loadThresholds();                    // config → sane pair
const suggestions = classifyBatch(txns, profile, { thresholds });
// each → { taxLineId, confidence, band, matchedRuleId, reason, businessEntityId? }
```

1. **M3-4 (mapping engine)** emits `confidence` and annotates every result
   with `band`. `classify()` stays pure: the *caller* resolves config once via
   `loadThresholds()` and passes it as `options.thresholds` (the same pattern
   as `loadProfile()` → `profile`). Without `options.thresholds`, the bundled
   conservative defaults apply.
2. **M2 (review skill/report)** renders the band: `high` ops appear as
   auto-suggested, `medium` as "review suggested", `low`/`unclassified` as
   flagged-for-attention.
3. **M4-10 (proposal generator)** includes **only `high`-band ops** when
   composing the apply proposal. `medium`, `low`, and `unclassified` never
   pre-fill a proposal — and every proposal, whatever its composition, goes
   through the human approval gate before anything is applied.
