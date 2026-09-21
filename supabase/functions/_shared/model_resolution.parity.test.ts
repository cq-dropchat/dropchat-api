// T2 (step 1) — CHARACTERIZATION of how an agent's provider and model are
// resolved, before anything moves.
//
// The relation provider→(base URL, env var, default model) lives as a `switch`
// on a string in TWO files, and they are not the same switch:
// chat-completions knows groq, anthropic, google and openai; responses knows
// only groq and openai. So `api_url: "anthropic"` under the Responses protocol
// does NOT reach Anthropic — it falls through to the default branch, where
// "anthropic" is treated as a base URL, the provider becomes "custom" and the
// model becomes gpt-5-mini. That is today's behaviour, bug and all, and this
// file is what says so out loud.
//
// The two functions below are those switches COPIED VERBATIM from
// protocols/chat-completions.ts and protocols/responses.ts. They are the
// reference implementation: `resolveModel` has to answer exactly what they
// answer, for every input, or the refactor changed behaviour. Same idea as
// `_traces/attention_parity.test.ts`, and the same reason.
import { assertEquals } from "jsr:@std/assert@1";
import { assertSnapshot } from "jsr:@std/testing@1/snapshot";
import { type ResolvedModel, resolveModel } from "./model_resolution.ts";
import type { AIAgentExtra } from "./types/extra_types.ts";

// Obviously fake, and set here so the comparison is about the NAME of the
// variable each provider reads, not about what a machine happens to have.
Deno.env.set("GROQ_API_KEY", "groq-de-prueba-0000");
Deno.env.set("ANTHROPIC_API_KEY", "anthropic-de-prueba-0000");
Deno.env.set("GOOGLE_API_KEY", "google-de-prueba-0000");

/** protocols/chat-completions.ts, sendRequest, verbatim. */
function chatCompletionsToday(extra: AIAgentExtra): ResolvedModel {
  let provider = extra.api_url;
  let baseURL = extra.api_url;
  let apiKey = extra.api_key;
  let model = extra.model;

  switch (baseURL) {
    case "groq":
      baseURL = "https://api.groq.com/openai/v1";
      apiKey ||= Deno.env.get("GROQ_API_KEY");
      model ||= "openai/gpt-oss-20b";
      break;
    case "anthropic":
      baseURL = "https://api.anthropic.com/v1";
      apiKey ||= Deno.env.get("ANTHROPIC_API_KEY");
      model ||= "claude-sonnet-4-6";
      break;
    case "google":
      baseURL = "https://generativelanguage.googleapis.com/v1beta/openai";
      apiKey ||= Deno.env.get("GOOGLE_API_KEY");
      model ||= "gemini-3-flash-preview";
      break;
    case "openai":
      baseURL = undefined;
      /* falls through */
    default:
      baseURL = baseURL?.replace("/chat/completions", "") || undefined;
      apiKey ||= undefined;
      model ||= "gpt-5-mini";
      provider = !!baseURL && baseURL !== "openai" ? "custom" : "openai";
  }

  return { provider, baseURL, apiKey, model } as ResolvedModel;
}

/** protocols/responses.ts, sendRequest, verbatim. */
function responsesToday(extra: AIAgentExtra): ResolvedModel {
  let provider = extra.api_url;
  let baseURL = extra.api_url;
  let apiKey = extra.api_key;
  let model = extra.model;

  switch (baseURL) {
    case "groq":
      baseURL = "https://api.groq.com/openai/v1";
      apiKey ||= Deno.env.get("GROQ_API_KEY");
      model ||= "openai/gpt-oss-20b";
      break;
    case "openai":
      baseURL = undefined;
      /* falls through */
    default:
      baseURL = baseURL?.replace("/responses", "") || undefined;
      apiKey ||= undefined;
      model ||= "gpt-5-mini";
      provider = !!baseURL && baseURL !== "openai" ? "custom" : "openai";
  }

  return { provider, baseURL, apiKey, model } as ResolvedModel;
}

/** Everything an `api_url` can be, including the ones nobody meant. */
const API_URLS = [
  undefined,
  "",
  "groq",
  "anthropic",
  "google",
  "openai",
  "custom",
  "https://interno.ejemplo/v1",
  "https://interno.ejemplo/v1/chat/completions",
  "https://interno.ejemplo/v1/responses",
];

const API_KEYS = [undefined, "clave-propia-de-la-organizacion-0000"];
const MODELS = [undefined, "modelo-elegido-a-mano"];

function cases(): AIAgentExtra[] {
  const all: AIAgentExtra[] = [];
  for (const api_url of API_URLS) {
    for (const api_key of API_KEYS) {
      for (const model of MODELS) {
        all.push({ api_url, api_key, model } as AIAgentExtra);
      }
    }
  }
  return all;
}

Deno.test("T2: the new resolver answers what chat-completions answers today", () => {
  for (const extra of cases()) {
    assertEquals(
      resolveModel(extra, "chat_completions"),
      chatCompletionsToday(extra),
      `chat_completions for ${JSON.stringify(extra)}`,
    );
  }
});

Deno.test("T2: the new resolver answers what responses answers today", () => {
  for (const extra of cases()) {
    assertEquals(
      resolveModel(extra, "responses"),
      responsesToday(extra),
      `responses for ${JSON.stringify(extra)}`,
    );
  }
});

// The record of what that actually is, so the next reader does not have to run
// a switch in their head. Note the two rows that read like bugs and are:
// under Responses, "anthropic" and "google" resolve to a base URL of
// "anthropic" and a provider of "custom".
Deno.test("T2: what every api_url resolves to, both protocols", async (t) => {
  const table = API_URLS.map((api_url) => ({
    api_url,
    chat_completions: resolveModel(
      { api_url } as AIAgentExtra,
      "chat_completions",
    ),
    responses: resolveModel({ api_url } as AIAgentExtra, "responses"),
  }));

  await assertSnapshot(t, table);
});
