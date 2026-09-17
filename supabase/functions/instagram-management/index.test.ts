// F18 — Meta's Instagram callbacks acted on every organization holding the
// account. Organization A connected an Instagram account, later organization
// B connected the same one (the newest connected row owns it: that is where
// instagram-webhook routes messages). A data-deletion request then deleted
// BOTH rows — and by cascade A's conversations and messages too — inside
// Meta's HTTP request; a deauthorize disconnected both.
//
// Runs against a local Supabase with supabase/tests/fixtures loaded.
import "../_shared/testing/env.ts"; // before index.ts: keys are read at import
import { assert, assertEquals } from "jsr:@std/assert@1";
import { encodeBase64Url } from "@std/encoding/base64url";
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

async function signedRequest(payload: Record<string, unknown>) {
  const encodedPayload = encodeBase64Url(
    new TextEncoder().encode(JSON.stringify(payload)),
  );
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(env.instagramAppSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(encodedPayload),
  );
  return `${encodeBase64Url(new Uint8Array(sig))}.${encodedPayload}`;
}

async function callback(path: string, igUserId: string) {
  const form = new FormData();
  form.set(
    "signed_request",
    await signedRequest({
      user_id: igUserId,
      algorithm: "HMAC-SHA256",
      issued_at: Math.floor(Date.now() / 1000),
    }),
  );
  return await handler(
    new Request(`http://localhost/instagram-management/${path}`, {
      method: "POST",
      body: form,
    }),
  );
}

/** The same account connected in org A (older) and org B (newer, the owner). */
async function sharedAccount(client: Client) {
  const igUserId = `1784${Math.floor(Math.random() * 1e11)}`;
  const contact = `999${Math.floor(Math.random() * 1e10)}`;

  await client
    .from("organizations_addresses")
    .insert([
      {
        organization_id: fixture.orgA,
        service: "instagram",
        address: igUserId,
        status: "connected",
        created_at: new Date(Date.now() - 2 * 86400_000).toISOString(),
      },
      {
        organization_id: fixture.orgB,
        service: "instagram",
        address: igUserId,
        status: "connected",
        created_at: new Date(Date.now() - 86400_000).toISOString(),
      },
    ])
    .throwOnError();

  for (const organization_id of [fixture.orgA, fixture.orgB]) {
    await client
      .from("messages")
      .insert({
        organization_id,
        service: "instagram",
        organization_address: igUserId,
        conversation_address: contact,
        sender_address: contact,
        content: { version: "1", type: "text", kind: "text", text: "hola" },
        status: { delivered: new Date().toISOString() },
      })
      .throwOnError();
  }

  return igUserId;
}

async function cleanup(client: Client, igUserId: string) {
  await client.from("deletion_requests").delete().eq("address", igUserId);
  await client.from("organizations_addresses").delete()
    .eq("service", "instagram").eq("address", igUserId);
}

async function account(
  client: Client,
  organizationId: string,
  igUserId: string,
) {
  const { data } = await client
    .from("organizations_addresses")
    .select("status")
    .eq("organization_id", organizationId)
    .eq("service", "instagram")
    .eq("address", igUserId)
    .maybeSingle()
    .throwOnError();
  return data;
}

async function messageCount(
  client: Client,
  organizationId: string,
  igUserId: string,
) {
  const { count } = await client
    .from("messages")
    .select("id", { count: "exact", head: true })
    .eq("organization_id", organizationId)
    .eq("organization_address", igUserId)
    .throwOnError();
  return count;
}

Deno.test({
  name:
    "F18: a data-deletion request is filed for the owning organization only, not run inline for all",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    const igUserId = await sharedAccount(client);

    try {
      const response = await callback("data-deletion", igUserId);
      assertEquals(response.status, 200);
      const { url, confirmation_code } = await response.json();

      // Org A — which lost the connection to B — keeps everything.
      assertEquals(
        (await account(client, fixture.orgA, igUserId))?.status,
        "connected",
      );
      assertEquals(await messageCount(client, fixture.orgA, igUserId), 1);

      // Org B's account is disconnected at once; the data waits for the sweep.
      assertEquals(
        (await account(client, fixture.orgB, igUserId))?.status,
        "deleting",
      );
      assertEquals(await messageCount(client, fixture.orgB, igUserId), 1);

      const { data: request } = await client
        .from("deletion_requests")
        .select("id, organization_id, source, completed_at")
        .eq("id", confirmation_code)
        .single()
        .throwOnError();
      assertEquals(request.organization_id, fixture.orgB);
      assertEquals(request.source, "meta_data_deletion");

      // The status URL reports the real state of that request.
      const pending = await (await handler(new Request(url))).json();
      assertEquals(pending.status, "pending");
      assertEquals(pending.confirmation_code, confirmation_code);

      await client
        .from("deletion_requests")
        .update({ completed_at: new Date().toISOString() })
        .eq("id", confirmation_code)
        .throwOnError();
      const done = await (await handler(new Request(url))).json();
      assertEquals(done.status, "completed");

      const unknown = await handler(
        new Request(
          `http://localhost/instagram-management/data-deletion/status?code=${crypto.randomUUID()}`,
        ),
      );
      assertEquals(unknown.status, 404);
    } finally {
      await cleanup(client, igUserId);
    }
  },
});

Deno.test({
  name:
    "F18: a deauthorize disconnects the owning organization only, and a later data deletion still targets it",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    const igUserId = await sharedAccount(client);

    try {
      const response = await callback("deauthorize", igUserId);
      assertEquals(response.status, 200);

      assertEquals(
        (await account(client, fixture.orgA, igUserId))?.status,
        "connected",
      );
      assertEquals(
        (await account(client, fixture.orgB, igUserId))?.status,
        "disconnected",
      );

      // Meta sends the data-deletion request after the deauthorize: it still
      // targets B, not A's older row that happens to be connected.
      const deletion = await callback("data-deletion", igUserId);
      const { confirmation_code } = await deletion.json();
      const { data: request } = await client
        .from("deletion_requests")
        .select("organization_id")
        .eq("id", confirmation_code)
        .single()
        .throwOnError();
      assertEquals(request.organization_id, fixture.orgB);
      assertEquals(
        (await account(client, fixture.orgA, igUserId))?.status,
        "connected",
      );
    } finally {
      await cleanup(client, igUserId);
    }
  },
});

Deno.test({
  name: "F18: an account nobody holds files nothing and still answers Meta",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    const igUserId = `1784${Math.floor(Math.random() * 1e11)}`;

    const response = await callback("data-deletion", igUserId);
    assertEquals(response.status, 200);
    const { confirmation_code } = await response.json();
    assert(typeof confirmation_code === "string");

    const { count } = await client
      .from("deletion_requests")
      .select("id", { count: "exact", head: true })
      .eq("address", igUserId)
      .throwOnError();
    assertEquals(count, 0);
  },
});
