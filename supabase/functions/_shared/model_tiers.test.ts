// T2 (step 2) — an agent that names a tier, and what happens when the tier is
// not there.
//
// The tier is the whole point of the item: the day a provider retires a model,
// the repair is one UPDATE on three rows instead of one write per agent in
// every organization. That only holds if the tier WINS over the fields it
// replaces, which is the first case here, and if a missing tier degrades
// instead of breaking, which is the last one.
import { assertEquals } from "jsr:@std/assert@1";
import {
  forcedToolsAllowed,
  resolveModel,
  resolveProtocol,
} from "./model_resolution.ts";
import type { ModelTierRow } from "./types/database_types.ts";
import type { AIAgentExtra } from "./types/extra_types.ts";

Deno.env.set("ANTHROPIC_API_KEY", "anthropic-de-prueba-0000");
Deno.env.set("GROQ_API_KEY", "groq-de-prueba-0000");

const AVANZADO: ModelTierRow = {
  slug: "avanzado",
  name: "Avanzado",
  description: null,
  provider: "anthropic",
  model: "claude-sonnet-5",
  protocol: "chat_completions",
  supports_forced_tools: true,
  sort_order: 3,
  created_at: "2026-09-21T00:00:00.000Z",
  updated_at: "2026-09-21T00:00:00.000Z",
};

Deno.test("T2: a tier beats the fields it replaces", () => {
  // An agent that was configured by hand and later moved onto a tier still
  // carries its old strings. The tier is the one that counts, or the item
  // bought nothing: those strings are exactly what stops being editable.
  const extra = {
    model_tier: "avanzado",
    api_url: "groq",
    model: "openai/gpt-oss-20b",
  } as AIAgentExtra;

  assertEquals(resolveModel(extra, "chat_completions", AVANZADO), {
    provider: "anthropic",
    baseURL: "https://api.anthropic.com/v1",
    apiKey: "anthropic-de-prueba-0000",
    model: "claude-sonnet-5",
  });
});

Deno.test("T2: the organization's own key still wins over the platform's", () => {
  // And it is what makes the call unbillable (`billable = !extra.api_key`), so
  // a tier must not quietly move somebody onto platform credits.
  const extra = {
    model_tier: "avanzado",
    api_key: "clave-propia-de-la-organizacion-0000",
  } as AIAgentExtra;

  assertEquals(
    resolveModel(extra, "chat_completions", AVANZADO).apiKey,
    "clave-propia-de-la-organizacion-0000",
  );
});

Deno.test("T2: a tier that is no longer there does not take the agent down", () => {
  // A platform admin deleted the row, or renamed the slug. The agent falls
  // back to what it had before — answering on the wrong model is bad, not
  // answering at all is worse.
  const extra = { model_tier: "avanzado", api_url: "groq" } as AIAgentExtra;

  assertEquals(resolveModel(extra, "chat_completions", null), {
    provider: "groq",
    baseURL: "https://api.groq.com/openai/v1",
    apiKey: "groq-de-prueba-0000",
    model: "openai/gpt-oss-20b",
  });
});

Deno.test("T2: the protocol comes from the tier when there is one", () => {
  // The handler is chosen before the call is built, so this has to be decided
  // from the same row that decides the model — or an agent on a Responses tier
  // gets the Chat Completions handler and the tier resolves against the wrong
  // protocol.
  const responsesTier = {
    ...AVANZADO,
    provider: "groq",
    protocol: "responses",
  };

  assertEquals(
    resolveProtocol({ model_tier: "x" } as AIAgentExtra, responsesTier),
    "responses",
  );
  // No tier: the agent's own field, and then the default.
  assertEquals(
    resolveProtocol({ protocol: "responses" } as AIAgentExtra, null),
    "responses",
  );
  assertEquals(resolveProtocol({} as AIAgentExtra, null), "chat_completions");
  // A tier the agent named overrides a protocol it also carries.
  assertEquals(
    resolveProtocol(
      { protocol: "responses" } as AIAgentExtra,
      AVANZADO,
    ),
    "chat_completions",
  );
});

Deno.test("T2: a tier that cannot be forced into a tool turns off multi-message", () => {
  // `multi_message_response` defaults ON and hands the model a synthetic
  // `respond` tool with `tool_choice: "required"`. A reasoning-mode model
  // rejects that outright — the call fails, every time, for every message.
  const reasoning = { ...AVANZADO, supports_forced_tools: false };

  assertEquals(forcedToolsAllowed({} as AIAgentExtra, reasoning), false);
  // And the agent's own opt-out still works with a tier that does support it.
  assertEquals(forcedToolsAllowed({} as AIAgentExtra, AVANZADO), true);
  assertEquals(
    forcedToolsAllowed(
      { multi_message_response: false } as AIAgentExtra,
      AVANZADO,
    ),
    false,
  );
  // No tier at all: unchanged from before T2.
  assertEquals(forcedToolsAllowed({} as AIAgentExtra, null), true);
  assertEquals(
    forcedToolsAllowed({ multi_message_response: false } as AIAgentExtra, null),
    false,
  );
});

Deno.test("T2: a tier on a provider that cannot speak the protocol is not followed blindly", () => {
  // The table refuses this combination (`model_tiers_protocol_supported`), so
  // reaching it means somebody wrote the row around the CHECK. The resolver
  // still must not send the call to a base URL named "anthropic": it falls
  // back rather than inventing a provider.
  const impossible = { ...AVANZADO, protocol: "responses" };

  assertEquals(resolveModel({} as AIAgentExtra, "responses", impossible), {
    provider: "openai",
    baseURL: undefined,
    apiKey: undefined,
    model: "gpt-5-mini",
  });
});
