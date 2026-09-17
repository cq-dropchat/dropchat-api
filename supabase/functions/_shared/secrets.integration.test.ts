// F02, end to end against a local Supabase with supabase/tests/fixtures
// loaded (supabase/tests/run.sh): what an API key sees through PostgREST,
// and what the service role gets back through _shared/secrets.ts.
import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import type { Database } from "./types/database_types.ts";
import { env, fixture, supabaseIsUp } from "./testing/env.ts";
import {
  getAddressSecrets,
  revealAddress,
  revealAgent,
  revealOrganization,
  SECRET_MASK,
} from "./secrets.ts";

const up = await supabaseIsUp();

function serviceClient() {
  return createClient<Database>(env.url, env.serviceRoleKey, {
    auth: { persistSession: false },
  });
}

function apiKeyClient(key: string) {
  return createClient<Database>(env.url, env.anonKey, {
    auth: { persistSession: false },
    global: { headers: { "api-key": key } },
  });
}

Deno.test({
  name: "F02: a member API key reads agents.extra with every credential masked",
  ignore: !up,
  // supabase-js keeps its HTTP connections around; not a leak of ours.
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const { data } = await apiKeyClient(fixture.keyAMember)
      .from("agents")
      .select("extra")
      .eq("id", fixture.agentRobotA)
      .single()
      .throwOnError();

    const extra = data.extra as Record<string, unknown>;
    assertEquals(extra.api_key, SECRET_MASK);
    const text = JSON.stringify(extra);
    assert(!text.includes("sk-test-secret-a"));
    assert(!text.includes("P@ss-test-secret"));
    assert(!text.includes("erp-test-secret"));
    assert(!text.includes("mcp-test-secret"));
    // The public facts are still there.
    assertEquals(extra.model, "openai/gpt-oss-20b");
  },
});

Deno.test({
  name:
    "F02: a member API key reads organizations_addresses.extra without the token",
  ignore: !up,
  // supabase-js keeps its HTTP connections around; not a leak of ours.
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const { data } = await apiKeyClient(fixture.keyAMember)
      .from("organizations_addresses")
      .select("extra")
      .eq("organization_id", fixture.orgA)
      .eq("service", "whatsapp")
      .single()
      .throwOnError();

    const extra = data.extra as Record<string, unknown>;
    assertEquals(extra.access_token, SECRET_MASK);
    assertEquals(extra.verified_name, "Alpha Shop");
  },
});

Deno.test({
  name: "F02: an owner API key cannot read public.secrets at all",
  ignore: !up,
  // supabase-js keeps its HTTP connections around; not a leak of ours.
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const { error } = await apiKeyClient(fixture.keyAOwner)
      .from("secrets")
      .select("value");

    assertNotEquals(error, null);
    assertEquals(error?.code, "42501");
  },
});

Deno.test({
  name: "F02: the service role reveals the agent's key and tool credentials",
  ignore: !up,
  // supabase-js keeps its HTTP connections around; not a leak of ours.
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = serviceClient();
    const { data: masked } = await client
      .from("agents")
      .select()
      .eq("id", fixture.agentRobotA)
      .single()
      .throwOnError();

    const agent = await revealAgent(client, masked);
    const extra = agent.extra as {
      api_key: string;
      tools: { type: string; label: string; config: Record<string, unknown> }[];
    };

    assertEquals(extra.api_key, "sk-test-secret-a");
    const sql = extra.tools.find((t) => t.type === "sql")!;
    assertEquals(sql.config.password, "P@ss-test-secret");
    const http = extra.tools.find((t) => t.type === "http")!;
    assertEquals(
      (http.config.headers as Record<string, string>).Authorization,
      "Bearer erp-test-secret",
    );
  },
});

Deno.test({
  name: "F02: the service role reveals account and organization secrets",
  ignore: !up,
  // supabase-js keeps its HTTP connections around; not a leak of ours.
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = serviceClient();

    const secrets = await getAddressSecrets(
      client,
      fixture.orgA,
      "whatsapp",
      fixture.waA,
    );
    assertEquals(secrets?.access_token, "EAAG-test-secret-a");

    const { data: address } = await client
      .from("organizations_addresses")
      .select()
      .eq("organization_id", fixture.orgA)
      .eq("service", "whatsapp")
      .single()
      .throwOnError();
    const revealed = await revealAddress(client, address);
    assertEquals(
      (revealed.extra as Record<string, unknown>).access_token,
      "EAAG-test-secret-a",
    );

    const { data: org } = await client
      .from("organizations")
      .select()
      .eq("id", fixture.orgA)
      .single()
      .throwOnError();
    const revealedOrg = await revealOrganization(client, org);
    assertEquals(
      (revealedOrg.extra as { media_preprocessing: { api_key: string } })
        .media_preprocessing.api_key,
      "AIza-test-secret-a",
    );
  },
});

Deno.test({
  name:
    "F02: a token written through extra is stored in secrets and masked in the row",
  ignore: !up,
  // supabase-js keeps its HTTP connections around; not a leak of ours.
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = serviceClient();
    const probe = `EAAG-probe-${crypto.randomUUID()}`;

    await client
      .from("organizations_addresses")
      .update({ extra: { access_token: probe } })
      .eq("organization_id", fixture.orgB)
      .eq("service", "whatsapp")
      .eq("address", fixture.waB)
      .throwOnError();

    try {
      const { data } = await client
        .from("organizations_addresses")
        .select("extra")
        .eq("organization_id", fixture.orgB)
        .eq("service", "whatsapp")
        .eq("address", fixture.waB)
        .single()
        .throwOnError();
      assertEquals(
        (data.extra as Record<string, unknown>).access_token,
        SECRET_MASK,
      );

      const secrets = await getAddressSecrets(
        client,
        fixture.orgB,
        "whatsapp",
        fixture.waB,
      );
      assertEquals(secrets?.access_token, probe);
    } finally {
      // Restore the fixture value.
      await client
        .from("organizations_addresses")
        .update({ extra: { access_token: "EAAG-test-secret-b" } })
        .eq("organization_id", fixture.orgB)
        .eq("service", "whatsapp")
        .eq("address", fixture.waB)
        .throwOnError();
    }
  },
});
