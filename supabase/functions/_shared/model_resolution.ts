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

export function resolveModel(
  extra: AIAgentExtra,
  protocol: AgentProtocol,
): ResolvedModel {
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
