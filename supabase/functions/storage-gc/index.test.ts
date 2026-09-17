// F18 — an account-scoped deletion (Meta's data-deletion callback) left the
// account's attachments in Storage: storage-gc only removed the folders of
// organizations that no longer exist, and the organization survives.
//
// Now sweep_deletions records the objects the deleted messages referenced
// (public.deletion_media) and storage-gc removes those no remaining message
// uses. Runs against a local Supabase (Storage included) with
// supabase/tests/fixtures loaded.
import "../_shared/testing/env.ts"; // before index.ts: keys are read at import
import { assert, assertEquals } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import type { Database } from "../_shared/types/database_types.ts";
import { env, fixture, supabaseIsUp } from "../_shared/testing/env.ts";
import { handler } from "./index.ts";

const up = await supabaseIsUp();

function service() {
  return createClient<Database>(env.url, env.serviceRoleKey, {
    auth: { persistSession: false },
  });
}

type Client = ReturnType<typeof service>;

function gc() {
  return handler(
    new Request("http://localhost/storage-gc", {
      method: "POST",
      headers: { authorization: `Bearer ${env.serviceRoleKey}` },
    }),
  );
}

async function exists(client: Client, name: string) {
  const { data, error } = await client.storage.from("media").download(name);
  return !error && data !== null;
}

async function record(client: Client, names: string[]) {
  // What sweep_deletions writes for a deleted account (pgTAP 22 covers it).
  await client
    .from("deletion_media")
    .insert(
      names.map((object_name) => ({
        request_id: crypto.randomUUID(),
        organization_id: fixture.orgA,
        object_name,
      })),
    )
    .throwOnError();
}

async function recorded(client: Client, names: string[]) {
  const { data } = await client
    .from("deletion_media")
    .select("object_name")
    .in("object_name", names)
    .throwOnError();
  return data.length;
}

Deno.test({
  name:
    "F18: storage-gc removes a deleted account's objects nothing references, keeps shared ones, and is idempotent",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    const run = crypto.randomUUID();
    const base = `organizations/${fixture.orgA}/attachments`;
    const exclusive = `${base}/f18-gc-exclusive-${run}`;
    const shared = `${base}/f18-gc-shared-${run}`;
    let messageId: string | undefined;

    try {
      for (const name of [exclusive, shared]) {
        await client.storage
          .from("media")
          .upload(name, new Blob(["f18"], { type: "image/jpeg" }))
          .then(({ error }) => {
            if (error) throw error;
          });
      }

      // Another account of the organization still shows the shared object.
      const { data: message } = await client
        .from("messages")
        .insert({
          organization_id: fixture.orgA,
          service: "whatsapp",
          organization_address: fixture.waA,
          conversation_address: fixture.contactA1,
          sender_address: fixture.contactA1,
          content: {
            version: "1",
            type: "file",
            kind: "image",
            file: {
              uri: `internal://media/${shared}`,
              mime_type: "image/jpeg",
              size: 3,
            },
          },
          status: { delivered: new Date().toISOString() },
        })
        .select("id")
        .single()
        .throwOnError();
      messageId = message.id;

      await record(client, [exclusive, shared]);

      const first = await gc();
      assertEquals(first.status, 200);
      const body = await first.json();
      assertEquals(body.account_media.removed, 1);
      assertEquals(body.account_media.kept, 1);

      assertEquals(await exists(client, exclusive), false, "not removed");
      assertEquals(await exists(client, shared), true, "shared object removed");
      assertEquals(await recorded(client, [exclusive, shared]), 0);

      // A second run, and a row naming an object already gone: nothing
      // breaks, nothing else is removed, the row is forgotten.
      await record(client, [exclusive]);
      const second = await (await gc()).json();
      assertEquals(second.account_media.removed, 0);
      assertEquals(await recorded(client, [exclusive]), 0);
      assert(await exists(client, shared));
    } finally {
      if (messageId) await client.from("messages").delete().eq("id", messageId);
      await client.from("deletion_media").delete().in("object_name", [
        exclusive,
        shared,
      ]);
      await client.storage.from("media").remove([exclusive, shared]);
    }
  },
});
