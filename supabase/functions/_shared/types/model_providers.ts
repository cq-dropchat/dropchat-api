// T2 — the providers this platform can call, and how each one is reached.
//
// This was a `switch` on a string in three files that did not agree: the two
// protocol handlers each carried their own (Responses knew two providers of
// the four) and the agent form carried a third copy of the default models. A
// tier that resolves through any of them would have been a fourth.
//
// So the relation lives here once, and it is mirrored into the UI
// (scripts/check-type-sync.sh) rather than retyped: the form offers what the
// API can actually call.
//
// What is NOT here is the choice — which model each tier uses. That is
// `public.model_tiers`, a table, because it changes when a provider retires a
// model and that should not need a deploy. What lives in code is what cannot
// be changed without one anyway: reaching a new provider needs its secret in
// the function's environment.
//
// No imports, no dependencies: the UI takes this file verbatim.

export type ModelProvider = "openai" | "anthropic" | "google" | "groq";

export type AgentProtocol = "chat_completions" | "responses";

export type ProviderConfig = {
  /**
   * Absent for OpenAI, and that absence is load-bearing: the client uses its
   * own default base URL, and reads `OPENAI_API_KEY` from the environment by
   * itself.
   */
  base_url?: string;
  /** The name of the environment variable holding the key. Never the key. */
  api_key_env?: string;
  /**
   * Which protocols this provider actually answers. Google's OpenAI-compat
   * layer 404s on `/responses`, and Anthropic speaks its own Messages API, so
   * for those two it is `chat_completions` alone.
   */
  protocols: AgentProtocol[];
  /** What it is called when the agent names no model of its own. */
  default_model: string;
};

export const PROVIDERS: Record<ModelProvider, ProviderConfig> = {
  openai: {
    protocols: ["chat_completions", "responses"],
    default_model: "gpt-5-mini",
  },
  anthropic: {
    base_url: "https://api.anthropic.com/v1",
    api_key_env: "ANTHROPIC_API_KEY",
    protocols: ["chat_completions"],
    default_model: "claude-sonnet-4-6",
  },
  google: {
    base_url: "https://generativelanguage.googleapis.com/v1beta/openai",
    api_key_env: "GOOGLE_API_KEY",
    protocols: ["chat_completions"],
    default_model: "gemini-3-flash-preview",
  },
  groq: {
    base_url: "https://api.groq.com/openai/v1",
    api_key_env: "GROQ_API_KEY",
    protocols: ["chat_completions", "responses"],
    default_model: "openai/gpt-oss-20b",
  },
};

export function isModelProvider(value: string): value is ModelProvider {
  return Object.hasOwn(PROVIDERS, value);
}
