// lib/tax/taxYear.mjs — the ACTIVE TAX YEAR resolution rule (issue #17, GAP-15).
//
// WHAT THIS IS
//   The single place that answers "which tax year is this review about?", plus
//   the year-boundary rule that governs early January. Two facts drive every
//   answer, and nothing else does:
//     • the REVIEW DATE, converted to the configured IANA timezone, and
//     • an OPTIONAL explicit `tax_year` override from config.json.
//
// WHAT IS NOT AN INPUT — the budget NAME
//   The prototype budget is literally named 'Personal 2024'. Reading a year out
//   of a budget's display name conflates a label the user may rename at any time
//   with a tax fact, and it silently keeps answering 2024 forever. The budget
//   name is DISPLAY-ONLY: no function here accepts it, parses it, or receives it.
//
// WHY THE TIMEZONE IS REQUIRED, NOT OPTIONAL
//   Near midnight on Dec 31 / Jan 1 the host clock and the user's configured zone
//   disagree about the calendar YEAR, not just the day — the difference is a whole
//   tax year of figures. So `timezone` is a required argument on the public
//   resolvers, and an absent or bogus zone THROWS rather than falling back to the
//   host zone (issue #31's fail-closed rule, applied at the tax-year seam).
//
// THE YEAR-BOUNDARY (CHANGEOVER) RULE
//   A single tax year's four estimated-tax due dates span TWO calendar years: for
//   the US federal schedule, Apr 15 / Jun 15 / Sep 15 of year N and Jan 15 of year
//   N+1. So between Jan 1 and the day before that wrapping due date, a review has
//   two live tax years at once — year N is not finished (its Q4 payment has not
//   cleared) while year N+1 has already begun. In that window the review surfaces
//   BOTH: the prior year's close-out figures and the new year's opening state.
//   The window's end is DERIVED from the profile's own quarterly schedule (the
//   quarter whose due date wraps past the calendar year end), never hardcoded —
//   no month, day, or year literal for any tax deadline appears in this module.

import { epochDay } from './civilDate.mjs';
import { wrappingQuarterDue } from './estimatedTax.mjs';

// A civil date the rest of lib/tax can compare lexicographically: 'YYYY-MM-DD'.
const CIVIL_DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

// An INSTANT: a civil date-time carrying an explicit UTC offset or 'Z'. A naive
// date-time ('2025-12-31T23:30:00', no offset) is deliberately NOT matched — it
// names no point in time, so converting it to a zone would invent an answer.
const INSTANT_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/;

// Tax years are rendered into 'YYYY-MM-DD' due-date strings that lib/tax compares
// LEXICOGRAPHICALLY, so a year outside four digits would break those comparisons
// (e.g. '999-04-15' sorts before every four-digit date). Four digits is therefore
// a correctness bound, not a taste bound.
const MIN_YEAR = 1000;
const MAX_YEAR = 9999;

/**
 * Reject a timezone that is not a usable IANA zone identifier, THEN confirm the
 * runtime itself accepts it. The structural rules mirror `bin/config.sh`'s
 * `_is_valid_timezone` deny-list (issue #31, review round 3) so the shell gate and
 * this one agree about what a zone is: no absolute path, no traversal, no trailing
 * slash, only IANA name characters, and none of the non-selectable build artifacts
 * (`Factory`, `posixrules`) or leap-second / POSIX mirror subtrees (`right/`,
 * `posix/`) that resolve to a UTC-equivalent date and so re-leak exactly the
 * host-clock answer the configured zone exists to prevent. Matching is case-folded
 * for the same reason the shell folds it: a case-insensitive filesystem resolves
 * `factory` to the real `Factory` zone.
 *
 * @param {unknown} timezone candidate IANA zone identifier.
 * @throws {Error} when `timezone` is absent, misshapen, denied, or unknown.
 */
function requireTimezone(timezone) {
  if (typeof timezone !== 'string' || timezone.length === 0) {
    throw new Error(
      `resolveTaxYear requires an IANA timezone (config.timezone); got ${JSON.stringify(timezone)}. ` +
        'The tax year is the calendar year IN THAT ZONE — falling back to the host zone would ' +
        'answer the wrong year near midnight on Dec 31 / Jan 1.',
    );
  }
  const denied =
    timezone.startsWith('/') ||
    timezone.includes('..') ||
    timezone.endsWith('/') ||
    /[^A-Za-z0-9_/+-]/.test(timezone);
  const lower = timezone.toLowerCase();
  const mirrored = lower.startsWith('right/') || lower.startsWith('posix/');
  const base = lower.slice(lower.lastIndexOf('/') + 1);
  const pseudo = base === 'factory' || base === 'posixrules';
  if (denied || mirrored || pseudo) {
    throw new Error(
      `resolveTaxYear rejected timezone ${JSON.stringify(timezone)}: not a selectable IANA zone ` +
        '(paths, traversal, non-IANA characters, the right//posix/ mirrors, and the Factory / ' +
        'posixrules build artifacts are refused — they resolve to a UTC-equivalent date).',
    );
  }
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: timezone });
  } catch {
    throw new Error(
      `resolveTaxYear rejected timezone ${JSON.stringify(timezone)}: the runtime does not know ` +
        'this zone. Use a zoneinfo name like America/Phoenix or UTC.',
    );
  }
}

/**
 * The civil date (`YYYY-MM-DD`) that `reviewDate` falls on IN `timezone`.
 *
 * Accepts either an already-civil `'YYYY-MM-DD'` string — the shape
 * `bin/config.sh`'s `_today_in_tz` produces, already resolved in the configured
 * zone, so the conversion is the identity — or an INSTANT (a `Date`, or a
 * date-time string with an explicit offset / `Z`), which is converted. A naive
 * date-time without an offset is REFUSED: it names no instant, so no zone can
 * place it on a calendar day without guessing.
 *
 * @param {unknown} reviewDate civil date, `Date`, or offset-bearing date-time.
 * @param {string}  timezone   validated IANA zone identifier.
 * @returns {string} the civil date in `timezone`.
 * @throws {Error} when `reviewDate` is not a real date in an accepted shape.
 */
function civilDateInZone(reviewDate, timezone) {
  if (typeof reviewDate === 'string' && CIVIL_DATE_RE.test(reviewDate)) {
    // Already a civil date in the caller's configured zone. epochDay rejects the
    // well-shaped impossibilities ('2025-13-45', '2025-02-30') that would otherwise
    // compare happily against real due dates and answer plausibly but wrongly.
    if (epochDay(reviewDate) === null) {
      throw new Error(
        `resolveTaxYear received ${JSON.stringify(reviewDate)}, which is not a date the calendar has.`,
      );
    }
    return reviewDate;
  }

  let instant = null;
  if (reviewDate instanceof Date) instant = reviewDate;
  else if (typeof reviewDate === 'string' && INSTANT_RE.test(reviewDate)) instant = new Date(reviewDate);

  if (instant === null || Number.isNaN(instant.getTime())) {
    throw new Error(
      `resolveTaxYear requires a review date as 'YYYY-MM-DD', a Date, or a date-time carrying an ` +
        `explicit UTC offset or 'Z'; got ${JSON.stringify(reviewDate)}. A date-time without an offset ` +
        'names no instant, so no timezone can place it on a calendar day.',
    );
  }

  // formatToParts, not a formatted string: the parts are locale-independent, so
  // the extracted year/month/day never depend on how a locale orders or decorates
  // its date pattern.
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: timezone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(instant);
  const field = (type) => parts.find((p) => p.type === type)?.value ?? '';
  return `${field('year').padStart(4, '0')}-${field('month')}-${field('day')}`;
}

/**
 * The ACTIVE TAX YEAR for a review: the calendar year that `reviewDate` falls in
 * WHEN CONVERTED TO `timezone`, or `taxYearOverride` when the user pinned one in
 * `config.json` (`tax_year`).
 *
 * The budget's display name is not an input and is never parsed.
 *
 * Fails closed on every bad input — an absent/unknown zone, an unparseable or
 * impossible review date, or an override that is not a four-digit integer — rather
 * than falling back to the host clock or silently ignoring a malformed override.
 *
 * @param {string|Date} reviewDate      `'YYYY-MM-DD'`, a `Date`, or an offset-bearing date-time.
 * @param {string}      timezone        IANA zone identifier (`config.timezone`).
 * @param {number}      [taxYearOverride] explicit `config.tax_year`, when the user set one.
 * @returns {number} the four-digit tax year.
 * @throws {Error} on an invalid timezone, review date, or override.
 */
export function resolveTaxYear(reviewDate, timezone, taxYearOverride) {
  requireTimezone(timezone);
  if (taxYearOverride !== undefined && taxYearOverride !== null) {
    if (!Number.isInteger(taxYearOverride) || taxYearOverride < MIN_YEAR || taxYearOverride > MAX_YEAR) {
      throw new Error(
        `config.tax_year must be a four-digit integer year; got ${JSON.stringify(taxYearOverride)}. ` +
          'A malformed override is refused rather than ignored — silently falling back to the review ' +
          "date would answer a different year than the user asked for, with no signal.",
      );
    }
    return taxYearOverride;
  }
  return Number(civilDateInZone(reviewDate, timezone).slice(0, 4));
}

/**
 * @typedef {object} YearBoundary The year-changeover state of one review.
 * @property {number}  taxYear           the active tax year (from {@link resolveTaxYear}).
 * @property {?number} priorTaxYear      the still-open prior tax year during the changeover, else null.
 * @property {boolean} inChangeover      true while BOTH years are live (see the rule below).
 * @property {?string} changeoverThrough `'YYYY-MM-DD'` — the prior year's wrapping due date, else null.
 * @property {string}  reviewDate        the review's civil date in the configured timezone.
 * @property {string}  headerLabel       the report-header label; names BOTH years during the changeover.
 */

/**
 * Decide the year-boundary state for a review whose civil date is ALREADY resolved
 * in the configured timezone — the core shared by {@link resolveYearBoundary} and
 * the engine facade's `computeTaxSummary` (whose `asOfDate` is a civil date by
 * contract, so it needs no second timezone conversion).
 *
 * The changeover is live when BOTH hold:
 *   1. the active tax year equals the review's own calendar year — a review with an
 *      explicit override pinning a DIFFERENT year is already a single-year,
 *      prior-year run and needs no dual framing; and
 *   2. the review date falls before the wrapping quarter's due date in that calendar
 *      year — i.e. the prior year's final estimated payment has not come due yet.
 *
 * A schedule with no wrapping quarter (every due date inside its own tax year)
 * yields `inChangeover: false` — a real answer, not a fallback: with no cross-year
 * quarter there is no window in which two tax years are both live.
 *
 * @param {string} civilDate `'YYYY-MM-DD'` review date, already in the configured zone.
 * @param {number} taxYear   the resolved active tax year.
 * @param {Array}  dueDates  `profile.quarterlyEstimatedDueDates` (month/day/quarter entries).
 * @returns {YearBoundary}
 * @throws {Error} when `dueDates` carries no usable quarterly schedule — the boundary
 *   question cannot be answered without one, and answering "no changeover" would be
 *   indistinguishable from a real "no".
 */
export function yearBoundaryForCivilDate(civilDate, taxYear, dueDates) {
  const wrap = wrappingQuarterDue(dueDates);
  if (wrap === null && !hasUsableSchedule(dueDates)) {
    throw new Error(
      'resolving the tax-year boundary requires the profile quarterly due-date schedule ' +
        '(quarterlyEstimatedDueDates with month/day/quarter); got none. Without it the Jan-window ' +
        'changeover cannot be distinguished from "no changeover".',
    );
  }

  const reviewYear = Number(civilDate.slice(0, 4));
  let inChangeover = false;
  let changeoverThrough = null;
  if (wrap !== null && taxYear === reviewYear) {
    const mm = String(wrap.month).padStart(2, '0');
    const dd = String(wrap.day).padStart(2, '0');
    // The wrapping quarter belongs to the PRIOR tax year but comes due in this
    // calendar year — the year number is derived from the review, never hardcoded.
    const wrapDue = `${reviewYear}-${mm}-${dd}`;
    if (civilDate < wrapDue) {
      inChangeover = true;
      changeoverThrough = wrapDue;
    }
  }

  const priorTaxYear = inChangeover ? taxYear - 1 : null;
  const headerLabel = inChangeover
    ? `Tax Year ${taxYear} (${priorTaxYear} close-out through ${changeoverThrough})`
    : `Tax Year ${taxYear}`;

  return { taxYear, priorTaxYear, inChangeover, changeoverThrough, reviewDate: civilDate, headerLabel };
}

// True when the schedule holds at least one entry the due-date math can use. Kept
// separate from wrappingQuarterDue's null so an EMPTY schedule (unanswerable) is
// distinguished from a complete in-year schedule that simply never wraps.
function hasUsableSchedule(dueDates) {
  return (
    Array.isArray(dueDates) &&
    dueDates.some((d) => d && d.month != null && d.day != null && d.quarter != null)
  );
}

/**
 * The year-boundary state for a review, resolving the tax year and the timezone
 * conversion first. The public entry point for callers holding a raw review date
 * and the user's config.
 *
 * @param {string|Date} reviewDate      `'YYYY-MM-DD'`, a `Date`, or an offset-bearing date-time.
 * @param {string}      timezone        IANA zone identifier (`config.timezone`).
 * @param {Array}       dueDates        `profile.quarterlyEstimatedDueDates`.
 * @param {number}      [taxYearOverride] explicit `config.tax_year`, when the user set one.
 * @returns {YearBoundary}
 * @throws {Error} on an invalid timezone, review date, override, or empty schedule.
 */
export function resolveYearBoundary(reviewDate, timezone, dueDates, taxYearOverride) {
  const taxYear = resolveTaxYear(reviewDate, timezone, taxYearOverride);
  return yearBoundaryForCivilDate(civilDateInZone(reviewDate, timezone), taxYear, dueDates);
}
