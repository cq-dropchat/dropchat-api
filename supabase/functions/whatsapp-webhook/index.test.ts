// F05 — the Meta webhook does every download, upload and upsert before it
// answers 200. Meta retries (and eventually disables) a webhook that takes
// too long; a history batch with twenty media items did.
//
// Runs against a local Supabase with supabase/tests/fixtures loaded. Graph
// API calls are stubbed with a slow fetch; storage and PostgREST are real.
import "../_shared/testing/env.ts"; // before index.ts: APP_SECRET is read at import
import { assert, assertEquals } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import type { Database } from "../_shared/types/database_types.ts";
import { env, fixture, supabaseIsUp } from "../_shared/testing/env.ts";
import { metaRequest } from "../_shared/testing/sign.ts";
import { handler } from "./index.ts";

const up = await supabaseIsUp();

const GRAPH_DELAY_MS = 150;
const MEDIA_COUNT = 20;

function delay(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** A `messages` change with N image messages from contact A1 to account A. */
function mediaBatch(run: string) {
  return {
    object: "whatsapp_business_account",
    entry: [{
      id: fixture.wabaA,
      changes: [{
        field: "messages",
        value: {
          messaging_product: "whatsapp",
          metadata: {
            display_phone_number: "5491100000001",
            phone_number_id: fixture.waA,
          },
          contacts: [{
            profile: { name: "Carla" },
            wa_id: fixture.contactA1,
            user_id: "AR.10000000000000000101",
          }],
          messages: Array.from({ length: MEDIA_COUNT }, (_, i) => ({
            from: fixture.contactA1,
            id: `wamid.F05.${run}.${i}`,
            timestamp: String(1757000000 + i),
            type: "image",
            image: {
              mime_type: "image/jpeg",
              sha256: "0".repeat(64),
              id: `9${String(i).padStart(14, "0")}`,
            },
          })),
        },
      }],
    }],
  };
}

/** Graph API stub: metadata then download, each after GRAPH_DELAY_MS. */
function stubGraph() {
  const realFetch = globalThis.fetch;
  let graphCalls = 0;

  globalThis.fetch = async (input, init) => {
    const url = input instanceof Request ? input.url : String(input);

    if (url.startsWith("https://graph.facebook.com/")) {
      graphCalls++;
      await delay(GRAPH_DELAY_MS);
      const id = url.split("/").pop();
      return Response.json({
        messaging_product: "whatsapp",
        url:
          `https://lookaside.fbsbx.com/whatsapp_business/attachments/?mid=${id}`,
        mime_type: "image/jpeg",
        sha256: "0".repeat(64),
        file_size: 10,
        id,
      });
    }

    if (url.startsWith("https://lookaside.fbsbx.com/")) {
      graphCalls++;
      await delay(GRAPH_DELAY_MS);
      return new Response(new Uint8Array(10), {
        headers: { "content-type": "image/jpeg" },
      });
    }

    return realFetch(input, init);
  };

  return {
    restore: () => {
      globalThis.fetch = realFetch;
    },
    calls: () => graphCalls,
  };
}

/** The deployed runtime's waitUntil, capturing what the handler defers. */
function stubEdgeRuntime() {
  const pending: Promise<unknown>[] = [];
  const g = globalThis as unknown as { EdgeRuntime?: unknown };
  const previous = g.EdgeRuntime;
  g.EdgeRuntime = { waitUntil: (p: Promise<unknown>) => pending.push(p) };
  return {
    pending,
    restore: () => {
      g.EdgeRuntime = previous;
    },
  };
}

Deno.test({
  name:
    "F05: the webhook acks before downloading 20 media items, then finishes the work under waitUntil",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const run = crypto.randomUUID();
    const graph = stubGraph();
    const runtime = stubEdgeRuntime();
    const client = createClient<Database>(env.url, env.serviceRoleKey, {
      auth: { persistSession: false },
    });

    try {
      const request = await metaRequest(
        "http://localhost/whatsapp-webhook",
        mediaBatch(run),
        env.metaAppSecret,
      );

      const t0 = performance.now();
      const response = await handler(request);
      const ackMs = performance.now() - t0;

      assertEquals(response.status, 200);
      // Two sequential Graph round trips per item, all items in parallel:
      // the work cannot finish in under 2 × GRAPH_DELAY_MS. The ack must.
      assert(
        ackMs < GRAPH_DELAY_MS,
        `ack took ${ackMs.toFixed(0)}ms; the work was awaited before answering`,
      );
      assertEquals(
        runtime.pending.length,
        1,
        "the work was handed to waitUntil",
      );

      await Promise.all(runtime.pending);
      const workMs = performance.now() - t0;
      assert(workMs >= 2 * GRAPH_DELAY_MS, `work finished in ${workMs}ms`);
      assertEquals(graph.calls(), MEDIA_COUNT * 2);

      const { data: rows } = await client
        .from("messages")
        .select("external_id, content")
        .eq("organization_id", fixture.orgA)
        .like("external_id", `wamid.F05.${run}.%`)
        .throwOnError();

      assertEquals(rows.length, MEDIA_COUNT);
      for (const row of rows) {
        const content = row.content as { type: string; file: { uri: string } };
        assertEquals(content.type, "file");
        assert(
          content.file.uri.startsWith("internal://media/"),
          `media was not stored: ${content.file.uri}`,
        );
      }
    } finally {
      graph.restore();
      runtime.restore();
      await client
        .from("messages")
        .delete()
        .eq("organization_id", fixture.orgA)
        .like("external_id", `wamid.F05.${run}.%`);
    }
  },
});

Deno.test({
  name: "F05: an invalid signature is acked with 200 and nothing is deferred",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const runtime = stubEdgeRuntime();
    try {
      const request = await metaRequest(
        "http://localhost/whatsapp-webhook",
        mediaBatch("bad"),
        "not-the-app-secret",
      );
      const response = await handler(request);
      assertEquals(response.status, 200);
      assertEquals(runtime.pending.length, 0);
    } finally {
      runtime.restore();
    }
  },
});
