// Test doubles for agent-client: a counted LLM stub and a tool-less AI
// agent standing in for the fixture's Robot A, whose tools point at hosts
// that do not resolve. Obviously fake keys only.
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../types/database_types.ts";
import { fixture } from "./env.ts";

type Client = SupabaseClient<Database>;

/** The test agent talks to Groq; count those calls and answer with text. */
export function stubLlm(latencyMs = 200) {
  const realFetch = globalThis.fetch;
  let calls = 0;
  let active = 0;
  let maxActive = 0;
  const bodies: string[] = [];
  globalThis.fetch = async (input, init) => {
    const url = input instanceof Request ? input.url : String(input);
    if (url.startsWith("https://api.groq.com/")) {
      calls++;
      active++;
      maxActive = Math.max(maxActive, active);
      bodies.push(
        input instanceof Request
          ? await input.clone().text()
          : String(init?.body),
      );
      await new Promise((r) => setTimeout(r, latencyMs));
      active--;
      return Response.json({
        id: `chatcmpl-test-${crypto.randomUUID()}`,
        object: "chat.completion",
        created: Math.floor(Date.now() / 1000),
        model: "openai/gpt-oss-20b",
        choices: [{
          index: 0,
          message: { role: "assistant", content: "respuesta de prueba" },
          finish_reason: "stop",
        }],
        usage: { prompt_tokens: 10, completion_tokens: 3, total_tokens: 13 },
      });
    }
    return realFetch(input, init);
  };
  return {
    calls: () => calls,
    maxActive: () => maxActive,
    bodies,
    restore: () => (globalThis.fetch = realFetch),
  };
}

/**
 * Robot A's fixture tools point at hosts that do not resolve. Park it and
 * answer with a tool-less AI agent for the test's duration.
 */
export async function withTestAgent(
  client: Client,
  fn: (agentId: string) => Promise<void>,
) {
  const { data: robot } = await client
    .from("agents")
    .select("extra")
    .eq("id", fixture.agentRobotA)
    .single()
    .throwOnError();
  // deno-lint-ignore no-explicit-any
  const extra = robot.extra as any;

  await client
    .from("agents")
    .update({ extra: { ...extra, mode: "inactive" } })
    .eq("id", fixture.agentRobotA)
    .throwOnError();

  const { data: agent } = await client
    .from("agents")
    .insert({
      organization_id: fixture.orgA,
      name: "Robot F16",
      extra: {
        mode: "active",
        protocol: "chat_completions",
        api_url: "https://api.groq.com/openai/v1",
        api_key: "sk-test-f16-not-a-key",
        model: "openai/gpt-oss-20b",
        instructions: "You are a test robot.",
        response_delay_seconds: 0,
      },
    })
    .select("id")
    .single()
    .throwOnError();

  try {
    await fn(agent.id);
  } finally {
    await client.from("agents").delete().eq("id", agent.id);
    await client
      .from("agents")
      .update({ extra })
      .eq("id", fixture.agentRobotA)
      .throwOnError();
  }
}
