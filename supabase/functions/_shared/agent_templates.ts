// T6 — the effective configuration of an agent installed from a template.
//
// An installed agent is a POINTER plus a layer: `template_id` +
// `template_version` say what it is based on, and `agents.extra` is what this
// organization changed. Nothing of the template is copied into the agent, so
// taking a new version (D7) is one column and not a re-install that would
// discard the organization's edits.
//
// This function exists TWICE, here and as `public.resolve_agent_config`.
// TypeScript answers it on every message — a round trip per invocation is not
// free — and SQL answers it when unlinking freezes the result into `extra`.
// `_traces/agent_config_parity.test.ts` runs both over the same cases, which
// is the same arrangement H4's schedule has and for the same reason.
//
// Three things make this more than `{...config, ...extra}`:
//
//   1. TOOLS ARE A LIST, and `extra` is written as a JSON merge patch, where
//      an array is replaced WHOLE (§3.6). A layer that had to restate every
//      tool in order to connect one would also silently drop any tool a new
//      version added. They are merged by IDENTITY instead — `type:label`, the
//      same key `extract_secrets` files a tool's credentials under.
//   2. A MASK IS NOT A VALUE. `agent_template_config` keeps the source agent's
//      `api_key` as '********' to say "this template expects one", and T4
//      assumed install would write it through `extract_secrets`, which drops a
//      mask with nothing behind it. A layered install never writes the
//      template's config anywhere, so that never happens: the mask would reach
//      the provider AS the key. It is dropped here.
//   3. GUARDRAILS ARE THE TEMPLATE'S — slot 4 of the system prompt exists so a
//      template can state what its agent must not do, and an override would
//      make that a suggestion.
import type { SupabaseClient } from "@supabase/supabase-js";
import * as log from "./logger.ts";
import { SECRET_MASK } from "./secrets.ts";
import type { AIAgentExtra, ToolConfig } from "./types/extra_types.ts";

/** Tool types whose `config` is a connection, and which D13 does not publish. */
const NEEDS_CONNECTION = ["mcp", "sql", "http"];

type LooseTool = ToolConfig & {
  label?: string;
  name?: string;
  config?: Record<string, unknown>;
};

/** A tool's identity: its type and the name it is filed under. */
export function agentToolKey(tool: LooseTool): string {
  return `${tool.type ?? "?"}:${tool.label ?? tool.name ?? ""}`;
}

/**
 * Whether a tool can actually be called. A template declares its tools without
 * their connection (D13), so a freshly installed one has nowhere to go — and
 * handing that to the model produces a tool call that fails in front of a
 * customer.
 */
export function agentToolReady(tool: LooseTool): boolean {
  if (!NEEDS_CONNECTION.includes(tool.type)) return true;

  const config = tool.config;

  return !!config && typeof config === "object" && !Array.isArray(config) &&
    Object.keys(config).length > 0;
}

function mergeTool(base: LooseTool, over: LooseTool): LooseTool {
  const merged = { ...base, ...over } as LooseTool;

  if ("config" in base || "config" in over) {
    merged.config = { ...base.config, ...over.config };
  }

  return merged;
}

/**
 * With no template this is the IDENTITY on `extra`, and it has to be: every
 * agent in the product is that case today.
 */
export function resolveAgentConfig(
  config: AIAgentExtra | null | undefined,
  extra: AIAgentExtra | null | undefined,
): AIAgentExtra {
  const over = (extra ?? {}) as Record<string, unknown>;
  const base = Object.fromEntries(
    Object.entries((config ?? {}) as Record<string, unknown>).filter(
      ([, value]) => value !== SECRET_MASK,
    ),
  );

  const { tools: baseTools, ...baseRest } = base;
  const { tools: overTools, ...overRest } = over;

  const resolved: Record<string, unknown> = { ...baseRest, ...overRest };

  if ("guardrails" in base) {
    resolved.guardrails = base.guardrails;
  }

  const published = Array.isArray(baseTools) ? baseTools as LooseTool[] : [];
  const own = Array.isArray(overTools) ? overTools as LooseTool[] : [];

  const tools: LooseTool[] = [];

  for (const tool of published) {
    const override = own.find((o) => agentToolKey(o) === agentToolKey(tool));
    const merged = override ? mergeTool(tool, override) : tool;

    if (agentToolReady(merged)) tools.push(merged);
  }

  // The organization's own, which the template knows nothing about. NOT
  // filtered by readiness: that is exactly what an agent without a template
  // carries today, and this does not change it.
  for (const tool of own) {
    const key = agentToolKey(tool);

    if (!published.some((t) => agentToolKey(t) === key)) tools.push(tool);
  }

  if ("tools" in base || "tools" in over) {
    resolved.tools = tools;
  }

  return resolved as AIAgentExtra;
}

/**
 * The agent as it actually runs: its version's configuration underneath, its
 * own `extra` on top. A no-op for an agent with no template.
 *
 * Called with the service-role client, which matters for one case: the policy
 * that lets a tenant read versions hides RETIRED ones, and an agent on a
 * retired version has to keep answering (retiring pulls a version from the
 * catalogue, it does not reach into the organizations already on it).
 *
 * A version that is not there at all — a template row deleted for real — does
 * not stop the agent: the composite foreign key nulls the pointer in that
 * case, so this is defence for the window rather than a path anybody expects.
 */
export async function applyAgentTemplate<
  T extends {
    extra: unknown;
    template_id: string | null;
    template_version: number | null;
  },
>(client: SupabaseClient, agent: T): Promise<T> {
  if (!agent.template_id || agent.template_version === null) return agent;

  const { data } = await client
    .from("agent_template_versions")
    .select("config")
    .eq("template_id", agent.template_id)
    .eq("version", agent.template_version)
    .maybeSingle()
    .throwOnError();

  if (!data) {
    log.warn(
      `Agent template version ${agent.template_id}/${agent.template_version} is gone; running on the agent's own configuration.`,
    );
    return agent;
  }

  return {
    ...agent,
    extra: resolveAgentConfig(
      data.config as AIAgentExtra,
      agent.extra as AIAgentExtra,
    ),
  } as T;
}
