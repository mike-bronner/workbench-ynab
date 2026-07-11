'use strict';

/**
 * format-money.js — the single shared money helper for workbench-ynab (issue #34,
 * ROADMAP #8, changeset-contract §2).
 *
 * Centralizes the milliunits → currency-string conversion so NO surface hardcodes
 * `$`, a comma, a period, or two decimals. Every rendered amount — the universal
 * review report, the write-path dry-run diffs — goes through `formatMoney` and is
 * driven entirely by the budget's own `currency_format`, so a non-USD budget
 * renders with the correct symbol, symbol placement, separators, and decimal
 * digits (issue #34, v1 posture: option A — render non-USD correctly).
 *
 * SCOPE. This helper fixes currency PRESENTATION only. The tax engine
 * (lib/tax/*) is US-only by construction and is NOT extended here — it stays
 * dollar-denominated regardless of the budget currency (see README scope and
 * skills/review/ynab-review.md §5).
 *
 * MONEY IS ALWAYS MILLIUNITS. The ÷1000 conversion happens HERE and nowhere on
 * an apply/compute path (changeset-contract §2). Callers pass raw integer
 * milliunits; only DISPLAY divides.
 *
 * TRUST BOUNDARY. `currencyFormat` originates from the YNAB API `currency_format`
 * object (an off-the-wire, less-trusted source). Every field is read totally: a
 * missing, null, or malformed field falls back to its US/USD default rather than
 * throwing, so a partial or surprising API response can never crash a render.
 * `milliunits` that is not a finite number becomes `0` (never `NaN`), matching
 * the milliToDollars convention in lib/tax/estimatedTax.mjs.
 */

/**
 * The US/USD default `currency_format`. Used per-field when a caller passes no
 * currency format (e.g. the write-path dry-run, which does not fetch budget
 * settings) or an incomplete one. Reproduces the pre-#34 hardcoded output
 * (`$1,234.56`) exactly, so callers that default to USD are behaviour-preserving.
 */
const DEFAULT_CURRENCY_FORMAT = Object.freeze({
  iso_code: 'USD',
  currency_symbol: '$',
  symbol_first: true,
  decimal_digits: 2,
  group_separator: ',',
  decimal_separator: '.',
  display_symbol: true,
});

/** YNAB caps currency precision at 3 decimal digits; clamp to a safe integer range. */
const MAX_DECIMAL_DIGITS = 3;
const MILLI = 1000;

/**
 * Resolve a raw `currency_format` object into a total, field-complete shape by
 * layering it over the USD default. Reads `currency_symbol` (the canonical YNAB
 * field) but also accepts `symbol` as an alias so a caller that follows the
 * issue's shorthand still renders a symbol. Every field is coerced to a safe type.
 * @param {object} [cf] a YNAB `currency_format` object (or partial/undefined).
 * @returns {{currency_symbol:string, symbol_first:boolean, decimal_digits:number,
 *   group_separator:string, decimal_separator:string, display_symbol:boolean}}
 */
function resolveCurrencyFormat(cf) {
  const raw = cf && typeof cf === 'object' ? cf : {};
  const symbol =
    typeof raw.currency_symbol === 'string' ? raw.currency_symbol
      : typeof raw.symbol === 'string' ? raw.symbol
        : DEFAULT_CURRENCY_FORMAT.currency_symbol;

  let digits = Number(raw.decimal_digits);
  digits = Number.isFinite(digits) ? Math.min(Math.max(Math.trunc(digits), 0), MAX_DECIMAL_DIGITS)
    : DEFAULT_CURRENCY_FORMAT.decimal_digits;

  return {
    currency_symbol: symbol,
    symbol_first: typeof raw.symbol_first === 'boolean' ? raw.symbol_first : DEFAULT_CURRENCY_FORMAT.symbol_first,
    decimal_digits: digits,
    group_separator: typeof raw.group_separator === 'string' ? raw.group_separator : DEFAULT_CURRENCY_FORMAT.group_separator,
    decimal_separator: typeof raw.decimal_separator === 'string' ? raw.decimal_separator : DEFAULT_CURRENCY_FORMAT.decimal_separator,
    display_symbol: typeof raw.display_symbol === 'boolean' ? raw.display_symbol : DEFAULT_CURRENCY_FORMAT.display_symbol,
  };
}

/**
 * Group an integer-part string in threes with a separator (locale-driven).
 * `1234` + `.` → `1.234`. An empty separator yields no grouping.
 * @param {string} intDigits the absolute integer part as decimal digits.
 * @param {string} sep the group separator.
 * @returns {string}
 */
function groupThousands(intDigits, sep) {
  return intDigits.replace(/\B(?=(\d{3})+(?!\d))/g, sep);
}

/**
 * Format raw YNAB milliunits as a human-readable currency string, driven entirely
 * by `currencyFormat`. DISPLAY-ONLY: the ÷1000 conversion happens here and never
 * on an apply/compute path.
 *
 * Integer arithmetic throughout (no `toFixed`, no float round-trip): milliunits
 * are rounded to the currency's minor unit via an integer divisor, so the divisor
 * stays 1000 (YNAB-universal) while `decimal_digits` alone governs rounding —
 * `decimal_digits` may be 0 (e.g. JPY, no decimals), 2 (USD/EUR), or 3.
 *
 * Layout follows the issue's reference outputs: symbol adjacent when
 * `symbol_first` (`$250.00`, `-$54.99`), and a space before a trailing symbol
 * (`1.234,56 €`, `-1.234,56 €`). When `display_symbol` is false the symbol (and
 * its space) is omitted entirely.
 *
 * @param {number} milliunits raw integer milliunits (non-finite → 0).
 * @param {object} [currencyFormat] a YNAB `currency_format` object; USD when omitted.
 * @returns {string}
 */
function formatMoney(milliunits, currencyFormat) {
  const cf = resolveCurrencyFormat(currencyFormat);
  const amount = Number.isFinite(milliunits) ? milliunits : 0;

  const pow = 10 ** cf.decimal_digits; // minor units per whole unit (1, 100, 1000)
  const divisor = MILLI / pow; // integer for decimal_digits in [0, 3]
  const minorUnits = Math.round(amount / divisor);

  const sign = minorUnits < 0 ? '-' : '';
  const absMinor = Math.abs(minorUnits);
  const intPart = Math.floor(absMinor / pow);
  const fracPart = absMinor % pow;

  let number = groupThousands(String(intPart), cf.group_separator);
  if (cf.decimal_digits > 0) {
    number += cf.decimal_separator + String(fracPart).padStart(cf.decimal_digits, '0');
  }

  if (!cf.display_symbol || cf.currency_symbol === '') {
    return `${sign}${number}`;
  }
  return cf.symbol_first ? `${sign}${cf.currency_symbol}${number}` : `${sign}${number} ${cf.currency_symbol}`;
}

module.exports = { formatMoney, resolveCurrencyFormat, DEFAULT_CURRENCY_FORMAT };
