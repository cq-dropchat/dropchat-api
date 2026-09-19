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
