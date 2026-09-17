// F11 — the insert trigger and the retry sweep can both fire the dispatcher
// for one message; a Meta round trip longer than the sweep's minute sent it
// twice. A transient Meta error was retried every minute for twelve hours.
//
// Runs against a local Supabase with supabase/tests/fixtures loaded; the
// Graph API is stubbed.
import "../_shared/testing/env.ts"; // before index.ts: keys are read at import
import { assert, assertEquals } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import type { Database, MessageRow } from "../_shared/types/database_types.ts";
import { env, fixture, supabaseIsUp } from "../_shared/testing/env.ts";
import { handler } from "./index.ts";

const up = await supabaseIsUp();

function service() {
  return createClient<Database>(env.url, env.serviceRoleKey, {
    auth: { persistSession: false },
  });
}

function stubGraph(respond: () => Promise<Response>) {
  const realFetch = globalThis.fetch;
  let sends = 0;
  globalThis.fetch = async (input, init) => {
    const url = input instanceof Request ? input.url : String(input);
    if (
      url.startsWith("https://graph.facebook.com/") && url.endsWith("/messages")
    ) {
      sends++;
      return await respond();
    }
    return realFetch(input, init);
  };
  return { sends: () => sends, restore: () => (globalThis.fetch = realFetch) };
}

async function outgoingRow(client: ReturnType<typeof service>) {
  // Insert with the dispatch trigger's effect irrelevant: pg_net has no edge
  // runtime to reach locally, so only the calls below dispatch.
  const { data } = await client
    .from("messages")
    .insert({
      organization_id: fixture.orgA,
      service: "whatsapp",
      organization_address: fixture.waA,
      conversation_address: fixture.contactA1,
      sender_address: null,
      agent_id: fixture.agentAlice,
      content: { version: "1", type: "text", kind: "text", text: "una vez" },
    })
    .select()
    .single()
    .throwOnError();
  return data as MessageRow;
}

function request(record: MessageRow) {
  return new Request("http://localhost/whatsapp-dispatcher", {
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
  name: "F11: two concurrent dispatches of one message send it once",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    const row = await outgoingRow(client);
    const graph = stubGraph(async () => {
      await new Promise((r) => setTimeout(r, 200)); // a slow Meta
      return Response.json({
        messaging_product: "whatsapp",
        contacts: [{ input: fixture.contactA1, wa_id: fixture.contactA1 }],
        messages: [{ id: `wamid.F11.${row.id}` }],
      });
    });

    try {
      const [a, b] = await Promise.all([
        handler(request(row)),
        handler(request(row)),
      ]);
      assertEquals([a.status, b.status], [200, 200]);
      assertEquals(graph.sends(), 1, "Meta was called more than once");

      const { data } = await client
        .from("messages")
        .select("external_id, status")
        .eq("id", row.id)
        .single()
        .throwOnError();
      const status = data.status as Record<string, unknown>;
      assertEquals(data.external_id, `wamid.F11.${row.id}`);
      assertEquals(status.pending, undefined);
      assertEquals(status.dispatching, undefined);
      assert(status.accepted, "accepted was not stamped");
    } finally {
      graph.restore();
      await client.from("messages").delete().eq("id", row.id);
    }
  },
});

Deno.test({
  name:
    "F11: a transient Meta error backs off instead of retrying every minute",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    const row = await outgoingRow(client);
    const graph = stubGraph(() =>
      Promise.resolve(Response.json({
        error: { code: 130429, message: "(#130429) Rate limit hit" },
      }, { status: 400 }))
    );

    try {
      await handler(request(row)).catch(() => undefined); // transient rethrows

      const { data } = await client
        .from("messages")
        .select("status")
        .eq("id", row.id)
        .single()
        .throwOnError();
      const status = data.status as Record<string, unknown>;
      assertEquals(graph.sends(), 1);
      assert(status.pending, "a transient failure must keep the row armed");
      assertEquals(status.dispatching, undefined);
      assertEquals(status.attempts, 1);
      const wait = new Date(String(status.retry_at)).getTime() - Date.now();
      assert(wait > 50_000 && wait < 70_000, `retry_at is ${wait} ms out`);

      // While the retry is not due, another dispatch still sends (the
      // trigger path is not gated by retry_at) — but the sweep skips it.
      const { data: candidates } = await client
        .rpc("pending_dispatch_candidates")
        .select("id")
        .throwOnError();
      assert(!candidates.some((c) => c.id === row.id));
    } finally {
      graph.restore();
      await client.from("messages").delete().eq("id", row.id);
    }
  },
});
