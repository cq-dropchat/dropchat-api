import "../_shared/testing/env.ts";
import { assert, assertEquals } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import type { Database, MetaWebhookPayload } from "../_shared/supabase.ts";
import { env, fixture, supabaseIsUp } from "../_shared/testing/env.ts";
import { metaRequest } from "../_shared/testing/sign.ts";
import { handler } from "./index.ts";
import { handler as replay } from "../webhook-replay/index.ts";
import { receive } from "./receipts.ts";
const up = await supabaseIsUp();
Deno.test({
  name:
    "C3: post-ACK persistence failure survives and real replay deduplicates",
  ignore: !up,
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const client = createClient<Database>(env.url, env.serviceRoleKey, {
      auth: { persistSession: false },
    });
    const externalId = `wamid.durable.${crypto.randomUUID()}`;
    const payload = {
      object: "whatsapp_business_account",
      entry: [{
        id: fixture.wabaA,
        time: 1757000000,
        changes: [{
          field: "messages",
          value: {
            messaging_product: "whatsapp",
            metadata: {
              phone_number_id: fixture.waA,
              display_phone_number: "test",
            },
            messages: [{
              from: fixture.contactA1,
              id: externalId,
              timestamp: 1757000000,
              type: "text",
              text: { body: "durable replay" },
            }],
          },
        }],
      }],
    } as MetaWebhookPayload;
    const body = JSON.stringify(payload);
    const runtime = globalThis as unknown as {
      EdgeRuntime?: { waitUntil(p: Promise<unknown>): void };
    };
    const savedRuntime = runtime.EdgeRuntime;
    const work: Promise<unknown>[] = [];
    runtime.EdgeRuntime = {
      waitUntil: (p) => {
        work.push(p);
      },
    };
    const originalFetch = globalThis.fetch;
    let inject = true;
    let id: string | undefined;
    globalThis.fetch = (input, init) => {
      const req = input instanceof Request ? input : new Request(input, init);
      if (
        inject && req.url.includes("/rest/v1/messages") && req.method === "POST"
      ) {
        return Promise.resolve(
          Response.json({ code: "injected", message: "injected failure" }, {
            status: 503,
          }),
        );
      }
      return originalFetch(input, init);
    };
    try {
      const response = await handler(
        await metaRequest(
          "http://localhost/whatsapp-webhook",
          payload,
          env.metaAppSecret,
        ),
      );
      assertEquals(response.status, 200);
      await Promise.all(work);
      id = await receive(client, body, payload);
      const failed = await client.from("webhook_receipts").select().eq("id", id)
        .single().throwOnError();
      assertEquals(failed.data.status, "pending");
      assertEquals(failed.data.attempts, 1);
      assertEquals(failed.data.payload, payload);
      inject = false;
      await client.from("webhook_receipts").update({
        next_attempt_at: new Date(0).toISOString(),
      }).eq("id", id).throwOnError();
      const request = () =>
        new Request("http://localhost/webhook-replay", {
          method: "POST",
          headers: { authorization: `Bearer ${env.serviceRoleKey}` },
          body: JSON.stringify({ receipt_id: id }),
        });
      assertEquals((await replay(request())).status, 200);
      assertEquals((await replay(request())).status, 200);
      const complete = await client.from("webhook_receipts").select().eq(
        "id",
        id,
      ).single().throwOnError();
      assertEquals(complete.data.status, "done");
      assertEquals(complete.data.attempts, 2);
      const rows = await client.from("messages").select("id,content").eq(
        "organization_id",
        fixture.orgA,
      ).eq("external_id", externalId).throwOnError();
      assertEquals(rows.data.length, 1);
      assert(
        (rows.data[0].content as { text: string }).text === "durable replay",
      );
      assertEquals(await receive(client, body, payload), id);
    } finally {
      globalThis.fetch = originalFetch;
      runtime.EdgeRuntime = savedRuntime;
      if (id) await client.from("webhook_receipts").delete().eq("id", id);
      await client.from("messages").delete().eq("organization_id", fixture.orgA)
        .eq("external_id", externalId);
    }
  },
});
Deno.test("webhook-replay rejects non-service callers", async () => {
  assertEquals(
    (await replay(
      new Request("http://localhost/webhook-replay", {
        method: "POST",
        body: "{}",
      }),
    )).status,
    401,
  );
});
