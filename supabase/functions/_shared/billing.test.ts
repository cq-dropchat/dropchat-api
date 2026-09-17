// F17: credit reservation and the idempotent ledger, against a local
// Supabase with supabase/tests/fixtures loaded.
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import type { Database } from "./types/database_types.ts";
import { env, fixture, supabaseIsUp } from "./testing/env.ts";
import {
  estimateInputTokens,
  recordAiConsumption,
  reserveAiCredits,
} from "./billing.ts";

const up = await supabaseIsUp();

function service() {
  return createClient<Database>(env.url, env.serviceRoleKey, {
    auth: { persistSession: false },
  });
}

Deno.test("F17: input tokens are overestimated from the request size", () => {
  assertEquals(estimateInputTokens({ a: "x".repeat(396) }), 101);
  assertEquals(estimateInputTokens(undefined), 1);
});

Deno.test({
  name: "F17: a call the balance cannot cover is refused before it is made",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    // Org B holds the free plan's $1 grant. Claude-Sonnet-like pricing with a
    // 100k-token output budget costs $1.50: refused.
    const costs = { pricing: { input: 3, output: 15 }, quantity: 1_000_000 };

    await assertRejects(
      () => reserveAiCredits(client, fixture.orgB, costs, 1000, 100_000),
      Error,
      "Insufficient balance",
    );

    const estimate = await reserveAiCredits(
      client,
      fixture.orgB,
      costs,
      1000,
      1000,
    );
    assert(Math.abs(estimate - 0.018) < 1e-9, `estimate ${estimate}`);
  },
});

Deno.test({
  name: "F17: the same provider response is charged once",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    const external_id = `chatcmpl-${crypto.randomUUID()}`;
    const entry = {
      organization_id: fixture.orgB,
      provider: "groq",
      model: "openai/gpt-oss-20b",
      external_id,
      cost: 0.0001,
      billable: true,
    };

    try {
      await recordAiConsumption(client, entry);
      await recordAiConsumption(client, entry); // a retried insert

      const { data } = await client
        .schema("billing")
        .from("ledger")
        .select("id")
        .eq("external_id", external_id)
        .throwOnError();
      assertEquals(data.length, 1);
    } finally {
      await client.schema("billing").from("ledger").delete().eq(
        "external_id",
        external_id,
      );
    }
  },
});
