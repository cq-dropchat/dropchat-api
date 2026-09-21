// T1 — reading the business profile of an organization, defensively.
//
// `organizations.extra` is a free-form jsonb bag and the screen is not a gate:
// an admin's API key writes straight to PostgREST, and H4 already learned what
// that costs (`32_attention_validation.test.sql`). Here the damage is quieter
// than a broken sweep and arrives on every call — an unbounded string lands in
// the system prompt of every message, and a field of the wrong type would
// throw inside prepareRequest, which is the one place an agent cannot afford
// to fall over.
//
// So nothing here trusts the column. Every field is validated on its own, and
// a field that fails is DROPPED rather than taking the profile with it: a
// merchant who pasted a whole terms-of-service into "devoluciones" still gets
// an agent that knows what they sell.
import * as z from "zod";
import {
  BUSINESS_CURRENCIES,
  BUSINESS_PROFILE_FIELDS,
  BUSINESS_PROFILE_LIMITS as LIMITS,
  type BusinessCurrency,
  type BusinessProfile,
  type BusinessProfileField,
} from "./types/business_profile.ts";
import type { OrganizationExtra } from "./types/extra_types.ts";

const text = (max: number) => z.string().trim().min(1).max(max);

const FIELD_SCHEMAS = {
  industry: text(LIMITS.industry),
  sells: text(LIMITS.sells),
  shipping_coverage: text(LIMITS.shipping_coverage),
  shipping_times: text(LIMITS.shipping_times),
  payment_methods: z
    .array(text(LIMITS.payment_method))
    .min(1)
    .max(LIMITS.payment_methods),
  returns_policy: text(LIMITS.returns_policy),
  currency: z.enum(BUSINESS_CURRENCIES),
} satisfies Record<BusinessProfileField, z.ZodType>;

export const businessProfileSchema = z.object(FIELD_SCHEMAS).partial();

/**
 * Compile-time only. The type is mirrored into the UI and the schema is what
 * the API enforces; if they ever describe different profiles, `true` stops
 * being assignable to `never` and `deno check` says so.
 */
export const BUSINESS_PROFILE_PARITY: [
  BusinessProfile extends z.infer<typeof businessProfileSchema> ? true : never,
  z.infer<typeof businessProfileSchema> extends BusinessProfile ? true : never,
] = [true, true];

const LABELS: Record<BusinessProfileField, string> = {
  industry: "Rubro",
  sells: "Qué vende",
  shipping_coverage: "Cobertura de despacho",
  shipping_times: "Plazos de entrega",
  payment_methods: "Medios de pago",
  returns_policy: "Cambios y devoluciones",
  currency: "Moneda",
};

const CURRENCY_LABELS: Record<BusinessCurrency, string> = {
  CLP: "CLP (peso chileno)",
};

export type ParsedBusinessProfile = {
  profile: BusinessProfile;
  /** Fields that had content and were refused. Names only — never values. */
  dropped: BusinessProfileField[];
};

export function parseBusinessProfile(
  extra: OrganizationExtra | null | undefined,
): ParsedBusinessProfile {
  const profile: BusinessProfile = {};
  const dropped: BusinessProfileField[] = [];
  const bag = extra?.business_profile;

  // A string, a number, an array, null: all of them are `business_profile` to
  // jsonb, none of them is a profile.
  if (!bag || typeof bag !== "object" || Array.isArray(bag)) {
    return { profile, dropped };
  }

  for (const field of BUSINESS_PROFILE_FIELDS) {
    const raw = (bag as Record<string, unknown>)[field];

    // Absent, blank and an empty list are the same thing: nothing was said.
    // Only something with content can be refused, which is what keeps
    // `dropped` worth logging.
    if (raw === undefined || raw === null) continue;
    if (typeof raw === "string" && raw.trim() === "") continue;
    if (Array.isArray(raw) && raw.length === 0) continue;

    const parsed = FIELD_SCHEMAS[field].safeParse(raw);

    if (!parsed.success) {
      dropped.push(field);
      continue;
    }

    // Narrowing per field would need a switch that says nothing: the schemas
    // are indexed by the same key as the fields, and the parity assertion
    // above is what keeps that true.
    (profile as Record<string, unknown>)[field] = parsed.data;
  }

  return { profile, dropped };
}

/**
 * The profile as the model reads it, or null when there is nothing to say.
 *
 * Labelled, because the block is DATA about the business and not orders to the
 * agent: unlabelled, a line like "sin devolución de dinero" reads as something
 * the agent was told to answer.
 */
export function businessProfileBlock(
  extra: OrganizationExtra | null | undefined,
): string | null {
  const { profile, dropped } = parseBusinessProfile(extra);

  if (dropped.length > 0) {
    // Field names, never values: `extra` is also where this organization's
    // tokens live.
    console.warn(
      `business profile: ignoring invalid field(s): ${dropped.join(", ")}`,
    );
  }

  const lines = BUSINESS_PROFILE_FIELDS.flatMap((field) => {
    const value = profile[field];
    if (value === undefined) return [];

    const rendered = Array.isArray(value)
      ? value.join(", ")
      : field === "currency"
      ? CURRENCY_LABELS[value as BusinessCurrency]
      : value;

    return [`- ${LABELS[field]}: ${rendered}`];
  });

  return lines.length > 0 ? ["Perfil del negocio:", ...lines].join("\n") : null;
}
