// H4 — the organization's attention settings, as the agent needs them.
//
// The authority is SQL (public.attention_config and friends): the lifecycle
// sweeps are pg_cron jobs, and a cron job that has to call an edge function
// to know whether it may act stops working when the function does.
//
// What lives here is the half the system prompt needs — the defaults, "are we
// open right now", and "when do we open next" — so the agent can say
// "te responde una persona mañana desde las 9" instead of promising somebody
// who is asleep. `_traces/attention_parity.test.ts` runs the same cases
// through both implementations, so the two cannot drift quietly.
import type {
  AttentionConfig,
  OrganizationExtra,
} from "./types/extra_types.ts";

export const ATTENTION_DEFAULTS:
  & Required<
    Omit<AttentionConfig, "business_hours">
  >
  & { business_hours: AttentionConfig["business_hours"] } = {
    timezone: "America/Santiago",
    // Null, not a Monday-to-Friday guess: an organization that has not said
    // when it works is reachable at any hour.
    business_hours: null,
    ai_assignment_ttl_days: 14,
    // Hours, or 0 for "never". Not null: `extra` is written as a JSON merge
    // patch, where null removes the key.
    human_assignment_ttl_hours: 72,
    human_wait_minutes: 30,
    on_human_wait_timeout: "notify_customer",
    human_wait_message:
      "Nuestro equipo te responderá apenas esté disponible. Gracias por la espera.",
    auto_takeover: true,
  };

export type ResolvedAttention = typeof ATTENTION_DEFAULTS;

export function attentionConfig(
  extra: OrganizationExtra | null | undefined,
): ResolvedAttention {
  return { ...ATTENTION_DEFAULTS, ...(extra?.attention ?? {}) };
}

const DAYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"] as const;

/** The local weekday and time-of-day of an instant, in a named zone. */
function localParts(at: Date, timeZone: string) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    weekday: "short",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(at);

  const get = (type: string) => parts.find((p) => p.type === type)!.value;
  // Intl says "Mon"; the schedule says "mon".
  const weekday = get("weekday").toLowerCase() as typeof DAYS[number];
  // 24:00 happens: Intl spells midnight as "24" in some runtimes.
  const hour = get("hour") === "24" ? "00" : get("hour");

  return {
    weekday,
    date: `${get("year")}-${get("month")}-${get("day")}`,
    minutes: Number(hour) * 60 + Number(get("minute")),
  };
}

function toMinutes(hhmm: string): number {
  const [h, m] = hhmm.split(":");

  return Number(h) * 60 + Number(m);
}

export function isOpen(config: ResolvedAttention, at: Date = new Date()) {
  if (!config.business_hours) {
    return true;
  }

  const { weekday, minutes } = localParts(at, config.timezone);

  return (config.business_hours[weekday] ?? []).some(
    ([from, to]) => minutes >= toMinutes(from) && minutes <= toMinutes(to),
  );
}

/**
 * When the organization opens next, as an instant, or undefined when it never
 * closed (24/7) or never opens at all.
 *
 * Walks forward a day at a time from the local date, which is what makes the
 * answer right across a daylight-saving change: the opening is a LOCAL time,
 * and the instant it corresponds to is whatever that zone says it is.
 */
export function nextOpening(
  config: ResolvedAttention,
  at: Date = new Date(),
): Date | undefined {
  if (!config.business_hours) {
    return undefined;
  }

  for (let offset = 0; offset <= 14; offset++) {
    const day = new Date(at.getTime() + offset * 24 * 60 * 60 * 1000);
    const { weekday, date } = localParts(day, config.timezone);
    const windows = (config.business_hours[weekday] ?? [])
      .slice()
      .sort((a, b) => toMinutes(a[0]) - toMinutes(b[0]));

    for (const [from] of windows) {
      const opening = zonedTime(date, from, config.timezone);

      if (opening > at) {
        return opening;
      }
    }
  }

  return undefined;
}

/** The instant a local wall-clock time corresponds to in a named zone. */
function zonedTime(date: string, hhmm: string, timeZone: string): Date {
  // Start from the naive reading, then correct by the zone's offset at that
  // moment — which is what handles both standard and summer time without a
  // table of rules.
  const naive = new Date(`${date}T${hhmm}:00Z`);
  const offset = naive.getTime() -
    new Date(naive.toLocaleString("sv-SE", { timeZone }) + "Z").getTime();

  return new Date(naive.getTime() + offset);
}

/** What the system prompt says about the schedule. */
export function attentionContext(
  extra: OrganizationExtra | null | undefined,
  at: Date = new Date(),
) {
  const config = attentionConfig(extra);

  if (!config.business_hours) {
    return undefined;
  }

  const opening = isOpen(config, at) ? undefined : nextOpening(config, at);

  return {
    timezone: config.timezone,
    open_now: isOpen(config, at),
    ...(opening && {
      next_opening: new Intl.DateTimeFormat("es-CL", {
        timeZone: config.timezone,
        weekday: "long",
        hour: "2-digit",
        minute: "2-digit",
        hour12: false,
      }).format(opening),
    }),
  };
}
