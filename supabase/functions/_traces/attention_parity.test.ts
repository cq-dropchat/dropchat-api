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
  fri: [["09:00", "19:00"]],
  sat: [],
  sun: [],
} as unknown as NonNullable<OrganizationExtra["attention"]>["business_hours"];

/** The cases both sides must agree on, including the awkward ones. */
const CASES: { why: string; at: string }[] = [
  { why: "a Wednesday morning", at: "2026-09-16T13:00:00Z" },
  { why: "the lunch break", at: "2026-09-16T17:00:00Z" },
  { why: "minutes before closing", at: "2026-09-16T21:59:00Z" },
  { why: "minutes after closing", at: "2026-09-16T22:01:00Z" },
  { why: "a Saturday", at: "2026-09-19T13:00:00Z" },
  { why: "a Sunday night", at: "2026-09-20T23:00:00Z" },
  { why: "the Friday before the clocks change", at: "2026-09-04T23:00:00Z" },
  { why: "the Monday after the clocks change", at: "2026-09-07T23:00:00Z" },
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

      assertEquals(
        nextOpening(config, at)?.toISOString() ?? null,
        sql.next_opening ? new Date(sql.next_opening).toISOString() : null,
        `next opening at ${testCase.why} (${testCase.at})`,
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
