// F05, Instagram half: the handler acks a signed payload before any
// processing and hands the work to waitUntil. Uses the fixture payload (an
// IGSID no organization has connected), so the deferred work resolves the
// tenant, finds none, and ends — no Graph calls, no rows.
import "../_shared/testing/env.ts"; // before index.ts: APP_SECRET is read at import
import { assert, assertEquals } from "jsr:@std/assert@1";
import { env, supabaseIsUp } from "../_shared/testing/env.ts";
import { metaRequest } from "../_shared/testing/sign.ts";
import { handler } from "./index.ts";
import payload from "../_shared/__fixtures__/instagram/messages.json" with {
  type: "json",
};

const up = await supabaseIsUp();

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
  name: "F05: the Instagram webhook acks first and defers the processing",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const runtime = stubEdgeRuntime();
    try {
      const request = await metaRequest(
        "http://localhost/instagram-webhook",
        payload,
        env.instagramAppSecret,
      );

      const t0 = performance.now();
      const response = await handler(request);
      const ackMs = performance.now() - t0;

      assertEquals(response.status, 200);
      assertEquals(runtime.pending.length, 1);
      // No database round trip happens before the ack.
      assert(ackMs < 50, `ack took ${ackMs.toFixed(0)}ms`);

      await Promise.all(runtime.pending);
    } finally {
      runtime.restore();
    }
  },
});

Deno.test("F05: a GET verification challenge is answered inline", async () => {
  const response = await handler(
    new Request(
      "http://localhost/instagram-webhook?hub.mode=subscribe&hub.verify_token=wrong&hub.challenge=123",
    ),
  );
  assertEquals(response.status, 403);
});
