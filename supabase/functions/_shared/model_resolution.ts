// T2 — which endpoint, which key and which model a call actually uses.
//
// One function, because it used to be two switches that had drifted (see
// `model_resolution.parity.test.ts`, which pins what they answered before this
// existed). Behaviour is unchanged on purpose: every oddity of the old
// switches is reproduced here, including the one that reads like a bug and is
// — under the Responses protocol, `api_url: "anthropic"` is not Anthropic, it
// is a base URL of "anthropic" and a provider of "custom".
import {
  type AgentProtocol,
  isModelProvider,
  PROVIDERS,
} from "./types/model_providers.ts";
import type { AIAgentExtra } from "./types/extra_types.ts";
import type { ModelTierRow } from "./types/database_types.ts";
import type { SupabaseClient } from "@supabase/supabase-js";
import * as log from "./logger.ts";

export type ResolvedModel = {
  /** The key against `billing.costs`, with `custom` for anything else. */
  provider: string;
  baseURL: string | undefined;
  apiKey: string | undefined;
  /** Never empty: every branch has a default, which is what the clients need. */
  model: string;
};

/** The path each protocol's client appends on its own. */
const APPENDED_PATH: Record<AgentProtocol, string> = {
  chat_completions: "/chat/completions",
  responses: "/responses",
};

/**
 * The tier an agent named, or null — including when it named one that is not
 * there any more.
 *
 * A slug that no longer resolves is not an error the agent can do anything
 * about, and refusing to answer would turn one deleted row into every
 * conversation of every organization that used it. It falls back to the
 * agent's own fields and says so, once per call, in the log.
 */
export async function loadModelTier(
  client: SupabaseClient,
  slug: string | null | undefined,
): Promise<ModelTierRow | null> {
  if (!slug) return null;

  const { data } = await client
    .from("model_tiers")
    .select("*")
    .eq("slug", slug)
    .maybeSingle()
    .throwOnError();

  if (!data) {
    log.warn(`Unknown model tier "${slug}"; falling back to the agent's own.`);
  }

  return data as ModelTierRow | null;
}

/**
 * Which handler answers. Decided from the tier when there is one, because the
 * handler is chosen before the request is built: an agent on a Responses tier
 * given the Chat Completions handler would resolve its own tier against the
 * wrong protocol and fall through to gpt-5-mini.
 */
export function resolveProtocol(
  extra: AIAgentExtra,
  tier: ModelTierRow | null | undefined,
): AgentProtocol {
  const protocol = tier?.protocol ?? extra.protocol ?? "chat_completions";

  return protocol === "responses" ? "responses" : "chat_completions";
}

/**
 * Whether this turn may be answered by forcing the synthetic `respond` tool —
 * which is how one turn becomes several messages.
 *
 * The tier can only take the option away, never give it: a model that rejects
 * `tool_choice: "required"` fails the call outright, so that is not a
 * preference to be overridden by an agent's setting.
 */
export function forcedToolsAllowed(
  extra: AIAgentExtra,
  tier: ModelTierRow | null | undefined,
): boolean {
  if (tier && !tier.supports_forced_tools) return false;

  return extra.multi_message_response ?? true;
}

export function resolveModel(
  extra: AIAgentExtra,
  protocol: AgentProtocol,
  tier?: ModelTierRow | null,
): ResolvedModel {
  // T2: a tier wins over `api_url`, `model` and `protocol`. That is the whole
  // trade — those three stop being the agent's to spell out, and in exchange
  // retiring a model is one UPDATE instead of one write per agent.
  //
  // It is followed only if this code can actually reach that provider on this
  // protocol. The table refuses the impossible combinations
  // (`model_tiers_protocol_supported`), so arriving here with one means a row
  // was written around the CHECK — and the safe answer is the fallback below,
  // not a call to a base URL named after a company.
  if (
    tier &&
    isModelProvider(tier.provider) &&
    PROVIDERS[tier.provider].protocols.includes(protocol)
  ) {
    const config = PROVIDERS[tier.provider];

    return {
      provider: tier.provider,
      baseURL: config.base_url,
      apiKey: extra.api_key ||
        (config.api_key_env ? Deno.env.get(config.api_key_env) : undefined),
      model: tier.model,
    };
  }

  const requested = extra.api_url;

  // A provider this platform knows, that speaks this protocol. OpenAI is
  // deliberately not in this branch: it is reached by giving the client no
  // base URL at all, which is the fall-through below.
  if (
    requested &&
    requested !== "openai" &&
    isModelProvider(requested) &&
    PROVIDERS[requested].protocols.includes(protocol)
  ) {
    const config = PROVIDERS[requested];

    return {
      provider: requested,
      baseURL: config.base_url,
      // The organization's own key wins, and using one is also what makes the
      // call unbillable (`billable = !agent.extra.api_key`).
      apiKey: extra.api_key || Deno.env.get(config.api_key_env ?? ""),
      model: extra.model || config.default_model,
    };
  }

  // Everything else: OpenAI itself, a provider that does not speak this
  // protocol, and any custom endpoint. `api_url` is read as a URL here — which
  // is why a provider name that falls through ends up BEING the base URL.
  const baseURL =
    (requested === "openai"
      ? undefined
      : requested?.replace(APPENDED_PATH[protocol], "")) || undefined;

  return {
    provider: !!baseURL && baseURL !== "openai" ? "custom" : "openai",
    baseURL,
    apiKey: extra.api_key || undefined,
    model: extra.model || PROVIDERS.openai.default_model,
  };
}
