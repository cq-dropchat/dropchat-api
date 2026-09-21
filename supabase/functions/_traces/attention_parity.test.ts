// H4 — the schedule is implemented twice, so it is checked twice against the
// same cases.
//
// SQL is the authority (the lifecycle sweeps are pg_cron jobs and cannot
// depend on an edge function being up); TypeScript answers the same questions
// for the system prompt, where a round trip per invocation would be paid on
// every message. Two implementations of one rule drift silently — this is
// what makes them fail loudly instead.
//
// Runs against the local database with no fixture: it calls the attention
// functions with literal configurations.
import "../_shared/testing/env.ts";
import { assertEquals } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import { env, supabaseIsUp } from "../_shared/testing/env.ts";
import { attentionConfig, isOpen, nextOpening } from "../_shared/attention.ts";
import type { OrganizationExtra } from "../_shared/types/extra_types.ts";

const up = await supabaseIsUp();

const WEEKDAYS = {
  mon: [["09:00", "19:00"]],
  tue: [["09:00", "19:00"]],
  wed: [["09:00", "13:00"], ["15:00", "19:00"]],
  thu: [["09:00", "19:00"]],
  // Friday runs to midnight and Saturday opens at midnight: a shop that
  // closes "late". Nothing here crossed midnight before, and `24:00` is a
  // value the write-side validation accepts on purpose, so the two
  // implementations had never been asked the same question about it.
  fri: [["09:00", "24:00"]],
  sat: [["00:00", "03:00"]],
  sun: [],
} as unknown as NonNullable<OrganizationExtra["attention"]>["business_hours"];

/**
 * The cases both sides must agree on, including the awkward ones.
 *
 * `open` pins the absolute answer where it can be reasoned about without
 * trusting either implementation. Agreement alone would let both sides be
 * wrong together, which is the failure a parity test cannot see — and the
 * midnight-crossing cases are new, so they are the ones worth pinning. All
 * three sit well clear of the September transition, where Chile is a flat
 * -03, so the local time is the instant minus three hours and nothing else.
 */
const CASES: { why: string; at: string; open?: boolean }[] = [
  { why: "a Wednesday morning", at: "2026-09-16T13:00:00Z" },
  { why: "the lunch break", at: "2026-09-16T17:00:00Z" },
  { why: "minutes before closing", at: "2026-09-16T21:59:00Z" },
  { why: "minutes after closing", at: "2026-09-16T22:01:00Z" },
  { why: "a Saturday", at: "2026-09-19T13:00:00Z" },
  { why: "a Sunday night", at: "2026-09-20T23:00:00Z" },
  { why: "the Friday before the clocks change", at: "2026-09-04T23:00:00Z" },
  { why: "the Monday after the clocks change", at: "2026-09-07T23:00:00Z" },
  // Chile moves to -03 on the first Sunday of September, so 2026-09-06 is
  // 23 hours long. The two cases above bracket it without touching it, which
  // is the one instant where an hour that does not exist can be answered
  // differently by each side.
  {
    why: "the hour that does not exist, on the short Sunday",
    at: "2026-09-06T04:30:00Z",
  },
  { why: "just after the clocks jump", at: "2026-09-06T05:30:00Z" },
  // Midnight, from both sides.
  // 23:59 on Friday the 18th, inside 09:00-24:00.
  {
    why: "Friday a minute before midnight",
    at: "2026-09-19T02:59:00Z",
    open: true,
  },
  // 00:01 on Saturday the 19th, inside 00:00-03:00. The crossing itself.
  {
    why: "Saturday a minute after midnight",
    at: "2026-09-19T03:01:00Z",
    open: true,
  },
  // 03:30 on Saturday, after the late window shuts.
  {
    why: "Saturday after the late window closes",
    at: "2026-09-19T06:30:00Z",
    open: false,
  },
];

/**
 * The SQL side, through the same functions the sweeps use. They are revoked
 * from the API roles (they are internal), so this asks with the service role.
 */
async function sqlAnswer(
  client: ReturnType<typeof service>,
  extra: OrganizationExtra,
  at: string,
): Promise<{ is_open: boolean; next_opening: string | null }> {
  const config = await client
    .rpc("attention_config", { p_extra: extra })
    .throwOnError();

  const [open, opening] = await Promise.all([
    client.rpc("attention_is_open", { p_config: config.data, p_at: at })
      .throwOnError(),
    client.rpc("attention_next_opening", { p_config: config.data, p_at: at })
      .throwOnError(),
  ]);

  return {
    is_open: open.data as unknown as boolean,
    next_opening: opening.data as unknown as string | null,
  };
}

function service() {
  return createClient(env.url, env.serviceRoleKey, {
    auth: { persistSession: false },
  });
}

Deno.test({
  name: "H4: SQL and TypeScript answer the schedule the same way",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    const extra: OrganizationExtra = {
      attention: { timezone: "America/Santiago", business_hours: WEEKDAYS },
    };
    const config = attentionConfig(extra);

    for (const testCase of CASES) {
      const sql = await sqlAnswer(client, extra, testCase.at);
      const at = new Date(testCase.at);

      assertEquals(
        isOpen(config, at),
        sql.is_open,
        `open at ${testCase.why} (${testCase.at})`,
      );

      if (testCase.open !== undefined) {
        assertEquals(
          sql.is_open,
          testCase.open,
          `and both are RIGHT at ${testCase.why} (${testCase.at})`,
        );
      }

      assertEquals(
        nextOpening(config, at)?.toISOString() ?? null,
        sql.next_opening ? new Date(sql.next_opening).toISOString() : null,
        `next opening at ${testCase.why} (${testCase.at})`,
      );
    }
  },
});

// The defaults are written twice, by hand — 04-14_attention.sql and
// _shared/attention.ts — and nothing compared them. Every key is a decision
// the sweeps act on: change `human_wait_minutes` from 30 to 45 on one side
// and the prompt promises one wait while the sweep enforces another, with
// every test still green.
Deno.test({
  name: "H4: SQL and TypeScript resolve the same defaults, key by key",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();

    for (
      const [why, extra] of [
        ["nothing configured", {}],
        ["a partial configuration", {
          attention: { human_wait_minutes: 5, timezone: "America/Santiago" },
        }],
      ] as const
    ) {
      const sql = await client
        .rpc("attention_config", { p_extra: extra })
        .throwOnError();

      const ts = attentionConfig(extra) as Record<string, unknown>;
      const resolved = sql.data as unknown as Record<string, unknown>;

      // Key by key rather than by deep equality, so a mismatch names the key
      // instead of printing two objects and leaving the reader to diff them.
      for (const key of Object.keys(ts)) {
        assertEquals(
          resolved[key] ?? null,
          ts[key] ?? null,
          `${key}, with ${why}`,
        );
      }

      assertEquals(
        Object.keys(resolved).sort(),
        Object.keys(ts).sort(),
        `the two sides resolve the same set of keys, with ${why}`,
      );
    }
  },
});

// `ignore: !up` is deliberate: a laptop without Docker should not fail for
// not having a database. But the same flag makes these tests DISAPPEAR, in
// green, and the one place they must never disappear is CI — where the
// workflow starts the database before running the suite. Without this, a
// workflow that stopped starting it would go on passing.
Deno.test({
  name: "H4: the parity tests are not skipped where they have to run",
  fn() {
    if (Deno.env.get("CI") === "true" && !up) {
      throw new Error(
        "the database is down in CI, so the parity tests above were skipped " +
          "silently and nothing compared SQL against TypeScript",
      );
    }
  },
});

Deno.test({
  name:
    "H4: SQL and TypeScript agree that an organization with no schedule is open",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();

    const sql = await sqlAnswer(client, {}, new Date().toISOString());

    assertEquals(sql.is_open, true);
    assertEquals(sql.next_opening, null);
    assertEquals(isOpen(attentionConfig(null)), true);
    assertEquals(nextOpening(attentionConfig(null)), undefined);
  },
});
