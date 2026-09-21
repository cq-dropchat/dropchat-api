// T6 — what an installed agent actually runs on, as the four cases the item
// asks for: no overrides, an overridden instruction, an overridden tool, and a
// version that was retired.
//
// Pure: no database, no network. The twin in SQL is checked against this one
// in `_traces/agent_config_parity.test.ts`.
import { assertEquals } from "jsr:@std/assert@1";
import { assertSnapshot } from "jsr:@std/testing@1/snapshot";
import { agentToolKey, resolveAgentConfig } from "./agent_templates.ts";
import type { AIAgentExtra } from "./types/extra_types.ts";

/** What `publish_agent_template_version` writes: tools without connections. */
const PUBLISHED = {
  mode: "active",
  instructions: "Atendé pedidos contra entrega. Confirmá la dirección.",
  model_tier: "equilibrado",
  guardrails: "No prometas fechas de entrega que no estén en el perfil.",
  tools: [
    { provider: "local", type: "function", name: "calculator" },
    { provider: "local", type: "sql", label: "pedidos" },
  ],
} as unknown as AIAgentExtra;

Deno.test("T6: installed and not touched", async (t) => {
  // The tool with no connection is missing on purpose: D13 does not publish
  // configs, so this agent cannot query the shop's orders until somebody says
  // where they are.
  await assertSnapshot(
    t,
    resolveAgentConfig(PUBLISHED, { mode: "draft" } as AIAgentExtra),
  );
});

Deno.test("T6: the organization rewrote the instructions", async (t) => {
  await assertSnapshot(
    t,
    resolveAgentConfig(
      PUBLISHED,
      {
        mode: "active",
        instructions: "Atendé en tono formal. Cobramos contra entrega.",
      } as AIAgentExtra,
    ),
  );
});

Deno.test("T6: the organization connected the tool", async (t) => {
  await assertSnapshot(
    t,
    resolveAgentConfig(
      PUBLISHED,
      {
        mode: "active",
        tools: [
          {
            provider: "local",
            type: "sql",
            label: "pedidos",
            config: { driver: "postgres", host: "db.tienda" },
          },
          {
            provider: "local",
            type: "http",
            label: "erp",
            config: { url: "https://erp.tienda" },
          },
        ],
      } as unknown as AIAgentExtra,
    ),
  );
});

Deno.test("T6: a retired version runs exactly as it did", async (t) => {
  // Retiring pulls a version from the catalogue; it does not reach into the
  // organizations already on it. There is nothing in the resolution that
  // knows about `retired_at`, and that is the assertion: an agent does not
  // change behaviour because somebody stopped offering its version.
  const retired = { ...PUBLISHED, instructions: "Versión retirada" };
  const layer = { mode: "active" } as AIAgentExtra;

  assertEquals(
    resolveAgentConfig(retired as AIAgentExtra, layer),
    resolveAgentConfig(
      { ...retired, instructions: "Versión retirada" } as AIAgentExtra,
      layer,
    ),
  );

  await assertSnapshot(t, resolveAgentConfig(retired as AIAgentExtra, layer));
});

// ---------------------------------------------------------------------------
// The identity case, which is what every agent in the product is today.
// ---------------------------------------------------------------------------

Deno.test("T6: an agent with no template is its own configuration", () => {
  const extra = {
    mode: "active",
    instructions: "mías",
    temperature: 0.4,
    tools: [
      {
        provider: "local",
        type: "http",
        label: "erp",
        config: { url: "https://erp.interno" },
      },
      // Not ready, and kept anyway: the readiness rule is about what a
      // TEMPLATE published, not about what an organization wrote itself.
      { provider: "local", type: "sql", label: "sin-conexion" },
    ],
  } as unknown as AIAgentExtra;

  assertEquals(resolveAgentConfig(null, extra), extra);
  assertEquals(resolveAgentConfig(undefined, extra), extra);
});

Deno.test("T6: a mask never becomes a credential", () => {
  // `agent_template_config` publishes the source agent's `api_key` as
  // '********' to say the template expects one. T4 assumed install would write
  // it through extract_secrets, which drops a mask with nothing behind it —
  // but a layered install writes none of the template anywhere, so nothing
  // ever strips it. Left alone it would be sent to the provider AS the key,
  // and `billable = !extra.api_key` would stop reserving credits.
  const resolved = resolveAgentConfig(
    { api_key: "********", instructions: "de la plantilla" } as AIAgentExtra,
    {} as AIAgentExtra,
  );

  assertEquals("api_key" in resolved, false);
  assertEquals(resolved.instructions, "de la plantilla");

  // The organization's own key is not a mask and is not touched.
  assertEquals(
    resolveAgentConfig(
      { api_key: "********" } as AIAgentExtra,
      { api_key: "la-clave-de-la-organizacion-0000" } as AIAgentExtra,
    ).api_key,
    "la-clave-de-la-organizacion-0000",
  );
});

Deno.test("T6: a tool is identified the way its secrets are filed", () => {
  // `extract_secrets` indexes an agent's tool credentials by `type:label`, so
  // using anything else here would mean a tool could keep its connection while
  // losing its secrets, or the other way round.
  assertEquals(
    agentToolKey({ type: "sql", label: "pedidos" } as never),
    "sql:pedidos",
  );
  assertEquals(
    agentToolKey({ type: "function", name: "calculator" } as never),
    "function:calculator",
  );
});
