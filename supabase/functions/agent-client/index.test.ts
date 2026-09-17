// F16 — agent-client end to end: every armed inbound message wakes the
// handler, and the in-memory created_at comparison was all that kept two
// invocations from two paid LLM calls. A duplicate invocation of the same
// message (a retried pg_net request, a replayed trigger) answered twice.
//
// Runs against a local Supabase with supabase/tests/fixtures loaded. The
// LLM provider is stubbed and counted; everything else is real.
import "../_shared/testing/env.ts"; // before index.ts: keys are read at import
import { assertEquals } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import type { Database, MessageRow } from "../_shared/types/database_types.ts";
import { env, fixture, supabaseIsUp } from "../_shared/testing/env.ts";
import { handler } from "./index.ts";

const up = await supabaseIsUp();

const CONV_A2 = "aaaaaaaa-0000-4000-8000-0000000000c2";
const CONTACT_A2 = "5491100000102";

function service() {
  return createClient<Database>(env.url, env.serviceRoleKey, {
    auth: { persistSession: false },
  });
}

/** The test agent talks to Groq; count those calls and answer with text. */
function stubLlm(latencyMs = 200) {
  const realFetch = globalThis.fetch;
  let calls = 0;
  let active = 0;
  let maxActive = 0;
  const bodies: string[] = [];
  globalThis.fetch = async (input, init) => {
    const url = input instanceof Request ? input.url : String(input);
    if (url.startsWith("https://api.groq.com/")) {
      calls++;
      active++;
      maxActive = Math.max(maxActive, active);
      bodies.push(
        input instanceof Request
          ? await input.clone().text()
          : String(init?.body),
      );
      await new Promise((r) => setTimeout(r, latencyMs));
      active--;
      return Response.json({
        id: `chatcmpl-test-${crypto.randomUUID()}`,
        object: "chat.completion",
        created: Math.floor(Date.now() / 1000),
        model: "openai/gpt-oss-20b",
        choices: [{
          index: 0,
          message: { role: "assistant", content: "respuesta de prueba" },
          finish_reason: "stop",
        }],
        usage: { prompt_tokens: 10, completion_tokens: 3, total_tokens: 13 },
      });
    }
    return realFetch(input, init);
  };
  return {
    calls: () => calls,
    maxActive: () => maxActive,
    bodies,
    restore: () => (globalThis.fetch = realFetch),
  };
}

/**
 * Robot A's fixture tools point at hosts that do not resolve. Park it and
 * answer with a tool-less AI agent for the test's duration.
 */
async function withTestAgent(
  client: ReturnType<typeof service>,
  fn: () => Promise<void>,
) {
  const { data: robot } = await client
    .from("agents")
    .select("extra")
    .eq("id", fixture.agentRobotA)
    .single()
    .throwOnError();
  // deno-lint-ignore no-explicit-any
  const extra = robot.extra as any;

  await client
    .from("agents")
    .update({ extra: { ...extra, mode: "inactive" } })
    .eq("id", fixture.agentRobotA)
    .throwOnError();

  const { data: agent } = await client
    .from("agents")
    .insert({
      organization_id: fixture.orgA,
      name: "Robot F16",
      extra: {
        mode: "active",
        protocol: "chat_completions",
        api_url: "https://api.groq.com/openai/v1",
        api_key: "sk-test-f16-not-a-key",
        model: "openai/gpt-oss-20b",
        instructions: "You are a test robot.",
        response_delay_seconds: 0,
      },
    })
    .select("id")
    .single()
    .throwOnError();

  try {
    await fn();
  } finally {
    await client.from("agents").delete().eq("id", agent.id);
    await client
      .from("agents")
      .update({ extra })
      .eq("id", fixture.agentRobotA)
      .throwOnError();
  }
}

async function inbound(client: ReturnType<typeof service>, text: string) {
  // Unarmed (no status.pending): the trigger stays quiet and the test makes
  // every invocation itself.
  const { data } = await client
    .from("messages")
    .insert({
      organization_id: fixture.orgA,
      service: "whatsapp",
      organization_address: fixture.waA,
      conversation_address: CONTACT_A2,
      sender_address: CONTACT_A2,
      content: { version: "1", type: "text", kind: "text", text },
      status: { delivered: new Date().toISOString() },
    })
    .select()
    .single()
    .throwOnError();
  return data as MessageRow;
}

// The local database clock can run ahead of Deno's, and the handler reads
// history up to its own now(): wait out the skew, as pg_net's latency does.
const settle = () => new Promise((r) => setTimeout(r, 500));

function invoke(record: MessageRow) {
  return handler(
    new Request("http://localhost/agent-client", {
      method: "POST",
      headers: {
        authorization: `Bearer ${env.serviceRoleKey}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ type: "INSERT", table: "messages", record }),
    }),
  );
}

async function cleanup(client: ReturnType<typeof service>, since: string) {
  await client.from("agent_turns").delete().eq("conversation_id", CONV_A2);
  await client.from("messages").delete().eq("conversation_id", CONV_A2).gte(
    "created_at",
    since,
  );
}

async function replies(client: ReturnType<typeof service>, since: string) {
  const { data } = await client
    .from("messages")
    .select("id")
    .eq("conversation_id", CONV_A2)
    .is("sender_address", null)
    .gte("created_at", since)
    .throwOnError();
  return data.length;
}

Deno.test({
  name: "F16: a duplicate invocation of one message makes one LLM call",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    const since = new Date(Date.now() - 1000).toISOString();
    await cleanup(client, since);
    const llm = stubLlm();

    try {
      await withTestAgent(client, async () => {
        const m = await inbound(client, "hola");
        await settle();
        await Promise.all([invoke(m), invoke(m)]);

        assertEquals(llm.calls(), 1);
        assertEquals(await replies(client, since), 1);
      });
    } finally {
      llm.restore();
      await cleanup(client, since);
    }
  },
});

Deno.test({
  name: "F16: two inbound messages in one conversation make one LLM call",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    const since = new Date(Date.now() - 1000).toISOString();
    await cleanup(client, since);
    const llm = stubLlm();

    try {
      await withTestAgent(client, async () => {
        const m1 = await inbound(client, "hola");
        const m2 = await inbound(client, "¿están?");
        await settle();
        await Promise.all([invoke(m1), invoke(m2)]);

        assertEquals(llm.calls(), 1);
        assertEquals(await replies(client, since), 1);
      });
    } finally {
      llm.restore();
      await cleanup(client, since);
    }
  },
});

Deno.test({
  name:
    "F16: a message arriving mid-answer waits for it and is answered with that reply in the history",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    const since = new Date(Date.now() - 1000).toISOString();
    await cleanup(client, since);
    const llm = stubLlm(1500);

    try {
      await withTestAgent(client, async () => {
        const m1 = await inbound(client, "hola");
        await settle();
        const first = invoke(m1);

        // m1's LLM call is in flight.
        await new Promise((r) => setTimeout(r, 800));
        const m2 = await inbound(client, "¿están?");
        await settle();
        await Promise.all([first, invoke(m2)]);

        assertEquals(llm.calls(), 2);
        assertEquals(llm.maxActive(), 1);
        assertEquals(await replies(client, since), 2);
        // The second call saw the first answer.
        assertEquals(llm.bodies[1].includes("respuesta de prueba"), true);
      });
    } finally {
      llm.restore();
      await cleanup(client, since);
    }
  },
});
