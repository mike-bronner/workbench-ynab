// lib/tax/civilDate.mjs — the ONE strict civil-date parser for lib/tax
// (issues #240, #263).
//
// WHAT THIS IS
//   A single, shared, calendar-validating parser for `YYYY-MM-DD` civil-date
//   strings. Every date seam in lib/tax routes through it instead of re-deriving
//   a regex, so the calendar check can never be silently dropped again.
//
// WHY IT EXISTS
//   lib/tax grew two competing patterns. The correct one (this module's ancestor,
//   the module-private `epochDay` in estimatedTaxReminder.mjs) round-tripped
//   through Date.UTC to reject impossible civil dates. The other — a bare
//   `/^(\d{4})-(\d{2})-(\d{2})/` shape check — accepted `'2025-13-45'` and
//   `'2025-02-30'` and let them flow into date arithmetic that then answered
//   PLAUSIBLY BUT WRONGLY (a quarter number, not an error). Because the strict
//   version was module-private, there was nothing shared to reach for and each
//   new seam re-derived the weak one. Promoting it here is the fix that makes the
//   invariant stick: there is now one obvious thing to import.
//
// STRICTNESS — WHAT IS REJECTED
//   * anything that is not a string;
//   * anything not EXACTLY `YYYY-MM-DD` (the match is anchored at both ends, so
//     trailing junk like `'2025-04-155'` is refused — every civil date in this
//     codebase is built date-only: loadProfile's `${year}-${mm}-${dd}`, the
//     facade's `toISOString().slice(0, 10)`, and YNAB's date-only `tx.date`);
//   * out-of-range month/day (`'2025-13-45'`, `'0000-00-00'`);
//   * impossible-but-well-shaped calendar dates (`'2025-02-30'`, which Date.UTC
//     would otherwise roll over into March and answer as a real date);
//   * years 0000–0099, which JS's Date maps into 1900–1999 — the round-trip
//     catches the remap and refuses rather than silently reading `'0050-01-01'`
//     as 1950. No real tax date lives there, so fail-closed is right.
//
// FAIL CLOSED
//   Returns `null` for every rejection — never throws, never a partial result,
//   never a "best effort" date. Callers turn that null into their own documented
//   refusal (no quarter, no reminder, no day count), so a malformed date can
//   never fabricate an answer.
//
// UTC AS A FRAME, NOT A TIMEZONE
//   `epochDay` uses UTC purely as a stable civil-date frame — no timezone
//   influence. Both operands of any subtraction pass through the same frame, so
//   the difference is an exact calendar-day count regardless of the user's tz.
//   Callers are responsible for handing in dates already resolved to the user's
//   timezone (see estimatedTaxReminder.mjs's TIMEZONE note).
//
// PURITY
//   Pure and total: no I/O, no globals, no stdout/stderr. Safe on an MCP/JSON-RPC
//   path.

// Exactly YYYY-MM-DD, anchored at both ends. Shape only — the calendar check is
// the Date.UTC round-trip below, and is NOT optional.
const CIVIL_DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;

const MS_PER_DAY = 86400000;

/**
 * Parse a strict `YYYY-MM-DD` civil date, rejecting impossible calendar dates.
 *
 * @param {string} dateISO civil date, exactly `YYYY-MM-DD`.
 * @returns {{year:number, month:number, day:number, epochDay:number}|null}
 *   the parsed parts (`month` 1–12, `day` 1–31) plus the UTC epoch-day integer,
 *   or `null` when `dateISO` is not a real calendar date.
 */
export function parseCivilDate(dateISO) {
  if (typeof dateISO !== 'string') return null;
  const m = CIVIL_DATE_RE.exec(dateISO);
  if (!m) return null;
  const year = Number(m[1]);
  const month = Number(m[2]);
  const day = Number(m[3]);
  const ms = Date.UTC(year, month - 1, day);
  // THE calendar check, and the only one needed. Date.UTC normalizes anything
  // out of range instead of rejecting it, so every bad value lands on a DIFFERENT
  // real date than the one asked for — 2026-02-30 rolls into March, month 13 into
  // the next year, month 00 into the previous one, day 00 into the prior month's
  // last day. Comparing the components back therefore subsumes an explicit
  // 1–12 / 1–31 range test: if any component changed, the input was not a real
  // civil date and we fail closed rather than silently answer with another day.
  const back = new Date(ms);
  if (back.getUTCFullYear() !== year || back.getUTCMonth() !== month - 1 || back.getUTCDate() !== day) {
    return null;
  }
  return { year, month, day, epochDay: Math.round(ms / MS_PER_DAY) };
}

/**
 * The UTC epoch-day integer for a strict `YYYY-MM-DD` civil date.
 *
 * The day-count half of {@link parseCivilDate}, for the seams that subtract two
 * dates rather than read their parts (`calendarDaysBetween`, the review-date
 * gate). Derived from the one parser above — never a second implementation — so
 * the calendar check can not drift between the two entry points.
 *
 * @param {unknown} dateISO candidate civil date.
 * @returns {number|null} whole days since 1970-01-01 (UTC frame), or `null` when
 *   `dateISO` is not a real calendar date.
 */
export function epochDay(dateISO) {
  return parseCivilDate(dateISO)?.epochDay ?? null;
}

export default { parseCivilDate, epochDay };

