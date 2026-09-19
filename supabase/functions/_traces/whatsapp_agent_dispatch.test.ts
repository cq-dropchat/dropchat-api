// Trace (a), end to end on a local Supabase with supabase/tests/fixtures
// loaded (IMPLEMENTATION_PROMPT §5):
//
//   signed WhatsApp webhook → row in `messages` → (trigger enqueues)
//   agent-client → agent reply inserted → (trigger enqueues) the dispatcher →
//   a status webhook lands while the dispatcher is still committing (the
//   commitDispatchedMessage race) → a later `read` merges into the same row.
//
// The local edge runtime does not serve functions to pg_net (its requests
// fail with 503), so this test is the worker: it runs each function's handler
// in-process with the payload its trigger sends. That the triggers enqueue
// exactly that payload (URL and `record`) is asserted by pgTAP
// 14_retention.test.sql, where the queue row is visible before pg_net's worker
// takes it. Only the outside world is stubbed: the LLM provider and the Graph
// API.
//
// F12: agent-client is reached through the edge call queue. The test runs
// the queue's worker (dispatch_edge_calls) in a transaction it rolls back,
// takes the pg_net request the worker enqueued — URL, headers, body — and
// delivers exactly that to the handler.
//
// F26: the handlers run wrapped as their entrypoints serve them
// (withRequestLogging). The webhook's request id reaches agent-client through
// PostgREST's request.headers, the queued call and the worker's request; for
// the dispatcher hop (still a direct pg_net call from its trigger) the
// stand-in forwards the `x-request-id` the writing request sent to PostgREST
// (pgTAP 21_request_id asserts the trigger does the same). The webhook,
// agent-client and the dispatcher must log one request id.
import "../_shared/testing/env.ts"; // before the handlers: keys are read at import
import { assert, assertEquals } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import postgres from "postgres";
import type { Database, MessageRow } from "../_shared/types/database_types.ts";
import { env, fixture, supabaseIsUp } from "../_shared/testing/env.ts";
import { metaRequest } from "../_shared/testing/sign.ts";
import { stubLlm, withTestAgent } from "../_shared/testing/agents.ts";
import { withRequestLogging } from "../_shared/logger.ts";
import { handler as whatsappWebhookHandler } from "../whatsapp-webhook/index.ts";
import { handler as agentClientHandler } from "../agent-client/index.ts";
import { handler as whatsappDispatcherHandler } from "../whatsapp-dispatcher/index.ts";

const whatsappWebhook = withRequestLogging(
  "whatsapp-webhook",
  whatsappWebhookHandler,
);
const agentClient = withRequestLogging("agent-client", agentClientHandler);
const whatsappDispatcher = withRequestLogging(
  "whatsapp-dispatcher",
  whatsappDispatcherHandler,
);

const up = await supabaseIsUp();

const CONTACT = "5491100000102"; // contact A2: conversation conv_a2

function service() {
  return createClient<Database>(env.url, env.serviceRoleKey, {
    auth: { persistSession: false },
  });
}

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** The deployed runtime's waitUntil: the webhook acks, then does the work. */
async function deliverWebhook(body: unknown): Promise<string | null> {
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
    return response.headers.get("x-request-id");
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
function triggerRequest(
  url: string,
  record: MessageRow,
  requestId: string | null,
) {
  return new Request(url, {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.serviceRoleKey}`,
      "content-type": "application/json",
      ...(requestId ? { "x-request-id": requestId } : {}),
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

/**
 * The edge call worker, for one queued call: sends it in a transaction that
 * is rolled back, and returns the request pg_net would have made. (The
 * pg_cron worker may already have sent the call to the local runtime, which
 * cannot serve it: resetting it to pending inside the transaction makes the
 * run deterministic.)
 */
async function workerRequest(recordId: string, fn: string): Promise<Request> {
  const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, {
    max: 1,
    onnotice: () => {},
  });
  let captured:
    | { url: string; headers: Record<string, string>; body: string }
    | undefined;
  try {
    await sql.begin(async (transaction) => {
      // postgres.js types TransactionSql without its call signature.
      const tx = transaction as unknown as typeof sql;
      await tx`update public.edge_calls set status = 'pending', next_attempt_at = now()
               where record_id = ${recordId} and function = ${fn}`;
      await tx`select public.dispatch_edge_calls(1000, 1000)`;
      const [row] = await tx`
        select q.url, q.headers, convert_from(q.body, 'utf8') as body
        from public.edge_calls c
        join net.http_request_queue q on q.id = c.request_id
        where c.record_id = ${recordId} and c.function = ${fn}`;
      captured = row as typeof captured;
      throw new Error("rollback");
    }).catch((error) => {
      if (error.message !== "rollback") throw error;
    });
  } finally {
    await sql.end();
  }
  assert(captured, `no queued ${fn} call for ${recordId}`);
  return new Request(`http://localhost/${fn}`, {
    method: "POST",
    headers: captured.headers,
    body: captured.body,
  });
}

/**
 * What PostgREST puts in `request.headers` for the trigger: the x-request-id
 * of the last write to `messages` since `take()`.
 */
function recordMessageWrites() {
  const realFetch = globalThis.fetch;
  let ids: (string | null)[] = [];
  globalThis.fetch = (input, init) => {
    const req = input instanceof Request ? input : new Request(input, init);
    if (
      req.method === "POST" && new URL(req.url).pathname === "/rest/v1/messages"
    ) {
      ids.push(req.headers.get("x-request-id"));
    }
    return realFetch(input, init);
  };
  return {
    take() {
      const last = ids.at(-1) ?? null;
      ids = [];
      return last;
    },
    restore: () => (globalThis.fetch = realFetch),
  };
}

/** The JSON log lines, by function. */
function captureLogs() {
  const original = {
    log: console.log,
    warn: console.warn,
    error: console.error,
  };
  const lines: { fn?: string; request_id?: string }[] = [];
  for (const level of ["log", "warn", "error"] as const) {
    console[level] = (...args: unknown[]) => {
      try {
        lines.push(JSON.parse(String(args[0])));
      } catch {
        original[level](...args);
      }
    };
  }
  return {
    ids: (
      fn: string,
    ) => [
      ...new Set(lines.filter((l) => l.fn === fn).map((l) => l.request_id)),
    ],
    restore: () => Object.assign(console, original),
  };
}

Deno.test({
  name:
    "trace (a): WhatsApp webhook → agent-client → reply → dispatcher → statuses merge into the reply row",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    const run = crypto.randomUUID();
    const inboundWamid = `wamid.TRACE-A.in.${run}`;
    const outboundWamid = `wamid.TRACE-A.out.${run}`;
    const since = new Date(Date.now() - 1000).toISOString();

    const llm = stubLlm(50);
    const writes = recordMessageWrites();
    const logs = captureLogs();
    // Captured after the stubs: the Graph stub below falls through to them.
    const realFetch = globalThis.fetch;

    try {
      await withTestAgent(client, async () => {
        // 1. A signed inbound message.
        writes.take();
        const requestId = await deliverWebhook(change({
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

        // 2. The edge call worker sends agent-client, which answers (the
        //    database clock can run ahead: settle).
        await wait(500);
        writes.take();
        const response = await agentClient(
          await workerRequest(inbound.id, "agent-client"),
        );
        assertEquals(response.status, 200);
        assertEquals(llm.calls(), 1);

        const { data: reply } = await client
          .from("messages")
          .select()
          .eq("conversation_id", inbound.conversation_id)
          .is("sender_address", null)
          // H1: the assignment note is an outgoing row too (no
          // sender_address), and record-only. What the dispatcher sends is
          // the reply, so the note stays out of this trace.
          .is("content->internal", null)
          .gte("created_at", since)
          .single()
          .throwOnError();
        assertEquals(
          (reply.content as { text?: string }).text,
          "respuesta de prueba",
        );

        // 3. Dispatch. Meta answers with the wamid, and its `sent` status
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

        const replyWrite = writes.take();
        const dispatched = await whatsappDispatcher(
          triggerRequest(
            "http://localhost/whatsapp-dispatcher",
            reply as MessageRow,
            replyWrite,
          ),
        );
        assertEquals(dispatched.status, 200);
        assertEquals(graphSends, 1);

        // 4. A `read` after the commit.
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

        // F26: one request id from the webhook to the dispatcher.
        assert(requestId, "the webhook response carries x-request-id");
        assertEquals(logs.ids("agent-client"), [requestId]);
        assertEquals(logs.ids("whatsapp-dispatcher"), [requestId]);
      });
    } finally {
      logs.restore();
      globalThis.fetch = realFetch;
      writes.restore();
      llm.restore();
      await client.from("agent_turns").delete().eq(
        "conversation_id",
        "aaaaaaaa-0000-4000-8000-0000000000c2",
      );
      await client
        .from("edge_calls")
        .delete()
        .eq("organization_id", fixture.orgA)
        .gte("created_at", since);
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
    }
  },
});
