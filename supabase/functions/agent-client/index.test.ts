// F16 — agent-client end to end: every armed inbound message wakes the
// handler, and the in-memory created_at comparison was all that kept two
// invocations from two paid LLM calls. A duplicate invocation of the same
// message (a retried pg_net request, a replayed trigger) answered twice.
//
// Runs against a local Supabase with supabase/tests/fixtures loaded. The
// LLM provider is stubbed and counted; everything else is real.
import "../_shared/testing/env.ts"; // before index.ts: keys are read at import
import { assert, assertEquals } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import type { Database, MessageRow } from "../_shared/types/database_types.ts";
import { env, fixture, supabaseIsUp } from "../_shared/testing/env.ts";
import { handler } from "./index.ts";
import { stubLlm, withTestAgent } from "../_shared/testing/agents.ts";

const up = await supabaseIsUp();

const CONV_A2 = "aaaaaaaa-0000-4000-8000-0000000000c2";
const CONTACT_A2 = "5491100000102";

function service() {
  return createClient<Database>(env.url, env.serviceRoleKey, {
    auth: { persistSession: false },
  });
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
    // H1: record-only rows are outgoing rows too (the assignment note carries
    // no sender_address). What this counts is what the contact would receive.
    .is("content->internal", null)
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

// ---------------------------------------------------------------------------
// F23 — the context query read `organizations(*, agents(*))`: every agent of
// the organization, members and retired AIs included, with their `extra`, and
// then decrypted the secrets of all of them — on every invocation. Only the
// live AI agents take part in selection; a local DM's author needs a name.
// ---------------------------------------------------------------------------

/** Records PostgREST calls (URL and JSON body) made through global fetch. */
function recordRest() {
  const realFetch = globalThis.fetch;
  const calls: { url: string; body: unknown }[] = [];
  globalThis.fetch = async (input, init) => {
    const response = await realFetch(input, init);
    const url = input instanceof Request ? input.url : String(input);
    if (url.startsWith(`${env.url}/rest/v1/`)) {
      const text = await response.clone().text();
      let body: unknown = text;
      try {
        body = JSON.parse(text);
      } catch { /* not JSON */ }
      calls.push({ url: decodeURIComponent(url), body });
    }
    return response;
  };
  return { calls, restore: () => (globalThis.fetch = realFetch) };
}

Deno.test({
  name:
    "F23: the context carries only live AI agents, and only their secrets are read",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    const since = new Date(Date.now() - 1000).toISOString();
    await cleanup(client, since);
    const llm = stubLlm(10);
    const rest = recordRest();

    try {
      await withTestAgent(client, async (testAgentId) => {
        const m = await inbound(client, "hola");
        await settle();
        await invoke(m);
        assertEquals(llm.calls(), 1);

        const context = rest.calls.find((c) =>
          c.url.includes("/rest/v1/conversations?") &&
          c.url.includes("organizations")
        );
        assert(context, "no context query recorded");
        const agents = (context.body as {
          organizations: {
            agents: {
              id: string;
              user_id: string | null;
              deleted_at: string | null;
            }[];
          };
        }).organizations.agents;
        assert(
          agents.some((a) => a.id === testAgentId),
          "the answering agent is missing",
        );
        for (const a of agents) {
          assertEquals(a.user_id, null, `member row ${a.id} loaded`);
          assertEquals(a.deleted_at, null, `retired agent ${a.id} loaded`);
        }

        const secrets = rest.calls.filter((c) =>
          c.url.includes("/rest/v1/secrets?") &&
          c.url.includes("scope=eq.agent")
        );
        for (const c of secrets) {
          assert(
            !c.url.includes(fixture.agentAlice),
            `a member's secrets were read: ${c.url}`,
          );
        }
      });
    } finally {
      rest.restore();
      llm.restore();
      await cleanup(client, since);
    }
  },
});

Deno.test({
  name: "F23: a local DM with an AI still names its author to the model",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    const llm = stubLlm(10);
    let address = "";

    try {
      await withTestAgent(client, async (testAgentId) => {
        address = [fixture.agentAlice, testAgentId].sort().join(":");
        const { data: local } = await client
          .from("organizations_addresses")
          .select("address")
          .eq("organization_id", fixture.orgA)
          .eq("service", "local")
          .limit(1)
          .single()
          .throwOnError();
        const { data: m } = await client
          .from("messages")
          .insert({
            organization_id: fixture.orgA,
            service: "local",
            organization_address: local.address,
            conversation_address: address,
            agent_id: fixture.agentAlice,
            content: {
              version: "1",
              type: "text",
              kind: "text",
              text: "hola robot",
            },
            status: { delivered: new Date().toISOString() },
          })
          .select()
          .single()
          .throwOnError();
        await settle();
        await invoke(m as MessageRow);

        assertEquals(llm.calls(), 1);
        assert(llm.bodies[0].includes("name: 'Alice'"), llm.bodies[0]);
      });
    } finally {
      llm.restore();
      if (address) {
        const { data: conv } = await client.from("conversations").select("id")
          .eq("organization_id", fixture.orgA).eq("service", "local")
          .eq("address", address).maybeSingle();
        if (conv) {
          await client.from("agent_turns").delete().eq(
            "conversation_id",
            conv.id,
          );
          await client.from("messages").delete().eq("conversation_id", conv.id);
          await client.from("conversations").delete().eq("id", conv.id);
        }
      }
    }
  },
});

// ---------------------------------------------------------------------------
// P1 — the window was bounded by the function's own clock while the rows are
// stamped by the database's. With the database ahead, the triggering row fell
// outside the window, `getNewestIncomingMessage` returned `undefined` and the
// handler threw a TypeError: 500, and the contact never got an answer.
// ---------------------------------------------------------------------------

/** Runs the function's clock `ms` behind the database's, as real skew does. */
function skewClockBack(ms: number) {
  const RealDate = Date;
  class SkewedDate extends RealDate {
    // deno-lint-ignore no-explicit-any
    constructor(...args: any[]) {
      // No arguments means "now", which is where the skew lives.
      // deno-lint-ignore no-explicit-any
      super(...(args.length ? args : [RealDate.now() - ms]) as [any]);
    }
    static override now() {
      return RealDate.now() - ms;
    }
  }
  // deno-lint-ignore no-explicit-any
  globalThis.Date = SkewedDate as any;
  return { restore: () => (globalThis.Date = RealDate) };
}

Deno.test({
  name:
    "P1: a database clock ahead of the function's still gets one answer, not a TypeError",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    const since = new Date(Date.now() - 1000).toISOString();
    await cleanup(client, since);
    const llm = stubLlm();
    // No settle(): the skew is the case under test. The agent answers with
    // response_delay_seconds: 0, where any skew at all is enough.
    const clock = skewClockBack(2000);

    try {
      await withTestAgent(client, async () => {
        const m = await inbound(client, "hola");
        await invoke(m);

        assertEquals(llm.calls(), 1);
        assertEquals(await replies(client, since), 1);
      });
    } finally {
      clock.restore();
      llm.restore();
      await cleanup(client, since);
    }
  },
});

// ---------------------------------------------------------------------------
// H1 — who answers is a property of the CONVERSATION. Before this, the choice
// was remade on every message ("the oldest AI agent that is not inactive"), so
// creating an agent could silently move conversations already underway onto
// it, and nothing recorded who was answering.
// ---------------------------------------------------------------------------

async function assignmentOf(client: ReturnType<typeof service>) {
  const { data } = await client
    .from("conversations")
    .select("assigned_agent_id")
    .eq("id", CONV_A2)
    .single()
    .throwOnError();

  return data.assigned_agent_id;
}

async function assignmentNotes(
  client: ReturnType<typeof service>,
  since: string,
) {
  const { data } = await client
    .from("messages")
    .select("content, status")
    .eq("conversation_id", CONV_A2)
    .eq("content->>kind", "assignment")
    .gte("created_at", since)
    .throwOnError();

  return data as unknown as {
    content: { data: Record<string, unknown> };
    status: Record<string, unknown>;
  }[];
}

/**
 * The entry agent is set explicitly in these two cases. `withTestAgent`
 * parks Robot A and adds its own agent, but a local database also carries the
 * retired-and-not-so-retired leftovers of earlier runs (see
 * IMPLEMENTATION_STATUS), so "the oldest eligible agent" is not a stable
 * fixture. The entry agent is: it is the organization's own answer to who
 * takes a new conversation.
 */
async function setEntryAgent(
  client: ReturnType<typeof service>,
  agentId: string | null,
) {
  await client
    .from("organizations")
    .update({ entry_agent_id: agentId })
    .eq("id", fixture.orgA)
    .throwOnError();
}

/** The gate is the only writer, so the reset goes through it too. */
async function unassign(client: ReturnType<typeof service>) {
  await client.rpc("set_conversation_assignment", {
    p_conversation_id: CONV_A2,
    p_agent_id: null as unknown as string,
    p_awaiting_human: false,
    p_actor_agent_id: null as unknown as string,
    p_reason: { cause: "manual" },
  });
}

Deno.test({
  name: "H1: the first answer assigns the conversation and records why",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    const since = new Date(Date.now() - 1000).toISOString();
    await unassign(client);
    await cleanup(client, since);
    const llm = stubLlm();

    try {
      await withTestAgent(client, async (agentId) => {
        await setEntryAgent(client, agentId);

        const m = await inbound(client, "hola");
        await settle();
        await invoke(m);

        assertEquals(llm.calls(), 1);
        assertEquals(await assignmentOf(client), agentId);

        const notes = await assignmentNotes(client, since);

        assertEquals(notes.length, 1);
        assertEquals(notes[0].content.data.cause, "entry");
        assertEquals(notes[0].content.data.to, agentId);
        assertEquals(notes[0].content.data.from, null);
        // Record-only: unarmed, so no dispatcher ever looks at it.
        assertEquals(notes[0].status, {});
      });
    } finally {
      llm.restore();
      await setEntryAgent(client, null);
      await unassign(client);
      await cleanup(client, since);
    }
  },
});

Deno.test({
  name:
    "H1: the second message keeps the same agent, even if an older one appeared meanwhile",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    const since = new Date(Date.now() - 1000).toISOString();
    await unassign(client);
    await cleanup(client, since);
    const llm = stubLlm();
    let intruderId: string | undefined;

    try {
      await withTestAgent(client, async (agentId) => {
        await setEntryAgent(client, agentId);

        const m1 = await inbound(client, "hola");
        await settle();
        await invoke(m1);

        assertEquals(await assignmentOf(client), agentId);

        // An agent created now but backdated before the one answering: under
        // the old rule it would have taken over the conversation mid-thread.
        const { data: intruder } = await client
          .from("agents")
          .insert({
            organization_id: fixture.orgA,
            name: "Robot H1 intruder",
            created_at: "2000-01-01T00:00:00.000Z",
            extra: {
              mode: "active",
              protocol: "chat_completions",
              api_url: "https://api.groq.com/openai/v1",
              api_key: "sk-test-h1-not-a-key",
              model: "openai/gpt-oss-20b",
              instructions: "You are the wrong robot.",
              response_delay_seconds: 0,
            },
          })
          .select("id")
          .single()
          .throwOnError();

        intruderId = intruder.id;

        const m2 = await inbound(client, "¿están?");
        await settle();
        await invoke(m2);

        assertEquals(await assignmentOf(client), agentId);

        const { data: answers } = await client
          .from("messages")
          .select("agent_id")
          .eq("conversation_id", CONV_A2)
          .is("sender_address", null)
          .is("content->internal", null)
          .gte("created_at", since)
          .throwOnError();

        assert(answers.length >= 2);
        assertEquals(
          answers.every((a) => a.agent_id === agentId),
          true,
        );

        // Assignment happened once: the second message found an owner.
        assertEquals((await assignmentNotes(client, since)).length, 1);
      });
    } finally {
      llm.restore();
      if (intruderId) {
        await client.from("agents").delete().eq("id", intruderId);
      }
      await setEntryAgent(client, null);
      await unassign(client);
      await cleanup(client, since);
    }
  },
});

Deno.test({
  name: "H3: a human who takes the conversation mid-answer gets the last word",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    const since = new Date(Date.now() - 1000).toISOString();
    await unassign(client);
    await cleanup(client, since);
    // Slow enough to step in while the model is still thinking.
    const llm = stubLlm(1500);

    try {
      await withTestAgent(client, async (agentId) => {
        await setEntryAgent(client, agentId);

        const m = await inbound(client, "quiero hablar con alguien");
        await settle();
        const answering = invoke(m);

        // The LLM call is in flight; a person answers by hand, which takes
        // the conversation (the implicit takeover of H3).
        await new Promise((r) => setTimeout(r, 700));

        await client
          .from("messages")
          .insert({
            organization_id: fixture.orgA,
            service: "whatsapp",
            organization_address: fixture.waA,
            conversation_address: CONTACT_A2,
            agent_id: fixture.agentAlice,
            content: {
              version: "1",
              type: "text",
              kind: "text",
              text: "Hola, soy Alice del equipo.",
            },
            // Armed, like the row the UI writes when a person hits send:
            // the takeover trigger is about messages that actually go out.
            status: { pending: new Date().toISOString() },
          })
          .throwOnError();

        await answering;

        assertEquals(await assignmentOf(client), fixture.agentAlice);

        // The answer that was in flight is dropped: nothing the agent wrote
        // lands on top of the person who is now handling this.
        const { data: written } = await client
          .from("messages")
          .select("agent_id, content")
          .eq("conversation_id", CONV_A2)
          .is("sender_address", null)
          .is("content->internal", null)
          .gte("created_at", since)
          .throwOnError();

        assertEquals(written.length, 1, JSON.stringify(written));
        assertEquals(written[0].agent_id, fixture.agentAlice);
      });
    } finally {
      llm.restore();
      await setEntryAgent(client, null);
      await unassign(client);
      await cleanup(client, since);
    }
  },
});
