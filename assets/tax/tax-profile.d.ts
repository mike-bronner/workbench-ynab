/**
 * Type definitions for the workbench-ynab tax profile.
 *
 * This is a GENERIC, shareable shape — nothing here is specific to one
 * taxpayer. A real taxpayer's numbers are one INSTANCE of `TaxProfile`
 * (see issue M3-5), never baked into types or prompts.
 *
 * The canonical source of truth is `tax-profile.schema.json` (JSON Schema
 * draft 2020-12) in this same directory. Keep the two in sync: when the
 * schema changes, update these types (and bump `schemaVersion`).
 *
 * MONEY UNITS: every amount in this profile is in DOLLARS, not YNAB
 * milliunits. The YNAB MCP returns milliunits — divide by 1000 to get
 * dollars before comparing against anything here.
 *
 * This is a declaration file only (`.d.ts`): it carries ZERO runtime
 * overhead and is imported purely for compile-time/JSDoc typing by the
 * engine code (issue M3-3).
 */

/** Federal filing status. */
export type FilingStatus =
  /** Single. */
  | "single"
  /** Married Filing Jointly. */
  | "mfj"
  /** Married Filing Separately. */
  | "mfs"
  /** Head of Household. */
  | "hoh"
  /** Qualifying Surviving Spouse (formerly Qualifying Widow(er)). */
  | "qw";

/**
 * Standard-deduction lookup keyed by filing status, then by four-digit
 * tax-year string. Values are dollar amounts — not YNAB milliunits
 * (divide YNAB milliunits by 1000 to get dollars).
 */
export type StandardDeductionByYear = {
  [status in FilingStatus]?: {
    /** Four-digit year string (e.g. "2025") → standard deduction in dollars. */
    [year: string]: number;
  };
};

/**
 * Mapping from a business entity's YNAB expense category-groups onto
 * schedule line items. The detailed shape is owned by issue M3-2 (mapping
 * engine); kept open here so M3-2 can define its internals without bumping
 * this schema.
 */
export interface ScheduleLineMap {
  [key: string]: unknown;
}

/** A sole-prop / pass-through business entity the taxpayer files for. */
export interface BusinessEntity {
  /** Stable, opaque identifier (placeholder example: `"biz-a"`). */
  id: string;
  /**
   * Free-text label. MUST be a placeholder (e.g. `"Business A"`) in the
   * schema, defaults, and examples — never a real business name.
   */
  displayName: string;
  /** IRS schedule this entity files on, e.g. `"C"`. */
  schedule: string;
  /** YNAB category-group → schedule-line mapping (shape owned by M3-2). */
  scheduleLineMap: ScheduleLineMap;
}

/** A Schedule A category that maps YNAB category-groups onto a deduction line. */
export interface ItemizedCategory {
  /** YNAB category-group names whose transactions feed this deduction. */
  categoryGroups?: string[];
  [key: string]: unknown;
}

/** Schedule A SALT category, with its own deduction cap. */
export interface ItemizedSalt extends ItemizedCategory {
  /**
   * Maximum deductible SALT in dollars, not YNAB milliunits (divide YNAB
   * milliunits by 1000 to get dollars). Federal cap is 10000 (5000 if MFS).
   */
  saltCap?: number;
}

/** Schedule A (itemized deductions) configuration. */
export interface Itemized {
  /** Medical & dental expenses (deductible above `thresholds.medicalAgiPercent` of AGI). */
  medical?: ItemizedCategory;
  /** State-and-local taxes, capped at `salt.saltCap`. */
  salt?: ItemizedSalt;
  /** Home mortgage / HELOC interest. */
  interest?: ItemizedCategory;
  /** Charitable contributions. */
  charitable?: ItemizedCategory;
}

/** Toggle for the (derived) one-half-of-SE-tax adjustment. */
export interface SeTaxHalfDeduction {
  /** Whether to apply the one-half-of-SE-tax adjustment. */
  enabled?: boolean;
}

/** A Schedule 1 adjustment that carries a user-supplied dollar amount. */
export interface AdjustmentAmount {
  /**
   * Amount in dollars, not YNAB milliunits (divide YNAB milliunits by 1000
   * to get dollars).
   */
  amount?: number;
}

/** Schedule 1 adjustments to income (above-the-line deductions). */
export interface Adjustments {
  /** One-half of self-employment tax (derived from computed SE tax). */
  seTaxHalfDeduction?: SeTaxHalfDeduction;
  /** Student loan interest deduction. */
  studentLoanInterest?: AdjustmentAmount;
  /** Deductible traditional-IRA contributions. */
  iraContributions?: AdjustmentAmount;
}

/** Tunable tax thresholds and rates. Rates are fractions; `saltCap` is dollars. */
export interface Thresholds {
  /** Medical-expense AGI floor as a fraction (default 0.075 = 7.5%). Not dollars. */
  medicalAgiPercent?: number;
  /** Combined SE tax rate as a fraction (default 0.153 = 15.3%). Not dollars. */
  seTaxRate?: number;
  /**
   * Default SALT cap in dollars, not YNAB milliunits (divide YNAB milliunits
   * by 1000 to get dollars). Default 10000.
   */
  saltCap?: number;
}

/**
 * One federal quarterly estimated-tax due date, as explicit calendar parts.
 * Q1–Q3 fall in the tax year (Apr 15 / Jun 15 / Sep 15); Q4 falls in January
 * of the FOLLOWING year (Jan 15). The consumer combines each part-set with the
 * correct calendar year and handles weekend/holiday shifting.
 *
 * The optional `period*` fields encode the UNEVEN income-attribution window for
 * the quarter (Q1 = Jan–Mar, Q2 = Apr–May, Q3 = Jun–Aug, Q4 = Sep–Dec), stored
 * as data so they stay adjustable for IRS calendar shifts. `periodEndMonth` for
 * Q4 is December of the tax year — the Jan 15 due date is not the period end.
 */
export interface QuarterlyEstimatedDueDate {
  /** Estimated-tax quarter, 1–4. */
  quarter: number;
  /** Calendar month, 1 (January) – 12 (December). */
  month: number;
  /** Calendar day of month, 1–31. */
  day: number;
  /** Month (1–12) the income-attribution period for this quarter starts on. */
  periodStartMonth?: number;
  /** Day of month (1–31) the income-attribution period for this quarter starts on. */
  periodStartDay?: number;
  /** Month (1–12) the income-attribution period for this quarter ends on (inclusive). */
  periodEndMonth?: number;
  /** Day of month (1–31) the income-attribution period for this quarter ends on (inclusive). */
  periodEndDay?: number;
}

/**
 * One federal income-tax marginal bracket. The top (highest) bracket OMITS
 * `upTo` to mean unbounded. `rate` is a fraction (0.22 = 22%), not dollars or a
 * percentage; `upTo` is the inclusive upper bound of taxable income in dollars.
 */
export interface IncomeTaxBracket {
  /** Inclusive upper bound of taxable income (dollars). Omit on the top bracket. */
  upTo?: number;
  /** Marginal rate for this bracket as a fraction (0.22 = 22%). */
  rate: number;
}

/**
 * Federal income-tax marginal brackets keyed by filing status, then by
 * four-digit tax-year string. Applied to the Schedule C net (after the half-SE
 * deduction) to estimate income tax on side-hustle earnings.
 */
export type IncomeTaxBracketsByYear = {
  [status in FilingStatus]?: {
    /** Four-digit year string (e.g. "2025") → ascending marginal brackets. */
    [year: string]: IncomeTaxBracket[];
  };
};

/**
 * Detection matchers for estimated-tax payments already recorded in YNAB. An
 * OUTFLOW transaction is an estimated-tax payment when its payee contains any
 * `payeeKeywords` entry (case-insensitive substring) or its category /
 * category-group / account matches one named here (case-insensitive).
 */
export interface EstimatedTaxPaymentMatchers {
  /** Case-insensitive payee substrings (e.g. "irs", "eftps"). */
  payeeKeywords?: string[];
  /** YNAB category names (case-insensitive exact). */
  categoryNames?: string[];
  /** YNAB category-group names (case-insensitive exact). */
  categoryGroups?: string[];
  /** YNAB account names (case-insensitive exact). */
  accounts?: string[];
}

/**
 * User-override layer. The profile loader (issue M3-3) deep-merges these
 * values on top of the bundled default US ruleset, so a user can change
 * individual values without restating the whole ruleset. A partial of the
 * profile; kept open because any subset may be overridden.
 */
export type TaxProfileOverrides = Partial<
  Omit<TaxProfile, "overrides">
> & {
  [key: string]: unknown;
};

/**
 * The generic, shareable tax profile. Canonical schema:
 * `tax-profile.schema.json`. All money amounts are in dollars, not YNAB
 * milliunits (divide YNAB milliunits by 1000 to get dollars).
 */
export interface TaxProfile {
  /**
   * Schema version this instance targets, so migrations can detect older
   * instances. Accepts a string (e.g. `"1"`) or an integer.
   */
  schemaVersion: string | number;
  /** Federal filing status. */
  filingStatus: FilingStatus;
  /** The tax year this profile applies to. */
  taxYear: number;
  /** Standard-deduction lookup by filing status and year (dollars). */
  standardDeductionByYear?: StandardDeductionByYear;
  /** Sole-prop / pass-through entities the taxpayer files for. */
  businessEntities?: BusinessEntity[];
  /** Schedule A (itemized deductions) configuration. */
  itemized?: Itemized;
  /** Schedule 1 adjustments to income. */
  adjustments?: Adjustments;
  /** Tunable thresholds and rates. */
  thresholds?: Thresholds;
  /** Federal quarterly estimated-tax due dates as calendar parts. */
  quarterlyEstimatedDueDates?: QuarterlyEstimatedDueDate[];
  /** Federal income-tax marginal brackets by filing status and year (issue #82). */
  incomeTaxBracketsByYear?: IncomeTaxBracketsByYear;
  /** Detection matchers for estimated-tax payments recorded in YNAB (issue #82). */
  estimatedTaxPayments?: EstimatedTaxPaymentMatchers;
  /** User overrides deep-merged on top of the default US ruleset (M3-3). */
  overrides?: TaxProfileOverrides;
}
