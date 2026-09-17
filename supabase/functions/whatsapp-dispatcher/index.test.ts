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

// ---------------------------------------------------------------------------
// F28 — an expired or revoked token (Meta code 190) failed every message on
// its own: one Graph call each, nothing on the account saying why, and the
// same for every message until someone noticed. Now the first 190 marks the
// account (`extra.dispatch_auth_failure`, readable by members, plus a line in
// public.logs); later messages fail at once without calling Meta, until a new
// token is stored — which clears the mark. The account stays `connected`:
// Meta still delivers its inbound webhooks, which a disconnected account
// would drop.
// ---------------------------------------------------------------------------

const EXPIRED = () =>
  Promise.resolve(Response.json({
    error: {
      message: "Error validating access token: Session has expired",
      type: "OAuthException",
      code: 190,
      error_subcode: 463,
    },
  }, { status: 401 }));

async function addressExtra(client: ReturnType<typeof service>) {
  const { data } = await client
    .from("organizations_addresses")
    .select("extra, status")
    .eq("organization_id", fixture.orgA)
    .eq("service", "whatsapp")
    .eq("address", fixture.waA)
    .single()
    .throwOnError();
  return data as { extra: Record<string, unknown>; status: string };
}

async function setToken(client: ReturnType<typeof service>, token: string) {
  await client
    .from("organizations_addresses")
    .update({ extra: { access_token: token } })
    .eq("organization_id", fixture.orgA)
    .eq("service", "whatsapp")
    .eq("address", fixture.waA)
    .throwOnError();
}

async function statusOf(client: ReturnType<typeof service>, id: string) {
  const { data } = await client
    .from("messages")
    .select("status")
    .eq("id", id)
    .single()
    .throwOnError();
  return data.status as Record<string, unknown>;
}

Deno.test({
  name:
    "F28: an expired token marks the account, and later messages fail without calling Meta",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    const since = new Date().toISOString();
    const first = await outgoingRow(client);
    const second = await outgoingRow(client);
    const graph = stubGraph(EXPIRED);

    try {
      await handler(request(first));
      const firstStatus = await statusOf(client, first.id);
      assert(firstStatus.failed, "a 190 is permanent");
      assertEquals(firstStatus.pending, undefined);

      const { extra, status } = await addressExtra(client);
      assertEquals(status, "connected", "inbound must keep flowing");
      const mark = extra.dispatch_auth_failure as Record<string, unknown>;
      assert(mark, "the account was not marked");
      assertEquals(mark.code, 190);
      assert(
        !JSON.stringify(mark).includes("EAAG"),
        "token leaked in the mark",
      );

      const { data: logs } = await client
        .from("logs")
        .select("level, category, message")
        .eq("organization_id", fixture.orgA)
        .eq("category", "dispatch")
        .gte("created_at", since)
        .throwOnError();
      assertEquals(logs.length, 1);
      assertEquals(logs[0].level, "error");

      await handler(request(second));
      assertEquals(graph.sends(), 1, "Meta was called with a known-bad token");
      const secondStatus = await statusOf(client, second.id);
      assert(secondStatus.failed);
      assertEquals(secondStatus.pending, undefined);
      assert(
        JSON.stringify(secondStatus.errors).includes("190"),
        JSON.stringify(secondStatus.errors),
      );
    } finally {
      graph.restore();
      await setToken(client, "EAAG-test-secret-a");
      await client.from("messages").delete().in("id", [first.id, second.id]);
      await client.from("logs").delete().eq("organization_id", fixture.orgA)
        .eq("category", "dispatch").gte("created_at", since);
    }
  },
});

Deno.test({
  name: "F28: storing a new token lifts the mark and sends again",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    const since = new Date().toISOString();
    const failing = await outgoingRow(client);
    let graph = stubGraph(EXPIRED);
    let next: MessageRow | undefined;

    try {
      await handler(request(failing));
      assert((await addressExtra(client)).extra.dispatch_auth_failure);
      graph.restore();

      await setToken(client, "EAAG-test-secret-a-renewed");
      assertEquals(
        (await addressExtra(client)).extra.dispatch_auth_failure,
        undefined,
        "a new token did not clear the mark",
      );

      next = await outgoingRow(client);
      graph = stubGraph(() =>
        Promise.resolve(Response.json({
          messaging_product: "whatsapp",
          contacts: [{ input: fixture.contactA1, wa_id: fixture.contactA1 }],
          messages: [{ id: `wamid.F28.${next!.id}` }],
        }))
      );
      await handler(request(next));
      assertEquals(graph.sends(), 1);
      assert((await statusOf(client, next.id)).accepted);
    } finally {
      graph.restore();
      await setToken(client, "EAAG-test-secret-a");
      await client.from("messages").delete().in(
        "id",
        [failing.id, next?.id].filter(Boolean) as string[],
      );
      await client.from("logs").delete().eq("organization_id", fixture.orgA)
        .eq("category", "dispatch").gte("created_at", since);
    }
  },
});
