// T6 — the layered configuration is resolved twice, so it is checked twice
// against the same cases.
//
// TypeScript answers it on every message (`_shared/agent_templates.ts`): a
// round trip per invocation is not free, and this runs inside the agent's hot
// path. SQL answers it when unlinking freezes the result into `agents.extra`
// (`public.resolve_agent_config`), where TypeScript is not present at all.
//
// Two implementations of one rule drift in silence. This is what makes them
// fail loudly instead — the same arrangement, and the same reason, as
// `attention_parity.test.ts`.
//
// Runs against the local database with no fixture: it calls the resolver with
// literal configurations.
import "../_shared/testing/env.ts";
import { assertEquals } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import { env, supabaseIsUp } from "../_shared/testing/env.ts";
import { resolveAgentConfig } from "../_shared/agent_templates.ts";
import type { AIAgentExtra } from "../_shared/types/extra_types.ts";

const up = await supabaseIsUp();

type Case = { why: string; config: unknown; extra: unknown };

const CASES: Case[] = [
  {
    why: "no template at all, which is every agent in the product today",
    config: null,
    extra: {
      mode: "active",
      instructions: "mías",
      tools: [{
        provider: "local",
        type: "http",
        label: "erp",
        config: { url: "https://erp.interno" },
      }],
    },
  },
  {
    why: "a template nobody has overridden yet",
    config: { instructions: "de la plantilla", model_tier: "equilibrado" },
    extra: { mode: "draft" },
  },
  {
    why: "the layer overriding one field and inheriting the rest",
    config: { instructions: "de la plantilla", model_tier: "equilibrado" },
    extra: { instructions: "mías" },
  },
  {
    why: "a mask the template carried",
    config: { api_key: "********", instructions: "de la plantilla" },
    extra: {},
  },
  {
    why: "guardrails the layer tries to unlock",
    config: { guardrails: "No prometas fechas" },
    extra: { guardrails: "Prometé lo que sea" },
  },
  {
    why: "guardrails of an agent with no template",
    config: null,
    extra: { guardrails: "las mías" },
  },
  {
    why: "a published tool with nowhere to connect",
    config: { tools: [{ provider: "local", type: "sql", label: "pedidos" }] },
    extra: {},
  },
  {
    why: "the same tool, connected by the organization",
    config: { tools: [{ provider: "local", type: "sql", label: "pedidos" }] },
    extra: {
      tools: [{
        provider: "local",
        type: "sql",
        label: "pedidos",
        config: { driver: "postgres", host: "db.tienda" },
      }],
    },
  },
  {
    why: "a tool the organization added on its own",
    config: {
      tools: [{ provider: "local", type: "function", name: "calculator" }],
    },
    extra: {
      tools: [{
        provider: "local",
        type: "http",
        label: "erp",
        config: { url: "https://erp" },
      }],
    },
  },
  {
    why: "a renamed tool, which loses its connection like it loses its secrets",
    config: { tools: [{ provider: "local", type: "sql", label: "pedidos" }] },
    extra: {
      tools: [{
        provider: "local",
        type: "sql",
        label: "ordenes",
        config: { driver: "postgres" },
      }],
    },
  },
  {
    why: "an empty config object, which is not a connection",
    config: {
      tools: [{ provider: "local", type: "mcp", label: "calendario" }],
    },
    extra: {
      tools: [{
        provider: "local",
        type: "mcp",
        label: "calendario",
        config: {},
      }],
    },
  },
  {
    why: "neither side mentioning tools, so neither does the answer",
    config: { instructions: "sin herramientas" },
    extra: {},
  },
];

function service() {
  return createClient(env.url, env.serviceRoleKey, {
    auth: { persistSession: false },
  });
}

Deno.test({
  name: "T6: SQL and TypeScript resolve the two layers the same way",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();

    for (const testCase of CASES) {
      const sql = await client
        .rpc("resolve_agent_config", {
          _config: testCase.config,
          _extra: testCase.extra,
        })
        .throwOnError();

      assertEquals(
        resolveAgentConfig(
          testCase.config as AIAgentExtra,
          testCase.extra as AIAgentExtra,
        ),
        sql.data as unknown as AIAgentExtra,
        testCase.why,
      );
    }
  },
});
