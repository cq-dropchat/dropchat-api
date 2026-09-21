// H2 (step 1) — CHARACTERIZATION of the history each protocol builds.
//
// Recorded BEFORE the change, so the snapshot shows what the model reads
// today, bug included: a message a HUMAN of the organization sent by hand
// arrives as `user` — indistinguishable from what the contact wrote — because
// the role is decided by `row.agent_id === agent.id`, which means "did THIS
// agent write it", not "did we write it".
//
// The consequence is not cosmetic. After a person steps in ("ya te hago el
// cambio, dame el número de pedido"), the agent re-reads that sentence as the
// customer's own words and answers it as if the customer had asked for the
// change — or contradicts a promise the company already made.
//
// Pure: no database, no network.
import { assertEquals } from "jsr:@std/assert@1";
import { assertSnapshot } from "jsr:@std/testing@1/snapshot";
import type { SupabaseClient } from "@supabase/supabase-js";
import type {
  ConversationRow,
  MessageRow,
  OrganizationRow,
} from "../../_shared/supabase.ts";
import type { AgentRowWithExtra, RequestContext } from "./base.ts";
import { ChatCompletionsHandler } from "./chat-completions.ts";
import { ResponsesHandler } from "./responses.ts";

const AI = "aaaaaaaa-0000-4000-8000-0000000000a1";
const HUMAN = "aaaaaaaa-0000-4000-8000-0000000000h1";
const CONTACT = "56912345678";

const agent = {
  id: AI,
  organization_id: "org-a",
  name: "Sofía",
  user_id: null,
  deleted_at: null,
  extra: {
    mode: "active",
    instructions: "Eres Sofía, la asistente de la tienda.",
    multi_message_response: false,
  },
} as unknown as AgentRowWithExtra;

function message(
  id: string,
  text: string,
  by: { agent_id?: string; sender_address?: string },
): MessageRow {
  return {
    id,
    organization_id: "org-a",
    conversation_id: "conv-1",
    agent_id: by.agent_id ?? null,
    sender_address: by.sender_address ?? null,
    external_id: null,
    content: { version: "1", type: "text", kind: "text", text },
    created_at: "2026-09-19T12:00:00.000Z",
    timestamp: "2026-09-19T12:00:00.000Z",
  } as unknown as MessageRow;
}

/**
 * The shape this is about: the contact asks, the AI answers, a HUMAN of the
 * organization steps in by hand, and the contact replies to the human.
 */
const HISTORY: MessageRow[] = [
  message("m1", "hola, quiero cambiar mi pedido", { sender_address: CONTACT }),
  message("m2", "¡Hola! ¿Qué pedido sería?", { agent_id: AI }),
  message("m3", "Soy Carla del equipo, ya te lo cambio: es el 4021", {
    agent_id: HUMAN,
  }),
  message("m4", "gracias Carla", { sender_address: CONTACT }),
];

function context(
  service: ConversationRow["service"],
  messages = HISTORY,
): RequestContext {
  return {
    organization: {
      id: "org-a",
      name: "Tienda Ejemplo",
      extra: null,
    } as unknown as OrganizationRow,
    conversation: {
      id: "conv-1",
      organization_id: "org-a",
      service,
      organization_address: "56911110000",
      address: service === "local" ? `${AI}:${HUMAN}` : CONTACT,
      type: "direct",
    } as unknown as ConversationRow,
    messages,
    contact: { name: "Pedro" },
    agent,
  };
}

/** prepareRequest touches no client for a text-only history. */
const noClient = null as unknown as SupabaseClient;

/** The parts that depend on the run (the clock) are not the subject here. */
function stable(value: unknown): unknown {
  if (typeof value === "string") {
    return value.replace(
      /(\w+day), \d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC/,
      "<now>",
    );
  }
  if (Array.isArray(value)) return value.map(stable);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([k, v]) => [k, stable(v)]),
    );
  }
  return value;
}

Deno.test("H2 characterization: chat completions, external conversation", async (t) => {
  const request = await new ChatCompletionsHandler(
    [],
    context("whatsapp"),
    noClient,
  ).prepareRequest();

  await assertSnapshot(t, stable(request));
});

Deno.test("H2 characterization: responses, external conversation", async (t) => {
  const request = await new ResponsesHandler([], context("whatsapp"), noClient)
    .prepareRequest();

  await assertSnapshot(t, stable(request));
});

Deno.test("H2 characterization: chat completions, local DM", async (t) => {
  // In a DM the peer IS a colleague, so the current rule is the right one
  // there and must not move: everything the AI did not write is `user`.
  const request = await new ChatCompletionsHandler(
    [],
    context("local", [
      message("l1", "probá contestar esto", { agent_id: HUMAN }),
      message("l2", "listo", { agent_id: AI }),
    ]),
    noClient,
  ).prepareRequest();

  await assertSnapshot(t, stable(request));
});

// ---------------------------------------------------------------------------
// H2 — the rule itself, stated as cases rather than as a snapshot.
// ---------------------------------------------------------------------------

function roles(request: { messages: { role: string; content?: unknown }[] }) {
  return request.messages
    .filter((m) => m.role !== "system")
    .map((m) => [m.role, m.content]);
}

Deno.test("H2: on an external service, what the company said is assistant — whoever typed it", async () => {
  const chat = await new ChatCompletionsHandler(
    [],
    context("whatsapp"),
    noClient,
  )
    .prepareRequest();

  assertEquals(roles(chat), [
    ["user", "hola, quiero cambiar mi pedido"],
    ["assistant", "¡Hola! ¿Qué pedido sería?"],
    ["assistant", "Soy Carla del equipo, ya te lo cambio: es el 4021"],
    ["user", "gracias Carla"],
  ]);

  const responses = await new ResponsesHandler(
    [],
    context("whatsapp"),
    noClient,
  )
    .prepareRequest();

  assertEquals(
    responses.input.map((i) => [
      (i as { role?: string }).role,
      (i as { content?: unknown }).content,
    ]),
    [
      ["user", "hola, quiero cambiar mi pedido"],
      ["assistant", "¡Hola! ¿Qué pedido sería?"],
      ["assistant", "Soy Carla del equipo, ya te lo cambio: es el 4021"],
      ["user", "gracias Carla"],
    ],
  );
});

Deno.test("H2: in a local DM the rule does not move — the peer is a colleague", async () => {
  const chat = await new ChatCompletionsHandler(
    [],
    context("local", [
      message("l1", "probá contestar esto", { agent_id: HUMAN }),
      message("l2", "listo", { agent_id: AI }),
    ]),
    noClient,
  ).prepareRequest();

  assertEquals(roles(chat), [
    ["user", "probá contestar esto"],
    ["assistant", "listo"],
  ]);
});

Deno.test("H2: the agent's own error notes stay assistant", async () => {
  // Record-only rows the agent wrote about itself. They were `assistant`
  // before H2 (same agent id) and must stay there: the new rule reads
  // authorship of the SPACE, and these are ours.
  const errorRow = {
    ...message("e1", "No pude consultar el stock.", { agent_id: AI }),
    content: {
      version: "1",
      type: "text",
      kind: "text",
      internal: true,
      text: "No pude consultar el stock.",
    },
  } as unknown as MessageRow;

  const chat = await new ChatCompletionsHandler(
    [],
    context("whatsapp", [HISTORY[0], errorRow]),
    noClient,
  ).prepareRequest();

  assertEquals(roles(chat), [
    ["user", "hola, quiero cambiar mi pedido"],
    ["assistant", "No pude consultar el stock."],
  ]);
});

// ---------------------------------------------------------------------------
// H2 — brand voice, and the order of the system prompt.
//
// Fixed for the whole spec: brand voice → business profile (T1) → the agent's
// own instructions → guardrails (T6) → runtime context. The two middle blocks
// do not exist yet; the order does, so nothing has to move when they arrive.
// ---------------------------------------------------------------------------

function withBrandVoice(service: ConversationRow["service"] = "whatsapp") {
  const ctx = context(service);
  ctx.organization = {
    ...ctx.organization,
    extra: { brand_voice: "Tutea al cliente. Firma como «el equipo»." },
  } as unknown as OrganizationRow;
  return ctx;
}

Deno.test("H2: the brand voice leads the system prompt, the agent's instructions follow", async (t) => {
  const chat = await new ChatCompletionsHandler([], withBrandVoice(), noClient)
    .prepareRequest();

  const system = chat.messages[0] as { role: string; content: string };

  assertEquals(system.role, "system");
  await assertSnapshot(t, stable(system.content));

  const responses = await new ResponsesHandler([], withBrandVoice(), noClient)
    .prepareRequest();

  // Both protocols say the same thing; Responses carries it in `instructions`.
  assertEquals(stable(responses.instructions), stable(system.content));
});

Deno.test("H2: an organization with no brand voice keeps the prompt it had", async (t) => {
  const chat = await new ChatCompletionsHandler(
    [],
    context("whatsapp"),
    noClient,
  )
    .prepareRequest();

  await assertSnapshot(
    t,
    stable((chat.messages[0] as { content: string }).content),
  );
});

// ---------------------------------------------------------------------------
// T1 — the business profile, in slot 2.
//
// The order H2 fixed says it goes after the brand voice and BEFORE the agent's
// own instructions, and that is not a detail of taste: the agent's block is
// what a template will write (T6), and it has to be able to say "offer what
// the business sells" over a profile that is already on the page.
// ---------------------------------------------------------------------------

function withProfile(brandVoice: boolean) {
  const ctx = context("whatsapp");
  ctx.organization = {
    ...ctx.organization,
    extra: {
      ...(brandVoice
        ? { brand_voice: "Tutea al cliente. Firma como «el equipo»." }
        : {}),
      business_profile: {
        industry: "Zapatillas urbanas",
        sells: "Zapatillas de calle y running, tallas 35 a 45.",
        shipping_coverage: "Todo Chile continental.",
        shipping_times: "24 a 48 horas en RM, 3 a 5 días hábiles en regiones.",
        payment_methods: ["Webpay", "Transferencia"],
        returns_policy: "Cambio por talla dentro de 30 días con boleta.",
        currency: "CLP",
      },
    },
  } as unknown as OrganizationRow;
  return ctx;
}

Deno.test("T1: the business profile sits between the brand voice and the instructions", async (t) => {
  const chat = await new ChatCompletionsHandler([], withProfile(true), noClient)
    .prepareRequest();

  const system = (chat.messages[0] as { content: string }).content;

  // The positions, asserted as positions and not only as a snapshot: a
  // snapshot records what happened, this records what may not stop happening.
  const voice = system.indexOf("Tutea al cliente");
  const profile = system.indexOf("Perfil del negocio:");
  const instructions = system.indexOf("Eres Sofía");

  assertEquals(voice < profile && profile < instructions, true, system);

  await assertSnapshot(t, stable(system));

  const responses = await new ResponsesHandler([], withProfile(true), noClient)
    .prepareRequest();

  assertEquals(stable(responses.instructions), stable(system));
});

Deno.test("T1: an organization with a profile and no brand voice still leads with the profile", async (t) => {
  const chat = await new ChatCompletionsHandler(
    [],
    withProfile(false),
    noClient,
  ).prepareRequest();

  await assertSnapshot(
    t,
    stable((chat.messages[0] as { content: string }).content),
  );
});
