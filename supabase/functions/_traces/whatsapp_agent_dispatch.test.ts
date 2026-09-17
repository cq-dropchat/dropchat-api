// Trace (a), end to end on a local Supabase with supabase/tests/fixtures
// loaded (IMPLEMENTATION_PROMPT §5):
//
//   signed WhatsApp webhook → row in `messages` → trigger enqueues
//   agent-client → agent reply inserted → trigger enqueues the dispatcher →
//   a status webhook lands while the dispatcher is still committing (the
//   commitDispatchedMessage race) → a later `read` merges into the same row.
//
// The local edge runtime does not serve functions to pg_net (its requests
// fail with 503), so this test is the worker: it proves each trigger enqueued
// its request through supabase_functions.hooks, then runs that function's
// handler in-process with the payload the trigger sends. Only the outside
// world is stubbed: the LLM provider and the Graph API.
import "../_shared/testing/env.ts"; // before the handlers: keys are read at import
import { assert, assertEquals } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import postgres from "postgres";
import type { Database, MessageRow } from "../_shared/types/database_types.ts";
import { env, fixture, supabaseIsUp } from "../_shared/testing/env.ts";
import { metaRequest } from "../_shared/testing/sign.ts";
import { stubLlm, withTestAgent } from "../_shared/testing/agents.ts";
import { handler as whatsappWebhook } from "../whatsapp-webhook/index.ts";
import { handler as agentClient } from "../agent-client/index.ts";
import { handler as whatsappDispatcher } from "../whatsapp-dispatcher/index.ts";

const up = await supabaseIsUp();

const CONTACT = "5491100000102"; // contact A2: conversation conv_a2

function service() {
  return createClient<Database>(env.url, env.serviceRoleKey, {
    auth: { persistSession: false },
  });
}

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** The deployed runtime's waitUntil: the webhook acks, then does the work. */
async function deliverWebhook(body: unknown) {
  const pending: Promise<unknown>[] = [];
  const g = globalThis as unknown as { EdgeRuntime?: unknown };
  const previous = g.EdgeRuntime;
  g.EdgeRuntime = { waitUntil: (p: Promise<unknown>) => pending.push(p) };
  try {
    const response = await whatsappWebhook(
      await metaRequest(
        "http://localhost/whatsapp-webhook",
        body,
        env.metaAppSecret,
      ),
    );
    assertEquals(response.status, 200);
    await Promise.all(pending);
  } finally {
    g.EdgeRuntime = previous;
  }
}

function change(value: Record<string, unknown>) {
  return {
    object: "whatsapp_business_account",
    entry: [{
      id: fixture.wabaA,
      changes: [{
        field: "messages",
        value: {
          messaging_product: "whatsapp",
          metadata: {
            display_phone_number: "5491100000001",
            phone_number_id: fixture.waA,
          },
          ...value,
        },
      }],
    }],
  };
}

function statusChange(wamid: string, status: string, at: number) {
  return change({
    statuses: [{
      id: wamid,
      status,
      timestamp: String(Math.floor(at / 1000)),
      recipient_id: CONTACT,
    }],
  });
}

/** The payload a messages trigger posts: the inserted row. */
function triggerRequest(url: string, record: MessageRow) {
  return new Request(url, {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.serviceRoleKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      type: "INSERT",
      table: "messages",
      schema: "public",
      record,
      old_record: null,
    }),
  });
}

Deno.test({
  name:
    "trace (a): WhatsApp webhook → agent-client → reply → dispatcher → statuses merge into the reply row",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { max: 1 });
    const run = crypto.randomUUID();
    const inboundWamid = `wamid.TRACE-A.in.${run}`;
    const outboundWamid = `wamid.TRACE-A.out.${run}`;
    const since = new Date(Date.now() - 1000).toISOString();

    const hooksSince = async (watermark: bigint, name: string) => {
      const [row] = await sql`
        select count(*)::int as n from supabase_functions.hooks
        where id > ${watermark.toString()} and hook_name = ${name}`;
      return row.n as number;
    };
    const watermark = async () => {
      const [row] = await sql`
        select coalesce(max(id), 0)::bigint as id from supabase_functions.hooks`;
      return BigInt(row.id);
    };

    const llm = stubLlm(50);
    // Captured after the LLM stub: the Graph stub below falls through to it.
    const realFetch = globalThis.fetch;

    try {
      await withTestAgent(client, async () => {
        // 1. A signed inbound message.
        let mark = await watermark();
        await deliverWebhook(change({
          contacts: [{ profile: { name: "Dario" }, wa_id: CONTACT }],
          messages: [{
            from: CONTACT,
            id: inboundWamid,
            timestamp: String(Math.floor(Date.now() / 1000)),
            type: "text",
            text: { body: "¿Tienen stock?" },
          }],
        }));

        const { data: inbound } = await client
          .from("messages")
          .select()
          .eq("organization_id", fixture.orgA)
          .eq("external_id", inboundWamid)
          .single()
          .throwOnError();
        assertEquals(inbound.conversation_address, CONTACT);
        assert(
          (inbound.status as Record<string, unknown>).pending,
          "inbound row armed",
        );

        // 2. The insert enqueued agent-client.
        assertEquals(
          await hooksSince(mark, "handle_incoming_message_to_agent"),
          1,
          "agent-client was not enqueued for the inbound row",
        );

        // 3. agent-client answers (the database clock can run ahead: settle).
        await wait(500);
        mark = await watermark();
        const response = await agentClient(
          triggerRequest(
            "http://localhost/agent-client",
            inbound as MessageRow,
          ),
        );
        assertEquals(response.status, 200);
        assertEquals(llm.calls(), 1);

        const { data: reply } = await client
          .from("messages")
          .select()
          .eq("conversation_id", inbound.conversation_id)
          .is("sender_address", null)
          .gte("created_at", since)
          .single()
          .throwOnError();
        assertEquals(
          (reply.content as { text?: string }).text,
          "respuesta de prueba",
        );

        // 4. The reply enqueued the dispatcher.
        assertEquals(
          await hooksSince(mark, "handle_outgoing_message_to_dispatcher"),
          1,
          "the dispatcher was not enqueued for the reply",
        );

        // 5. Dispatch. Meta answers with the wamid, and its `sent` status
        //    webhook lands BEFORE the dispatcher commits it to the row.
        let graphSends = 0;
        globalThis.fetch = async (input, init) => {
          const url = input instanceof Request ? input.url : String(input);
          if (
            url.startsWith("https://graph.facebook.com/") &&
            url.endsWith("/messages")
          ) {
            graphSends++;
            await deliverWebhook(
              statusChange(outboundWamid, "sent", Date.now()),
            );
            return Response.json({
              messaging_product: "whatsapp",
              contacts: [{ input: CONTACT, wa_id: CONTACT }],
              messages: [{ id: outboundWamid }],
            });
          }
          return realFetch(input, init);
        };

        const dispatched = await whatsappDispatcher(
          triggerRequest(
            "http://localhost/whatsapp-dispatcher",
            reply as MessageRow,
          ),
        );
        assertEquals(dispatched.status, 200);
        assertEquals(graphSends, 1);

        // 6. A `read` after the commit.
        await deliverWebhook(
          statusChange(outboundWamid, "read", Date.now() + 1000),
        );

        // One row carries the wamid: the reply, with every status merged.
        const { data: rows } = await client
          .from("messages")
          .select("id, status, content, agent_id")
          .eq("organization_id", fixture.orgA)
          .eq("external_id", outboundWamid)
          .throwOnError();
        assertEquals(rows.length, 1, "the webhook's duplicate row survived");
        assertEquals(rows[0].id, reply.id, "statuses landed on another row");
        assertEquals(rows[0].agent_id, reply.agent_id);
        const status = rows[0].status as Record<string, unknown>;
        assert(status.accepted, "accepted missing");
        assert(status.sent, "sent (arrived mid-dispatch) was lost");
        assert(status.read, "read missing");
        assertEquals(status.pending, undefined);
        assertEquals(
          (rows[0].content as { text?: string }).text,
          "respuesta de prueba",
          "the reply's content was overwritten by the status row",
        );
      });
    } finally {
      globalThis.fetch = realFetch;
      llm.restore();
      await client.from("agent_turns").delete().eq(
        "conversation_id",
        "aaaaaaaa-0000-4000-8000-0000000000c2",
      );
      await client
        .from("messages")
        .delete()
        .eq("organization_id", fixture.orgA)
        .in("external_id", [inboundWamid, outboundWamid]);
      await client
        .from("messages")
        .delete()
        .eq("organization_id", fixture.orgA)
        .eq("conversation_address", CONTACT)
        .gte("created_at", since);
      await sql.end();
    }
  },
});
