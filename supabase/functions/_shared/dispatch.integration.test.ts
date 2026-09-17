// F03, the dispatcher half: commitDispatchedMessage resolves its
// webhook-vs-dispatcher duplicate INSIDE the organization. Runs against a
// local Supabase with supabase/tests/fixtures loaded.
import { assertEquals } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import type { Database, MessageInsert } from "./types/database_types.ts";
import { env, fixture, supabaseIsUp } from "./testing/env.ts";
import { commitDispatchedMessage } from "./dispatch.ts";

const up = await supabaseIsUp();

function serviceClient() {
  return createClient<Database>(env.url, env.serviceRoleKey, {
    auth: { persistSession: false },
  });
}

Deno.test({
  name:
    "F03: the duplicate hunt never folds or deletes another tenant's row with the same external_id",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = serviceClient();
    const externalId = `wamid.RACE.${crypto.randomUUID()}`;
    const inserted: string[] = [];

    try {
      // Org B already holds this external id (a shared whatsapp-web number).
      const { data: bRow } = await client
        .from("messages")
        .insert({
          organization_id: fixture.orgB,
          service: "whatsapp",
          organization_address: fixture.waB,
          conversation_address: fixture.contactB1,
          sender_address: fixture.contactB1,
          external_id: externalId,
          content: { version: "1", type: "text", kind: "text", text: "B" },
          status: { delivered: "2026-09-10T10:00:00Z" },
          timestamp: "2026-09-10T10:00:00Z",
        })
        .select("id")
        .single()
        .throwOnError();
      inserted.push(bRow.id);

      // Org A: the dispatcher's own row (no external id yet)…
      const { data: ours } = await client
        .from("messages")
        .insert({
          organization_id: fixture.orgA,
          service: "whatsapp",
          organization_address: fixture.waA,
          conversation_address: fixture.contactA1,
          sender_address: null,
          agent_id: fixture.agentAlice,
          content: { version: "1", type: "text", kind: "text", text: "A" },
          status: { pending: "2026-09-10T10:00:00Z" },
          timestamp: "2026-09-10T10:00:00Z",
        })
        .select("id")
        .single()
        .throwOnError();
      inserted.push(ours.id);

      // …and the webhook's row for the same send, which landed first.
      const { data: webhookRow } = await client
        .from("messages")
        .insert({
          organization_id: fixture.orgA,
          service: "whatsapp",
          organization_address: fixture.waA,
          conversation_address: fixture.contactA1,
          sender_address: null,
          external_id: externalId,
          // A status-only upsert row, as the webhook writes it.
          content: {} as unknown as MessageInsert["content"],
          status: { sent: "2026-09-10T10:00:01Z" },
          timestamp: "2026-09-10T10:00:01Z",
        })
        .select("id")
        .single()
        .throwOnError();
      inserted.push(webhookRow.id);

      await commitDispatchedMessage({
        client,
        messageId: ours.id,
        organizationId: fixture.orgA,
        externalId,
        status: { accepted: "2026-09-10T10:00:02Z" },
      });

      const { data: after } = await client
        .from("messages")
        .select("id, organization_id, status, external_id")
        .eq("external_id", externalId)
        .order("organization_id")
        .throwOnError();

      // Exactly two rows remain: B's untouched, and ours carrying both halves.
      assertEquals(after.length, 2);
      const a = after.find((r) => r.organization_id === fixture.orgA)!;
      const b = after.find((r) => r.organization_id === fixture.orgB)!;
      assertEquals(a.id, ours.id);
      assertEquals(b.id, bRow.id);
      assertEquals(b.status, { delivered: "2026-09-10T10:00:00Z" });
      const status = a.status as Record<string, unknown>;
      assertEquals(status.sent, "2026-09-10T10:00:01Z");
      assertEquals(status.accepted, "2026-09-10T10:00:02Z");
      assertEquals(status.pending, undefined);
    } finally {
      await client.from("messages").delete().in("id", inserted);
    }
  },
});
