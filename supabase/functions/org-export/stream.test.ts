import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import { strFromU8, unzipSync } from "fflate";
import { streamOrganizationExport } from "./export.ts";
Deno.test("ZIP backpressure fetches no pages before consumption and cancellation stops work", async () => {
  const requests: URL[] = [];
  const client = createClient("http://localhost:54321", "test", {
    auth: { persistSession: false },
    global: {
      fetch: (input) => {
        requests.push(new URL(String(input)));
        return Promise.resolve(
          new Response("[]", {
            headers: { "content-type": "application/json" },
          }),
        );
      },
    },
  });
  const exported = streamOrganizationExport(client, "org");
  assertEquals(requests.length, 0);
  const reader = exported.stream.getReader();
  await reader.read();
  assertEquals(requests.length, 1);
  await reader.cancel();
  assertEquals(requests.length, 1);
});
Deno.test("streamed ZIP remains valid and surfaces a mid-export query failure", async () => {
  let fail = false;
  const client = createClient("http://localhost:54321", "test", {
    auth: { persistSession: false },
    global: {
      fetch: (input) => {
        const path = new URL(String(input)).pathname;
        if (fail && path.endsWith("/messages")) {
          return Promise.resolve(
            new Response('{"message":"unavailable"}', { status: 503 }),
          );
        }
        return Promise.resolve(
          new Response(
            path.endsWith("/organizations") ? '[{"id":"org"}]' : "[]",
            { headers: { "content-type": "application/json" } },
          ),
        );
      },
    },
  });
  const exported = streamOrganizationExport(client, "org");
  const bytes = new Uint8Array(
    await new Response(exported.stream).arrayBuffer(),
  );
  const files = unzipSync(bytes);
  assertEquals(
    JSON.parse(strFromU8(files["manifest.json"])).counts.organizations,
    1,
  );
  assertEquals(exported.bytes, bytes.length);
  fail = true;
  await assertRejects(async () => {
    await new Response(streamOrganizationExport(client, "org").stream)
      .arrayBuffer();
  });
});
