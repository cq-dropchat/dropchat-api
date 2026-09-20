// H4 — the schedule, as the agent reads it.
//
// The cases are the ones that break naive implementations: a weekend, a day
// with no hours at all, a lunch break, and Chile's daylight saving change,
// where "09:00 local" is a different instant on either side of it.
//
// Pure: no database, no network. The same cases run against the SQL side in
// _traces/attention_parity.test.ts, because the sweeps use that one.
import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  attentionConfig,
  attentionContext,
  isOpen,
  nextOpening,
} from "./attention.ts";
import type { OrganizationExtra } from "./types/extra_types.ts";

const WEEKDAYS = {
  mon: [["09:00", "19:00"]],
  tue: [["09:00", "19:00"]],
  wed: [["09:00", "13:00"], ["15:00", "19:00"]],
  thu: [["09:00", "19:00"]],
  fri: [["09:00", "19:00"]],
  sat: [],
  sun: [],
} as unknown as NonNullable<OrganizationExtra["attention"]>["business_hours"];

const org = (
  attention: OrganizationExtra["attention"] = {},
): OrganizationExtra => ({ attention });

Deno.test("H4: the defaults are A6's, with 24/7 as the unconfigured schedule", () => {
  const config = attentionConfig(null);

  assertEquals(config.timezone, "America/Santiago");
  assertEquals(config.business_hours, null);
  assertEquals(config.ai_assignment_ttl_days, 14);
  assertEquals(config.human_assignment_ttl_hours, 72);
  assertEquals(config.human_wait_minutes, 30);
  assertEquals(config.on_human_wait_timeout, "notify_customer");
  assertEquals(config.auto_takeover, true);
});

Deno.test("H4: what the organization configured wins over the defaults", () => {
  const config = attentionConfig(org({ human_wait_minutes: 5 }));

  assertEquals(config.human_wait_minutes, 5);
  assertEquals(config.ai_assignment_ttl_days, 14);
});

Deno.test("H4: an organization with no schedule is always open", () => {
  assertEquals(isOpen(attentionConfig(null)), true);
  assertEquals(nextOpening(attentionConfig(null)), undefined);
  // And says nothing about hours in the prompt: there is nothing to say.
  assertEquals(attentionContext(null), undefined);
});

Deno.test("H4: open and closed, by day and by hour", () => {
  const config = attentionConfig(org({ business_hours: WEEKDAYS }));

  // Wednesday 2026-09-16, Santiago.
  assertEquals(isOpen(config, new Date("2026-09-16T13:00:00Z")), true); // 10:00
  // Inside the lunch break.
  assertEquals(isOpen(config, new Date("2026-09-16T17:00:00Z")), false); // 14:00
  // Saturday.
  assertEquals(isOpen(config, new Date("2026-09-19T13:00:00Z")), false);
});

Deno.test("H4: the next opening from a weekend is Monday morning", () => {
  const config = attentionConfig(org({ business_hours: WEEKDAYS }));

  const opening = nextOpening(config, new Date("2026-09-19T13:00:00Z"));

  assert(opening);
  assertEquals(
    new Intl.DateTimeFormat("sv-SE", {
      timeZone: "America/Santiago",
      dateStyle: "short",
      timeStyle: "short",
    }).format(opening),
    "2026-09-21 09:00",
  );
});

Deno.test("H4: the next opening is a local time, on both sides of a clock change", () => {
  // Chile moves to summer time overnight on 2026-09-05. An opening at 09:00
  // on the Friday before is -04; the Monday after is -03. Naming the instant
  // by its offset is what a naive implementation gets wrong.
  const config = attentionConfig(org({ business_hours: WEEKDAYS }));

  const before = nextOpening(config, new Date("2026-09-03T23:00:00Z"));
  const after = nextOpening(config, new Date("2026-09-06T23:00:00Z"));

  assertEquals(before?.toISOString(), "2026-09-04T13:00:00.000Z"); // 09:00 -04
  assertEquals(after?.toISOString(), "2026-09-07T12:00:00.000Z"); // 09:00 -03
});

Deno.test("H4: the prompt gets the schedule only when there is one", () => {
  const config = org({ business_hours: WEEKDAYS });

  const closed = attentionContext(config, new Date("2026-09-19T13:00:00Z"));

  assertEquals(closed?.open_now, false);
  assert(closed?.next_opening?.includes("lunes"));

  const open = attentionContext(config, new Date("2026-09-16T13:00:00Z"));

  assertEquals(open?.open_now, true);
  // Nothing to announce while the team is there.
  assertEquals(open?.next_opening, undefined);
});
