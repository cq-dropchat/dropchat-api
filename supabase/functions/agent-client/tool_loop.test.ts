// F29 (step 3) — characterization of agent-client's request loop, written
// before splitting index.ts (1,107 lines) into modules.
//
// The F16/F23 tests use a tool-less agent, so the ~500-line tool loop had no
// test. These scenarios drive it with a scripted LLM and snapshot the rows
// the handler writes and the requests it sends:
//   - a round of tool calls — a valid calculator call, one with invalid
//     arguments, and a tool the agent does not have — then the answer;
//   - an LLM that never stops calling tools (the iteration cap);
//   - an agent with a welcome message in a new conversation.
//
// Runs against a local Supabase with supabase/tests/fixtures loaded. Only the
// LLM provider is stubbed. Regenerate only for an intended change:
//   deno test -A agent-client/tool_loop.test.ts -- --update
import "../_shared/testing/env.ts"; // before index.ts: keys are read at import
import { assert, assertEquals } from "jsr:@std/assert@1";
import { assertSnapshot } from "jsr:@std/testing@1/snapshot";
import { createClient } from "@supabase/supabase-js";
import type { Database, MessageRow } from "../_shared/types/database_types.ts";
import { env, fixture, supabaseIsUp } from "../_shared/testing/env.ts";
import { withTestAgent } from "../_shared/testing/agents.ts";
import { handler } from "./index.ts";

const up = await supabaseIsUp();

type Client = ReturnType<typeof service>;

function service() {
  return createClient<Database>(env.url, env.serviceRoleKey, {
    auth: { persistSession: false },
  });
}

type Completion = {
  content?: string | null;
  tool_calls?: { name: string; arguments: string }[];
};

/** A chat-completions provider that answers from a script, in order. */
function scriptedLlm(script: (call: number) => Completion) {
  const realFetch = globalThis.fetch;
  const requests: unknown[] = [];
  globalThis.fetch = async (input, init) => {
    const url = input instanceof Request ? input.url : String(input);
    if (!url.startsWith("https://api.groq.com/")) {
      return realFetch(input, init);
    }
    const body = input instanceof Request
      ? await input.clone().text()
      : String(init?.body);
    requests.push(JSON.parse(body));
    const turn = script(requests.length);
    const tool_calls = turn.tool_calls?.map((c, i) => ({
      id: `call_${requests.length}_${i}`,
      type: "function",
      function: { name: c.name, arguments: c.arguments },
    }));
    return Response.json({
      id: `chatcmpl-test-${requests.length}`,
      object: "chat.completion",
      created: 0,
      model: "openai/gpt-oss-20b",
      choices: [{
        index: 0,
        message: {
          role: "assistant",
          content: turn.content ?? null,
          ...(tool_calls && { tool_calls }),
        },
        finish_reason: tool_calls ? "tool_calls" : "stop",
      }],
      usage: { prompt_tokens: 10, completion_tokens: 3, total_tokens: 13 },
    });
  };
  return { requests, restore: () => (globalThis.fetch = realFetch) };
}

const settle = () => new Promise((r) => setTimeout(r, 500));

async function inbound(client: Client, contact: string, text: string) {
  const { data } = await client
    .from("messages")
    .insert({
      organization_id: fixture.orgA,
      service: "whatsapp",
      organization_address: fixture.waA,
      conversation_address: contact,
      sender_address: contact,
      content: { version: "1", type: "text", kind: "text", text },
      status: { delivered: new Date().toISOString() },
    })
    .select()
    .single()
    .throwOnError();
  return data as MessageRow;
}

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

async function written(client: Client, record: MessageRow) {
  const { data } = await client
    .from("messages")
    .select("sender_address, agent_id, content, status")
    .eq("conversation_id", record.conversation_id)
    .gt("created_at", record.created_at)
    // Both clocks, in the order that makes each one decisive where it is the
    // reliable one. `created_at` is the database's and separates writes:
    // H1's assignment note is its own transaction, so it lands where it was
    // written (ordering by `timestamp` put it among the tool traces or not,
    // depending on a millisecond of skew between the database's clock and the
    // function's). `timestamp` is agent-client's own and separates the rows
    // of ONE batch, which share a `created_at` — a tool use from its result.
    .order("created_at")
    .order("timestamp")
    .throwOnError();
  return data;
}

async function cleanup(client: Client, contact: string) {
  const { data: conv } = await client
    .from("conversations")
    .select("id")
    .eq("organization_id", fixture.orgA)
    .eq("address", contact)
    .maybeSingle();
  if (!conv) return;
  await client.from("agent_turns").delete().eq("conversation_id", conv.id);
  await client.from("messages").delete().eq("conversation_id", conv.id);
  await client.from("conversations").delete().eq("id", conv.id);
}

const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g;

/** Any ISO-8601 instant, whole-string: these rows carry no fixed one. */
const ISO = /^\d{4}-\d{2}-\d{2}T[\d:.]+(Z|[+-]\d{2}:?\d{2})?$/;

/**
 * Replaces what depends on the run: ids and timestamps.
 *
 * Masks by SHAPE and not by age. It used to mask an instant only when it was
 * newer than `Date.now() - 1000`, which made the snapshot depend on the two
 * clocks agreeing to within a second: these rows are written with the
 * DATABASE's clock and compared by Deno's, and this repo already knows they
 * drift (P1 exists because the database ran ahead). Under a loaded run the
 * row fell outside the window, the real instant reached the snapshot, and the
 * test failed for a reason that had nothing to do with the tool loop.
 *
 * Nothing is lost by widening it: not one of these timestamps is an
 * expectation — they were all going to be `<now>`.
 */
function stable(value: unknown, agentId: string): unknown {
  if (typeof value === "string") {
    if (ISO.test(value)) return "<now>";

    return value.replaceAll(agentId, "<agent>").replace(UUID, "<uuid>")
      .replace(/(\w+day), \d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC/, "<now>");
  }
  if (Array.isArray(value)) return value.map((v) => stable(v, agentId));
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map((
        [k, v],
      ) => [k, stable(v, agentId)]),
    );
  }
  return value;
}

function quietly<T>(fn: () => Promise<T>) {
  const { log, warn, error } = console;
  console.log = console.warn = console.error = () => {};
  return fn().finally(() => Object.assign(console, { log, warn, error }));
}

const CALCULATOR = { provider: "local", type: "function", name: "calculator" };

const test = (name: string, fn: (t: Deno.TestContext) => Promise<void>) =>
  Deno.test({
    name,
    ignore: !up,
    sanitizeResources: false,
    sanitizeOps: false,
    fn: (t) => quietly(() => fn(t)),
  });

test("F29: agent-client tool round, then the answer (characterization)", async (t) => {
  const client = service();
  const contact = "5491129100001";
  await cleanup(client, contact);
  const llm = scriptedLlm((call) =>
    call === 1
      ? {
        tool_calls: [
          { name: "calculator", arguments: '{"expression":"2+2"}' },
          { name: "calculator", arguments: '{"expr":1}' },
          { name: "weather", arguments: "{}" },
        ],
      }
      : {
        tool_calls: [{
          name: "respond",
          arguments: JSON.stringify({
            messages: [{ type: "text", text: "Son 4." }],
          }),
        }],
      }
  );

  try {
    await withTestAgent(client, async (agentId) => {
      const record = await inbound(client, contact, "¿cuánto es 2+2?");
      await settle();
      await invoke(record);

      await assertSnapshot(
        t,
        stable(
          {
            rows: await written(client, record),
            requests: llm.requests.map((r) =>
              (r as { messages: unknown[] }).messages
            ),
          },
          agentId,
        ),
      );
    }, { tools: [CALCULATOR] });
  } finally {
    llm.restore();
    await cleanup(client, contact);
  }
});

test("F29: agent-client stops after ten iterations (characterization)", async (t) => {
  const client = service();
  const contact = "5491129100002";
  await cleanup(client, contact);
  const llm = scriptedLlm(() => ({
    tool_calls: [{ name: "calculator", arguments: '{"expression":"1+1"}' }],
  }));

  try {
    await withTestAgent(client, async (agentId) => {
      const record = await inbound(client, contact, "calculá para siempre");
      await settle();
      await invoke(record);

      const rows = await written(client, record);
      await assertSnapshot(
        t,
        stable(
          { llmCalls: llm.requests.length, rows },
          agentId,
        ),
      );
    }, { tools: [CALCULATOR] });
  } finally {
    llm.restore();
    await cleanup(client, contact);
  }
});

test("F29: agent-client greets a new conversation (characterization)", async (t) => {
  const client = service();
  const contact = "5491129100003";
  await cleanup(client, contact);
  const llm = scriptedLlm(() => ({ content: "no debería llamarse" }));

  try {
    await withTestAgent(client, async (agentId) => {
      const record = await inbound(client, contact, "hola");
      await settle();
      await invoke(record);

      await assertSnapshot(
        t,
        stable(
          {
            llmCalls: llm.requests.length,
            rows: await written(client, record),
          },
          agentId,
        ),
      );
    }, { welcome_message: "¡Bienvenido! ¿En qué te ayudo?" });
  } finally {
    llm.restore();
    await cleanup(client, contact);
  }
});

// ---------------------------------------------------------------------------
// H3 — handing the conversation to a person.
//
// Failure scenario without it: the agent's only exits are to keep trying or
// to go quiet, so a complaint or a payment gone wrong stays with the bot
// until the customer gives up.
// ---------------------------------------------------------------------------

test("H3: escalate_to_human stops the AI and records why", async () => {
  const client = service();
  const contact = "5491129100004";
  await cleanup(client, contact);
  // Hand over, then say goodbye — the flow the tool's description asks for.
  // It cannot be one message: a `respond` call ends the round and the
  // protocol drops every other tool call in it, so the goodbye is the one
  // iteration the agent has left after escalating.
  const llm = scriptedLlm((call) =>
    call === 1
      ? {
        tool_calls: [{
          name: "escalate_to_human",
          arguments: JSON.stringify({
            category: "reclamo",
            reason: "el pedido llegó dañado",
          }),
        }],
      }
      : {
        tool_calls: [{
          name: "respond",
          arguments: JSON.stringify({
            messages: [{
              type: "text",
              text: "Lamento lo del pedido. Te atiende una persona del equipo.",
            }],
          }),
        }],
      }
  );

  try {
    await withTestAgent(client, async (agentId) => {
      const record = await inbound(client, contact, "me llegó roto el pedido");
      await settle();
      await invoke(record);

      const { data: conv } = await client
        .from("conversations")
        .select("assigned_agent_id, awaiting_human_since")
        .eq("id", record.conversation_id)
        .single()
        .throwOnError();

      assertEquals(conv.assigned_agent_id, null);

      // The goodbye was sent: the escalation of this same turn does not eat
      // the message that explains it.
      const said = (await written(client, record)).filter((r) =>
        r.sender_address === null &&
        (r.content as { internal?: boolean }).internal !== true
      );

      assertEquals(
        said.length,
        1,
        JSON.stringify({
          rows: await written(client, record),
          calls: llm.requests.length,
        }),
      );
      // Two rounds and no more: the escalation buys exactly one goodbye.
      assertEquals(llm.requests.length, 2);
      assertEquals(
        (said[0].content as { text: string }).text,
        "Lamento lo del pedido. Te atiende una persona del equipo.",
      );
      assert(conv.awaiting_human_since !== null);

      const { data: notes } = await client
        .from("messages")
        .select("content")
        .eq("conversation_id", record.conversation_id)
        .eq("content->>kind", "assignment")
        .eq("content->data->>cause", "escalation")
        .throwOnError();

      assertEquals(notes.length, 1);

      const data = (notes[0].content as { data: Record<string, unknown> }).data;

      assertEquals(data.category, "reclamo");
      assertEquals(data.reason, "el pedido llegó dañado");
      assertEquals(data.awaiting_human, true);
      assertEquals(data.by, agentId);

      // A message from the contact now goes unanswered: a person was
      // promised, and the LLM is not called again.
      const callsBefore = llm.requests.length;
      const followUp = await inbound(client, contact, "¿hay alguien?");
      await settle();
      await invoke(followUp);

      assertEquals(llm.requests.length, callsBefore);

      // Handed back to the AI, it answers again.
      await client.rpc("set_conversation_assignment", {
        p_conversation_id: record.conversation_id,
        p_agent_id: agentId,
        p_awaiting_human: false,
        p_actor_agent_id: null as unknown as string,
        p_reason: { cause: "manual" },
      });

      const third = await inbound(client, contact, "sigo esperando");
      await settle();
      await invoke(third);

      assert(llm.requests.length > callsBefore);
    });
  } finally {
    llm.restore();
    await cleanup(client, contact);
  }
});

test("H3: an agent with can_escalate false is not offered the tool", async () => {
  const client = service();
  const contact = "5491129100005";
  await cleanup(client, contact);
  const llm = scriptedLlm(() => ({ content: "listo" }));

  try {
    await withTestAgent(client, async () => {
      const record = await inbound(client, contact, "hola");
      await settle();
      await invoke(record);

      const names =
        (llm.requests[0] as { tools?: { function: { name: string } }[] })
          .tools?.map((t) => t.function.name) ?? [];

      assertEquals(names.includes("escalate_to_human"), false);
    }, { can_escalate: false, multi_message_response: false });
  } finally {
    llm.restore();
    await cleanup(client, contact);
  }
});
