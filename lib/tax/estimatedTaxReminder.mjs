// lib/tax/estimatedTaxReminder.mjs — quarterly estimated-tax reminder detector
// (issue #83, M6-5).
//
// WHAT THIS IS
//   A thin, PURE detector that decides — for a given day — whether a quarterly
//   estimated-tax payment reminder should fire, and shapes it as an M6-2 finding
//   (lib/monitor/alerts.mjs). It sits on top of two things that already exist and
//   invents neither:
//     * the tax-profile quarterly due dates (loadProfile getQuarterlyDueDates,
//       #22) — the caller resolves them and hands them in; NO quarter date is
//       hardcoded here (AC: Apr15/Jun15/Sep15/Jan15 come from config, never code);
//     * the M6-4 tracker (lib/tax/estimatedTax.mjs) — read-only, for the
//       remaining-due figure and the payment-suppression check.
//   The detector emits findings; the CALLER (the review router, M2-8) dispatches
//   them through M6-2's dispatchAlerts on the configured channel. This module
//   never dispatches, never reads the filesystem, and never touches YNAB.
//
// WHY A PURE FUNCTION
//   Every AC-mandated behaviour — the lead-time window (fires at T-leadDays, not
//   before), the due-day 🔴 escalation, payment suppression, and the enabled
//   switch — is a pure decision over (today, dueDates, tracker, config). Keeping
//   it pure makes the whole matrix unit-testable with plain objects and no I/O.
//
// TIMEZONE
//   All comparisons are civil-date (YYYY-MM-DD) arithmetic. `today` MUST already
//   be the date in the user's configured timezone — the caller computes it (the
//   review router resolves the tz and derives `today`), exactly as every other
//   date in the pipeline is tz-resolved upstream. Civil-date subtraction is
//   tz-independent, so once `today` is right the day counts are right.
//
// MONEY UNITS
//   The tracker stores plain DOLLARS (the tax engine is US-only), so amounts are
//   rendered as `$X.XX` directly — never milliunits, never formatMoney (that is
//   for multi-currency YNAB display; estimated tax is USD-only).
//
// STDOUT / STDERR DISCIPLINE
//   Pure library code: returns data, logs NOTHING to stdout. A caller invoked on
//   an MCP/JSON-RPC path keeps diagnostics to stderr only (one stray stdout byte
//   corrupts the handshake) — this module never writes either stream.
//
// NOT TAX ADVICE
//   Every finding carries the canonical compact not-tax-advice tag verbatim.

import { ACTION, ATTENTION, dedupeKey } from '../monitor/alerts.mjs';

/** The dedupe/finding type for an estimated-tax reminder (M6-2 dedupe_key). */
export const REMINDER_TYPE = 'estimated_tax_reminder';

// The canonical compact not-tax-advice tag. SINGLE SOURCE OF TRUTH:
// skills/shared/disclaimer.md — copied here byte-for-byte and pinned by a test,
// because any surface that shows a tax figure must carry this exact string.
export const DISCLAIMER_TAG =
  '⚠️ Estimates only — not tax advice. Consult a qualified professional before filing or paying.';

// --- Civil-date helpers ------------------------------------------------------

// Parse a strict YYYY-MM-DD prefix into a UTC epoch-day integer, or null. UTC is
// used purely as a stable civil-date frame (no tz influence): both operands go
// through the same frame, so the subtraction is an exact calendar-day count.
function epochDay(dateISO) {
  if (typeof dateISO !== 'string') return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(dateISO);
  if (!m) return null;
  const y = Number(m[1]);
  const mo = Number(m[2]);
  const d = Number(m[3]);
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  const ms = Date.UTC(y, mo - 1, d);
  // Reject impossible civil dates (e.g. 2026-02-30 rolls over to March) so a
  // malformed due date fails closed instead of silently shifting the window.
  const back = new Date(ms);
  if (back.getUTCFullYear() !== y || back.getUTCMonth() !== mo - 1 || back.getUTCDate() !== d) return null;
  return Math.round(ms / 86400000);
}

/** Whole calendar days from `fromISO` to `toISO` (positive when `to` is later),
 *  or null when either date is unparseable. */
export function calendarDaysBetween(fromISO, toISO) {
  const a = epochDay(fromISO);
  const b = epochDay(toISO);
  return a === null || b === null ? null : b - a;
}

// --- Money render ------------------------------------------------------------

function fmtUsd(n) {
  return `$${(Number(n) || 0).toFixed(2)}`;
}

// --- Tracker read (read-only, defensive) -------------------------------------

// Read one quarter's tracker entry, tolerating an absent/partial tracker. Never
// throws — a missing tracker just means "no estimate/payments recorded yet".
function quarterEntry(tracker, taxYear, quarter) {
  const years = tracker && typeof tracker === 'object' ? tracker.years : undefined;
  const y = years && typeof years === 'object' ? years[String(taxYear)] : undefined;
  const q = y && typeof y === 'object' ? y[String(quarter)] : undefined;
  return q && typeof q === 'object' ? q : undefined;
}

// A quarter is SUPPRESSED once at least one payment is recorded against it (AC:
// no nagging after payment). A non-array/absent payments field means none.
function hasRecordedPayment(entry) {
  return !!entry && Array.isArray(entry.payments) && entry.payments.length >= 1;
}

// --- Detector ----------------------------------------------------------------

const isInt = (v) => typeof v === 'number' && Number.isInteger(v);

/**
 * Compute the quarterly estimated-tax reminder findings for `today`.
 *
 * Fires one finding per quarter whose due date is within the reminder window and
 * which is not yet paid:
 *   * `remindersEnabled: false`            → no findings at all (the config switch).
 *   * today is in (dueDate − leadTimeDays … dueDate]  → 🟡 attention (lead-time).
 *   * today IS the due date and no payment recorded    → escalated to 🔴 action.
 *   * the quarter already has ≥1 recorded payment       → suppressed (no finding).
 *   * today is more than leadTimeDays before, or after, the due date → no finding.
 *
 * PURE: no I/O. TOTAL: malformed inputs degrade to "no reminder" (fail closed —
 * a missing/unparseable date never fabricates a nudge) rather than throwing.
 *
 * @param {object} args
 * @param {string} args.today            today's civil date (YYYY-MM-DD) in the user's tz.
 * @param {Array}  args.dueDates         resolved due dates: [{ quarter, date, taxYear }, …]
 *   (caller maps loadProfile().getQuarterlyDueDates(y) and attaches taxYear).
 * @param {object} [args.tracker]        loadTracker() state (read-only) for suppression + amounts.
 * @param {number} args.leadTimeDays     lead-time window in calendar days (integer ≥ 0).
 * @param {boolean} args.remindersEnabled master switch (alerts.tax.reminders_enabled).
 * @returns {Array<object>} M6-2 findings (possibly empty), most urgent naturally first.
 */
export function computeQuarterlyTaxReminders({
  today,
  dueDates = [],
  tracker = null,
  leadTimeDays = 0,
  remindersEnabled = false,
} = {}) {
  if (remindersEnabled !== true) return [];
  if (epochDay(today) === null) return []; // fail closed: no valid "today", no nudge
  // A negative or non-integer lead time is meaningless; floor to a safe 0 so the
  // due-day reminder still fires but no spurious early window opens.
  const lead = isInt(leadTimeDays) && leadTimeDays >= 0 ? leadTimeDays : 0;

  const findings = [];
  for (const d of Array.isArray(dueDates) ? dueDates : []) {
    if (!d || typeof d !== 'object') continue;
    const { quarter, date, taxYear } = d;
    if (!isInt(quarter) || quarter < 1 || quarter > 4) continue;
    if (taxYear == null) continue;

    const daysUntil = calendarDaysBetween(today, date);
    if (daysUntil === null) continue;                 // unparseable due date → skip
    if (daysUntil < 0 || daysUntil > lead) continue;  // outside [due − lead, due]

    const entry = quarterEntry(tracker, taxYear, quarter);
    if (hasRecordedPayment(entry)) continue;          // suppressed — already paid

    const onDueDate = daysUntil === 0;
    const label = `Q${quarter} ${taxYear}`;
    // remaining_due is the outstanding estimate; the recommended payment is that
    // same balance (pay it to clear the quarter). They coincide by construction —
    // suppression removes the finding the moment any payment lands, so a firing
    // reminder always sees zero payments and remaining_due === estimated_liability.
    const hasAmount = entry != null && typeof entry.remaining_due === 'number';
    const remainingStr = hasAmount ? fmtUsd(entry.remaining_due) : null;

    const title = onDueDate
      ? `Estimated tax ${label} is due today (${date}).`
      : `Estimated tax ${label} is due ${date} — ${daysUntil} day${daysUntil === 1 ? '' : 's'} away.`;

    const suggestedAction = hasAmount
      ? `Remaining due ${remainingStr}; recommended payment ${remainingStr} before ${date}. ${DISCLAIMER_TAG}`
      : `Run /ynab-tax to compute the amount, then pay before ${date}. ${DISCLAIMER_TAG}`;

    findings.push({
      daysUntil,
      finding: {
        severity: onDueDate ? ACTION : ATTENTION,
        title,
        detail: [
          `quarter=${label}`,
          `due=${date}`,
          `days_until=${daysUntil}`,
          `remaining_due=${hasAmount ? entry.remaining_due : 'unknown'}`,
          `phase=${onDueDate ? 'due-day' : 'lead-time'}`,
          'payment_recorded=false',
        ].join('; '),
        suggested_action: suggestedAction,
        // Distinct lead-time vs due-day keys so the due-day 🔴 can still fire on the
        // deadline even though the lead-time 🟡 already fired earlier in the window.
        dedupe_key: dedupeKey(REMINDER_TYPE, `Q${quarter}-${onDueDate ? 'due' : 'lead'}`, String(taxYear)),
      },
    });
  }
  // Most urgent first: ascending by days-until-due so a due-day (0) reminder always
  // precedes a farther one. Without this the emission order is dueDates order — and
  // when quarters from two tax years are simultaneously in-window (a large
  // leadTimeDays), the far-off one could sort ahead of the near one and be dropped
  // by dispatchAlerts' MAX_FINDINGS cap (it sorts by severity only, preserving input
  // order within a severity). Stable sort keeps same-day findings in dueDates order.
  return findings.sort((a, b) => a.daysUntil - b.daysUntil).map((f) => f.finding);
}

/**
 * Resolve the candidate due dates that could reach `today`: this tax year's four
 * quarters PLUS last tax year's (whose Q4 falls on Jan 15 of THIS calendar year,
 * so a January `today` still sees the prior year's Q4 deadline). Each entry is
 * stamped with the `taxYear` it belongs to — the label and the tracker lookup
 * both key on the tax year, not the due date's calendar year.
 *
 * @param {(year:number)=>Array} getQuarterlyDueDates loadProfile accessor.
 * @param {number} calendarYear today's calendar year (in the user's tz).
 * @returns {Array<{quarter:number, date:string, taxYear:number}>}
 */
export function resolveCandidateDueDates(getQuarterlyDueDates, calendarYear) {
  if (typeof getQuarterlyDueDates !== 'function' || !isInt(calendarYear)) return [];
  const out = [];
  for (const taxYear of [calendarYear, calendarYear - 1]) {
    for (const d of getQuarterlyDueDates(taxYear) ?? []) {
      if (d && isInt(d.quarter) && typeof d.date === 'string') {
        out.push({ quarter: d.quarter, date: d.date, taxYear });
      }
    }
  }
  return out;
}

export default {
  REMINDER_TYPE,
  DISCLAIMER_TAG,
  calendarDaysBetween,
  computeQuarterlyTaxReminders,
  resolveCandidateDueDates,
};
