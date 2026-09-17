// uploadToStorage keys a file by the SHA-256 of its bytes, so identical
// attachments share one object. Several of them uploaded at once — a batch of
// the same sticker, or the F05 test's twenty identical images on an empty
// bucket — raced to create that object, and Storage refused all but one with
// "The resource already exists". The losers' messages were stored with their
// Graph reference instead of the file.
import "./testing/env.ts";
import { assertEquals } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import { env, fixture, supabaseIsUp } from "./testing/env.ts";
import { uploadToStorage } from "./media.ts";

const up = await supabaseIsUp();

Deno.test({
  name: "uploadToStorage: identical bytes uploaded at once all succeed",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = createClient(env.url, env.serviceRoleKey, {
      auth: { persistSession: false },
    });
    // Bytes no earlier run has stored: the object does not exist yet.
    const bytes = new TextEncoder().encode(`media-race-${crypto.randomUUID()}`);
    let uri = "";

    try {
      const results = await Promise.allSettled(
        Array.from(
          { length: 20 },
          () =>
            uploadToStorage(
              client,
              fixture.orgA,
              new Blob([bytes], { type: "image/jpeg" }),
            ),
        ),
      );

      const rejected = results.filter((r) => r.status === "rejected");
      assertEquals(
        rejected.map((r) => String((r as PromiseRejectedResult).reason)),
        [],
      );
      const uris = new Set(
        results.map((r) => (r as PromiseFulfilledResult<string>).value),
      );
      assertEquals(uris.size, 1);
      uri = [...uris][0];
    } finally {
      if (uri) {
        await client.storage.from("media").remove([
          uri.replace("internal://media/", ""),
        ]);
      }
    }
  },
});
