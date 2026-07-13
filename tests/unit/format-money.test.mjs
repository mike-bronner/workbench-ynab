// format-money.test.mjs — the shared money helper (issue #34, Option A).
//
// Proves formatMoney drives currency presentation entirely from the budget's
// currency_format: correct symbol placement, separators, and decimal_digits for
// USD, EUR, and JPY — never a hardcoded '$' or two decimals. Also pins the
// USD-default parity that keeps the write-path dry-run (allocate-handler)
// byte-identical, and the trust-boundary fallbacks.
//
// CommonJS module imported via the default binding (node:test / ESM interop).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import money from '../../assets/format-money.js';

const { formatMoney, resolveCurrencyFormat, DEFAULT_CURRENCY_FORMAT } = money;

// --- USD default parity (regression: matches the pre-#34 hardcoded formatter) --
test('USD (default when no currency_format is passed) renders $X,XXX.XX', () => {
  assert.equal(formatMoney(250000), '$250.00');
  assert.equal(formatMoney(-54990), '-$54.99');
  assert.equal(formatMoney(0), '$0.00');
  assert.equal(formatMoney(1200000), '$1,200.00');
  assert.equal(formatMoney(-250000), '-$250.00');
});

// --- AC #8: EUR — symbol trails, comma decimal, period grouping ---------------
test('EUR renders "1.234,56 €" (symbol trailing, swapped separators)', () => {
  const eur = {
    symbol: '€',
    symbol_first: false,
    decimal_digits: 2,
    decimal_separator: ',',
    group_separator: '.',
  };
  assert.equal(formatMoney(1234560, eur), '1.234,56 €');
  assert.equal(formatMoney(-1234560, eur), '-1.234,56 €');
});

test('EUR via the canonical YNAB field name currency_symbol renders identically', () => {
  const eur = {
    currency_symbol: '€',
    symbol_first: false,
    decimal_digits: 2,
    decimal_separator: ',',
    group_separator: '.',
  };
  assert.equal(formatMoney(1234560, eur), '1.234,56 €');
});

// --- AC #9: JPY — decimal_digits 0, no decimal separator ----------------------
test('JPY (decimal_digits=0) renders a whole number with no decimal separator', () => {
  const jpy = {
    currency_symbol: '¥',
    symbol_first: true,
    decimal_digits: 0,
    decimal_separator: '.',
    group_separator: ',',
  };
  const out = formatMoney(1234000, jpy);
  assert.equal(out, '¥1,234');
  assert.ok(!out.includes('.'), 'JPY output must contain no decimal separator');
});

// --- decimal_digits governs rounding, not a hardcoded 2 -----------------------
test('decimal_digits=3 keeps three fractional digits', () => {
  const kwd = { currency_symbol: 'KD', symbol_first: true, decimal_digits: 3, decimal_separator: '.', group_separator: ',' };
  assert.equal(formatMoney(1500, kwd), 'KD1.500'); // 1500 milliunits = 1.5 units
  // NOTE: a 3-decimal currency has divisor = 1000 / 10**3 = 1, so `Math.round(amount / 1)`
  // is a no-op — there is no sub-milliunit remainder to round. The rounding DIRECTION
  // therefore cannot be exercised for this shape; it is pinned below for the shapes
  // that CAN round (2-decimal, divisor 10; 0-decimal, divisor 1000).
});

// --- fractional-milliunit ROUNDING is actually exercised (issue #150) ----------
// Every OTHER input in this suite is an exact multiple of its currency's minor-unit
// divisor, so `Math.round(amount / divisor)` at format-money.js's rounding line never
// rounds a fractional value — a swap to `Math.trunc`/`Math.floor` would pass the whole
// suite unchanged. These cases are the ONLY ones that pin the rounding DIRECTION: each
// asserts an output that a `Math.trunc`/`Math.floor` regression provably breaks.
// formatMoney rounds half-toward-+∞ (JS `Math.round`); the sibling formatDollars in
// delete-duplicate.js TRUNCATES instead — that divergence is deliberate and separately
// guarded in tests/unit/delete-duplicate.test.mjs.
test('USD sub-cent input rounds half-away-from-zero for positives (2995 → $3.00, -2995 → -$2.99)', () => {
  // 2995 milliunits = 299.5 cents. Math.round → 300 ("$3.00"); Math.trunc/Math.floor → 299 ("$2.99").
  assert.equal(formatMoney(2995), '$3.00');
  // -2995 = -299.5 cents. Math.round → -299 ("-$2.99", toward +∞); Math.floor → -300 ("-$3.00").
  assert.equal(formatMoney(-2995), '-$2.99');
  // This exact pair is byte-identical to the deleted allocate-handler formatter (the
  // USD-parity contract in this file's header) and must stay so.
});

test('EUR sub-cent input rounds (2-decimal shape, trailing symbol, swapped separators)', () => {
  const eur = { symbol: '€', symbol_first: false, decimal_digits: 2, decimal_separator: ',', group_separator: '.' };
  // 1234565 milliunits = 123456.5 cents. Math.round → 123457 ("1.234,57 €"); trunc/floor → 123456 ("1.234,56 €").
  assert.equal(formatMoney(1234565, eur), '1.234,57 €');
  // -1234565 = -123456.5 cents. Math.round → -123456 (toward +∞); Math.floor → -123457.
  assert.equal(formatMoney(-1234565, eur), '-1.234,56 €');
});

test('JPY (decimal_digits=0) sub-yen input rounds to the nearest whole yen, not truncated', () => {
  const jpy0 = { currency_symbol: '¥', symbol_first: true, decimal_digits: 0, decimal_separator: '.', group_separator: ',' };
  // 1500 milliunits = 1.5 yen. Math.round → 2 ("¥2"); Math.trunc/Math.floor → 1 ("¥1").
  assert.equal(formatMoney(1500, jpy0), '¥2');
  // -1500 = -1.5 yen. Math.round → -1 ("-¥1", toward +∞); Math.floor → -2 ("-¥2").
  assert.equal(formatMoney(-1500, jpy0), '-¥1');
});

test('JPY near-zero negative rounds to a clean "¥0" (no "-¥0"): a magnitude that rounds to zero has no sign', () => {
  const jpy0 = { currency_symbol: '¥', symbol_first: true, decimal_digits: 0, decimal_separator: '.', group_separator: ',' };
  // -500 milliunits = -0.5 yen. Math.round(-0.5) === -0, and the `minorUnits < 0` sign
  // test is false for -0, so the deliberate output is "¥0" — never "-¥0" or -1.
  assert.equal(formatMoney(-500, jpy0), '¥0');
});

// --- display_symbol=false drops the symbol (and its space) --------------------
test('display_symbol=false renders the number alone', () => {
  const noSym = { currency_symbol: '$', symbol_first: false, decimal_digits: 2, display_symbol: false };
  assert.equal(formatMoney(123450, noSym), '123.45');
});

// --- trust boundary: malformed input never throws -----------------------------
test('non-finite milliunits become 0, never NaN', () => {
  assert.equal(formatMoney(NaN), '$0.00');
  assert.equal(formatMoney(undefined), '$0.00');
  assert.equal(formatMoney(Infinity), '$0.00');
});

test('a partial currency_format falls back per-field to USD', () => {
  assert.equal(formatMoney(250000, { currency_symbol: '£' }), '£250.00');
  assert.equal(formatMoney(250000, {}), '$250.00');
  assert.equal(formatMoney(250000, null), '$250.00');
});

test('resolveCurrencyFormat clamps decimal_digits into [0,3]', () => {
  assert.equal(resolveCurrencyFormat({ decimal_digits: 9 }).decimal_digits, 3);
  assert.equal(resolveCurrencyFormat({ decimal_digits: -4 }).decimal_digits, 0);
  assert.equal(resolveCurrencyFormat({}).decimal_digits, DEFAULT_CURRENCY_FORMAT.decimal_digits);
});

// --- trust boundary: a NON-NUMBER decimal_digits falls back to 2, not 0 -------
// Regression: `Number(null)` etc. are 0 and pass Number.isFinite, so a malformed
// field must be rejected on TYPE before coercion — else it silently drops to 0
// decimals instead of the promised US/USD default.
test('malformed decimal_digits (null/false/"") falls back to the default 2, not 0', () => {
  assert.equal(resolveCurrencyFormat({ decimal_digits: null }).decimal_digits, 2);
  assert.equal(resolveCurrencyFormat({ decimal_digits: false }).decimal_digits, 2);
  assert.equal(resolveCurrencyFormat({ decimal_digits: '' }).decimal_digits, 2);
  assert.equal(resolveCurrencyFormat({ decimal_digits: '2' }).decimal_digits, 2);
  assert.equal(formatMoney(250000, { decimal_digits: null }), '$250.00');
  assert.equal(formatMoney(250000, { decimal_digits: false }), '$250.00');
  // A genuine numeric 0 is still honored (JPY renders decimal-free).
  assert.equal(resolveCurrencyFormat({ decimal_digits: 0 }).decimal_digits, 0);
  assert.equal(formatMoney(1234000, { currency_symbol: '¥', decimal_digits: 0 }), '¥1,234');
});

// --- trust boundary: an EMPTY decimal_separator is absent, not "valid blank" ---
// Regression: an empty separator glued the fractional digits onto the integer
// part (`$1,23456`). It must fall back to the default when decimal_digits > 0.
test('empty decimal_separator falls back to the default separator', () => {
  assert.equal(resolveCurrencyFormat({ decimal_separator: '' }).decimal_separator, '.');
  assert.equal(
    formatMoney(1234560, { decimal_digits: 2, group_separator: ',', decimal_separator: '' }),
    '$1,234.56',
  );
});

// --- hostile group_separator: `$`-metacharacters render literally -------------
// groupThousands uses a function replacement, so a `$&`/`$1`-style separator is
// inserted verbatim rather than interpreted as a regex replacement token.
test('a $-metacharacter group_separator is inserted literally, not interpreted', () => {
  // 1_234_567_000 milliunits ÷1000 = 1234567. A string replacement would treat
  // `$&` as "the matched substring" (empty, since the lookahead is zero-width) and
  // drop all separators; the literal `$&` between every group proves otherwise.
  assert.equal(
    formatMoney(1234567000, { display_symbol: false, decimal_digits: 0, group_separator: '$&' }),
    '1$&234$&567',
  );
});

// --- OUTPUT IS NOT PRE-ESCAPED: the symbol passes through verbatim ------------
// formatMoney must NOT HTML-escape (it also feeds non-HTML surfaces); escaping a
// hostile currency_symbol is the HTML renderer's job (ynab-review.md §5/§8). Pin
// the contract so no one "fixes" it by escaping inside the helper.
test('a hostile currency_symbol is returned verbatim — the HTML boundary escapes, not formatMoney', () => {
  const hostile = { currency_symbol: '<b>&</b>', symbol_first: true, decimal_digits: 2 };
  assert.equal(formatMoney(250000, hostile), '<b>&</b>250.00');
});
