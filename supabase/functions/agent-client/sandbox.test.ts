// S1 — the four things a `local` DM never exercised.
//
// "Chatear con este agente" opened a `local` DM, and `local` is the value
// every Fase H condition names as the exception: selection short-circuits on
// it (the roster IS the decision, so nothing is ever assigned), the welcome
// message is skipped, escalate_to_human is not offered, and with no
// escalation there is no awaiting_human_since either. Four fifths of what
// H1-H6 built was unreachable from the one screen meant to try an agent out.
//
// B1's claim is that a new SERVICE gets all four back without touching any of
// those conditions. These tests are where that claim is either true or not:
// each one pairs the sandbox case with the `local` one it replaces, so what
// is asserted is the DIFFERENCE, not just that sandbox happens to work.
//
// The pure cases need nothing; the two at the bottom run against a local
// Supabase with supabase/tests/fixtures loaded, with the LLM stubbed.
import "../_shared/testing/env.ts"; // before index.ts: keys are read at import
import { assert, assertEquals } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import type {
  AgentRow,
  ConversationRow,
  Database,
  MessageRow,
} from "../_shared/types/database_types.ts";
import type { AgentRowWithExtra } from "./protocols/base.ts";
import { type EntryConfig, selectAgent } from "./selection.ts";
import { buildAgentTools } from "./toolset.ts";
import { ESCALATE_TOOL_NAME } from "./tools/escalate.ts";
import { env, fixture, supabaseIsUp } from "../_shared/testing/env.ts";
import { withTestAgent } from "../_shared/testing/agents.ts";
import { handler } from "./index.ts";

const up = await supabaseIsUp();

// ---------------------------------------------------------------------------
// 1. Selection: sandbox routes and assigns; local does not.
// ---------------------------------------------------------------------------

const AI = {
  id: "agent-ai",
  organization_id: "org-a",
  user_id: null,
  deleted_at: null,
  created_at: "2026-01-01T00:00:00.000Z",
  name: "Sofía",
  extra: { mode: "active" },
} as unknown as AgentRow;

function conversation(service: string): ConversationRow {
  return {
    id: "conv-1",
    organization_id: "org-a",
    service,
    organization_address: "org-a",
    address: "sandbox:tester",
    type: "direct",
    assigned_agent_id: null,
    awaiting_human_since: null,
  } as unknown as ConversationRow;
}

const ORG: EntryConfig = { entry_agent_id: null, extra: null };

Deno.test("S1: a sandbox conversation goes through H1's routing and is assigned", () => {
  const selection = selectAgent(
    conversation("sandbox"),
    [AI],
    undefined,
    ORG,
  );

  assertEquals(selection.agent?.id, AI.id);
  assertEquals(selection.assign, { agent_id: AI.id, cause: "entry" });
});

Deno.test("S1: the local DM it replaces is answered without any assignment", () => {
  const selection = selectAgent(
    conversation("local"),
    [AI],
    AI as AgentRowWithExtra,
    ORG,
  );

  assertEquals(selection.agent?.id, AI.id);
  // The difference: no `assign`, so no note, no cause, nothing for M1 to
  // count and nothing for H4's TTL to expire.
  assertEquals(selection.assign, undefined);
});

// ---------------------------------------------------------------------------
// 2. The escalation tool is offered on sandbox and withheld on local.
// ---------------------------------------------------------------------------

function toolNames(service: string): string[] {
  const agent = { ...AI, extra: { mode: "active" } } as AgentRowWithExtra;

  return buildAgentTools(
    agent,
    new Map(),
    {
      agent,
      conversation: conversation(service),
      // Only `conversation.service` is read on this path.
    } as unknown as Parameters<typeof buildAgentTools>[2],
  )
    .map((tool) => tool.name ?? "");
}

Deno.test("S1: a sandbox agent is offered escalate_to_human", () => {
  assert(
    toolNames("sandbox").includes(ESCALATE_TOOL_NAME),
    "sandbox should offer the escalation tool",
  );
});

Deno.test("S1: the local DM it replaces is not", () => {
  assert(
    !toolNames("local").includes(ESCALATE_TOOL_NAME),
    "local should withhold it: the peer is a colleague, not a customer",
  );
});

// ---------------------------------------------------------------------------
// 3 and 4. End to end, against the database: the welcome message, and an
// escalation that leaves awaiting_human_since behind.
// ---------------------------------------------------------------------------

type Client = ReturnType<typeof service>;

function service() {
  return createClient<Database>(env.url, env.serviceRoleKey, {
    auth: { persistSession: false },
  });
}

/** A message from the tester, written the way the simulator writes it. */
async function inbound(client: Client, tester: string, text: string) {
  const { data } = await client
    .from("messages")
    .insert({
      organization_id: fixture.orgA,
      service: "sandbox",
      organization_address: fixture.orgA,
      conversation_address: tester,
      sender_address: tester,
      content: { version: "1", type: "text", kind: "text", text },
      // Unarmed: the trigger stays quiet and the test invokes the handler
      // itself, one call per message.
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

async function cleanup(client: Client, tester: string) {
  const { data: conv } = await client
    .from("conversations")
    .select("id")
    .eq("organization_id", fixture.orgA)
    .eq("service", "sandbox")
    .eq("address", tester)
    .maybeSingle();

  if (!conv) return;

  await client.from("agent_turns").delete().eq("conversation_id", conv.id);
  await client.from("messages").delete().eq("conversation_id", conv.id);
  await client.from("conversations").delete().eq("id", conv.id);
}

/** A provider that answers from a script, in order. */
function scriptedLlm(
  script: (
    call: number,
  ) => { content?: string; tool_calls?: { name: string; arguments: string }[] },
) {
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
      id: `chatcmpl-sandbox-${requests.length}`,
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

function quietly<T>(fn: () => Promise<T>) {
  const { log, warn, error } = console;
  console.log = console.warn = console.error = () => {};
  return fn().finally(() => Object.assign(console, { log, warn, error }));
}

const test = (name: string, fn: () => Promise<void>) =>
  Deno.test({
    name,
    ignore: !up,
    sanitizeResources: false,
    sanitizeOps: false,
    fn: () => quietly(fn),
  });

test("S1: a sandbox conversation is greeted, and the greeting REPLACES the answer", async () => {
  const client = service();
  const tester = "sandbox:tester-welcome";
  await cleanup(client, tester);
  const llm = scriptedLlm(() => ({ content: "no debería llamarse" }));

  try {
    await withTestAgent(client, async (agentId) => {
      const record = await inbound(client, tester, "hola");
      await settle();
      await invoke(record);

      const { data: written } = await client
        .from("messages")
        .select("content, agent_id")
        .eq("conversation_id", record.conversation_id)
        .gt("created_at", record.created_at)
        .order("created_at")
        .throwOnError();

      const texts = (written ?? []).map((row) =>
        (row.content as { text?: string }).text
      );

      assert(
        texts.includes("Probando el simulador"),
        `expected the welcome message, got ${JSON.stringify(texts)}`,
      );
      // It replaces the first answer rather than preceding it: the provider
      // is never asked. On `local` there is no greeting at all.
      assertEquals(llm.requests.length, 0);

      // H1 ran: the conversation now has an owner, which a local DM never
      // gets.
      const { data: conv } = await client
        .from("conversations")
        .select("assigned_agent_id")
        .eq("id", record.conversation_id)
        .single()
        .throwOnError();

      assertEquals(conv.assigned_agent_id, agentId);
    }, { welcome_message: "Probando el simulador" });
  } finally {
    llm.restore();
    await cleanup(client, tester);
  }
});

test("S1: escalating in the simulator leaves awaiting_human_since, as on a real channel", async () => {
  const client = service();
  const tester = "sandbox:tester-escalation";
  await cleanup(client, tester);
  const llm = scriptedLlm((call) =>
    call === 1
      ? {
        tool_calls: [{
          name: ESCALATE_TOOL_NAME,
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
            messages: [{ type: "text", text: "Te atiende una persona." }],
          }),
        }],
      }
  );

  try {
    await withTestAgent(client, async () => {
      const record = await inbound(client, tester, "mi pedido llegó roto");
      await settle();
      await invoke(record);

      const { data: conv } = await client
        .from("conversations")
        .select("awaiting_human_since, assigned_agent_id")
        .eq("id", record.conversation_id)
        .single()
        .throwOnError();

      assert(
        conv.awaiting_human_since !== null,
        "the simulator should be able to reach H3's hand-over",
      );
      assertEquals(conv.assigned_agent_id, null);

      // And the audit note is the real one, with the real closed vocabulary
      // — which is what makes the simulator worth anything for T5 later.
      const { data: notes } = await client
        .from("messages")
        .select("content")
        .eq("conversation_id", record.conversation_id)
        .gt("created_at", record.created_at)
        .throwOnError();

      const assignments = (notes ?? [])
        .map((row) => row.content as { kind?: string; data?: unknown })
        .filter((content) => content.kind === "assignment")
        .map((content) =>
          content.data as { cause?: string; category?: string }
        );

      // TWO notes, and the pair is the point: the simulator walks the whole
      // of H1 (routing put the conversation in the agent's hands) and then
      // the whole of H3 (the agent gave it up). A `local` DM produces
      // neither.
      //
      // Compared as a SET, not as a sequence. Both notes are written by the
      // same invocation and the query above has no ORDER BY, so their order
      // is whatever the plan returns — this asserted `["entry",
      // "escalation"]` and got the reverse roughly once in a run. Ordering by
      // `created_at` would not settle it either: `now()` is transaction time,
      // so notes written in one transaction share it. The escalation is then
      // identified by its cause rather than by its position.
      assertEquals(
        assignments.map((a) => a.cause).sort(),
        ["entry", "escalation"],
      );
      assertEquals(
        assignments.find((a) => a.cause === "escalation")?.category,
        "reclamo",
      );
    }, { multi_message_response: true });
  } finally {
    llm.restore();
    await cleanup(client, tester);
  }
});
