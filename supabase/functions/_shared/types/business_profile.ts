// T1 — the business profile: what the organization sells, ships and charges.
//
// This file is the one description of the fields, and it is mirrored into the
// UI (scripts/check-type-sync.sh) on purpose. The limits are not decoration:
// every one of these strings is copied into the system prompt of every single
// call, so a field without a ceiling is a bill without a ceiling. The screen
// and the API have to agree on where that ceiling is, and agreeing means
// reading it from the same place.
//
// No imports, no dependencies: the UI takes this file verbatim.

/** Chile today (`SPEC_CONTINUACION.md` §21). The list is what grows. */
export type BusinessCurrency = "CLP";

export type BusinessProfile = {
  /** Rubro — "zapatillas urbanas", "panadería". */
  industry?: string;
  /** What it sells, in the merchant's own words. */
  sells?: string;
  /** Where it ships to, and where it does not. */
  shipping_coverage?: string;
  /** How long delivery takes. */
  shipping_times?: string;
  /**
   * How it gets paid. A LIST, and `extra` is written as a JSON merge patch,
   * where an array is replaced whole (§3.6): whoever writes this sends every
   * method, never a delta, or the ones left out are deleted.
   */
  payment_methods?: string[];
  /** Returns and exchanges. */
  returns_policy?: string;
  currency?: BusinessCurrency;
};

export type BusinessProfileField = keyof BusinessProfile;

export const BUSINESS_CURRENCIES = ["CLP"] as const;

/**
 * Characters per field, and items per list. Chosen against what the field is
 * for: a rubro is a label, a returns policy is a paragraph, and neither is a
 * catalogue.
 */
export const BUSINESS_PROFILE_LIMITS = {
  industry: 80,
  sells: 600,
  shipping_coverage: 400,
  shipping_times: 300,
  returns_policy: 800,
  /** Per method. */
  payment_method: 60,
  /** Methods in the list. */
  payment_methods: 20,
} as const;

/** The order the profile is written in, on the screen and in the prompt. */
export const BUSINESS_PROFILE_FIELDS: readonly BusinessProfileField[] = [
  "industry",
  "sells",
  "shipping_coverage",
  "shipping_times",
  "payment_methods",
  "returns_policy",
  "currency",
];
