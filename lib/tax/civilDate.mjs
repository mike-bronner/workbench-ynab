// lib/tax/civilDate.mjs — the strict civil-date (YYYY-MM-DD) parser lib/tax
// shares (issue #240).
//
// WHAT THIS IS
//   One tiny, PURE parser that turns a 'YYYY-MM-DD' civil date into a UTC
//   epoch-day integer, or null when the string is not a date the calendar
//   actually has. No I/O, no host-clock read, no dependencies — so any module in
//   the tax engine can import it without dragging a subsystem along with it.
//
// WHY IT IS SHARED RATHER THAN RE-DERIVED
//   A shape-only regex (/^\d{4}-\d{2}-\d{2}$/) accepts '2025-13-45',
//   '2025-02-30' and '0000-00-00'. Those are not rejected anywhere downstream:
//   they flow into civil-date arithmetic and lexicographic date comparisons and
//   answer PLAUSIBLY BUT WRONGLY rather than failing closed — e.g. '2025-13-45'
//   sorts after every real 2025 quarterly due date ('1' > '0' in the month
//   position), so a "next payment" search silently skips Q1–Q3. Every seam that
//   re-derives the shape check drops the calendar check with it, so the check
//   lives here once and callers reuse it.
//
// TIMEZONE
//   UTC is used purely as a stable civil-date frame, never as a clock: the
//   parser reads only the string it is given. Because every operand goes through
//   the same frame, differences between two results are exact calendar-day
//   counts, independent of the host timezone.

/**
 * Parse a strict `YYYY-MM-DD` prefix into a UTC epoch-day integer.
 *
 * Rejects (returns null for) non-strings, anything without a `YYYY-MM-DD`
 * prefix, out-of-range month/day fields, and impossible civil dates — e.g.
 * `'2026-02-30'`, which `Date.UTC` would otherwise roll over into March, and
 * `'2025-02-29'` in a non-leap year.
 *
 * @param {unknown} dateISO candidate civil date.
 * @returns {number|null} whole days since 1970-01-01 (UTC frame), or null when
 *   `dateISO` is not a real calendar date.
 */
export function epochDay(dateISO) {
  if (typeof dateISO !== 'string') return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(dateISO);
  if (!m) return null;
  const y = Number(m[1]);
  const mo = Number(m[2]);
  const d = Number(m[3]);
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  const ms = Date.UTC(y, mo - 1, d);
  // Reject impossible civil dates (e.g. 2026-02-30 rolls over to March) so a
  // malformed date fails closed instead of silently shifting the window.
  const back = new Date(ms);
  if (back.getUTCFullYear() !== y || back.getUTCMonth() !== mo - 1 || back.getUTCDate() !== d) return null;
  return Math.round(ms / 86400000);
}
