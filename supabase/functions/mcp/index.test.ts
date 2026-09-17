// F27 — the MCP server scoped an OAuth user to "the first organization":
// `agents … limit(1)` with no order and no deleted_at filter. A member of two
// organizations operated on whichever row Postgres returned first, and could
// not choose.
//
// Now: `Organization-Id` (header) or `?organization_id=` picks one of the
// caller's live memberships; without it, the oldest membership. An API key is
// already one organization: naming another is refused.
//
// Runs against a local Supabase with supabase/tests/fixtures loaded. Alice
// (owner of A) is given a membership in B for the test's duration.
import "../_shared/testing/env.ts";
import { assert, assertEquals } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import type { Database } from "../_shared/types/database_types.ts";
import { env, fixture, supabaseIsUp } from "../_shared/testing/env.ts";
import { handler } from "./index.ts";

const up = await supabaseIsUp();

const ALICE = "aaaaaaaa-0000-4000-8000-0000000000a1";
const OTHER_ORG = "cccccccc-0000-4000-8000-000000000001"; // alice is not in it
const API_KEY_A = "test-key-a-owner-0000000000000000000"; // fixture, not a secret
const PHONE_A = "5491100000001";
const PHONE_B = "5492200000002";

function service() {
  return createClient<Database>(env.url, env.serviceRoleKey, {
    auth: { persistSession: false },
  });
}

async function aliceToken() {
  const client = createClient(env.url, env.anonKey, {
    auth: { persistSession: false },
  });
  const { data, error } = await client.auth.signInWithPassword({
    email: "alice@test.local",
    password: "alice", // the fixture's password
  });
  if (error) throw error;
  return data.session.access_token;
}

/** Alice as a member of B, older than her membership of A. */
async function withMembershipInB(fn: () => Promise<void>) {
  const client = service();
  await client
    .from("agents")
    .upsert({
      organization_id: fixture.orgB,
      user_id: ALICE,
      name: "Alice",
      role: "member",
      created_at: "2000-01-01T00:00:00Z",
      deleted_at: null,
    }, { onConflict: "organization_id,user_id" })
    .throwOnError();
  try {
    await fn();
  } finally {
    await client
      .from("agents")
      .update({ deleted_at: new Date().toISOString() })
      .eq("organization_id", fixture.orgB)
      .eq("user_id", ALICE)
      .throwOnError();
  }
}

/** Calls the `list_conversations` tool; returns the status and the account. */
async function listConversations(
  headers: Record<string, string>,
  query = "",
) {
  const response = await handler(
    new Request(`http://localhost/mcp${query}`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        accept: "application/json, text/event-stream",
        ...headers,
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: { name: "list_conversations", arguments: { limit: 1 } },
      }),
    }),
  );
  const text = await response.text();
  if (response.status !== 200) {
    return { status: response.status, phone: undefined, body: text };
  }
  const data = text.split("\n").find((l) => l.startsWith("data:"));
  const message = JSON.parse(data ? data.slice(5) : text);
  const result = JSON.parse(message.result.content[0].text);
  return { status: 200, phone: result.account?.phone as string, body: text };
}

function quiet<T>(fn: () => Promise<T>) {
  const { error, log, warn } = console;
  console.error = console.log = console.warn = () => {};
  return fn().finally(() => {
    Object.assign(console, { error, log, warn });
  });
}

const test = (name: string, fn: () => Promise<void>) =>
  Deno.test({
    name,
    ignore: !up,
    sanitizeResources: false,
    sanitizeOps: false,
    fn: () => quiet(fn),
  });

test("F27: Organization-Id picks the member's organization", async () => {
  const token = await aliceToken();
  await withMembershipInB(async () => {
    const a = await listConversations({
      authorization: `Bearer ${token}`,
      "organization-id": fixture.orgA,
    });
    const b = await listConversations({
      authorization: `Bearer ${token}`,
      "organization-id": fixture.orgB,
    });
    assertEquals([a.status, a.phone], [200, PHONE_A], a.body);
    assertEquals([b.status, b.phone], [200, PHONE_B], b.body);
  });
});

test("F27: ?organization_id= works for connectors that cannot set headers", async () => {
  const token = await aliceToken();
  await withMembershipInB(async () => {
    const b = await listConversations(
      { authorization: `Bearer ${token}` },
      `?organization_id=${fixture.orgB}`,
    );
    assertEquals([b.status, b.phone], [200, PHONE_B], b.body);
  });
});

test("F27: without a choice, the oldest membership, every time", async () => {
  const token = await aliceToken();
  await withMembershipInB(async () => {
    for (let i = 0; i < 3; i++) {
      const r = await listConversations({ authorization: `Bearer ${token}` });
      assertEquals([r.status, r.phone], [200, PHONE_B], r.body);
    }
  });
});

test("F27: an organization the user does not belong to is refused", async () => {
  const token = await aliceToken();
  const other = await listConversations({
    authorization: `Bearer ${token}`,
    "organization-id": OTHER_ORG,
  });
  assertEquals(other.status, 403, other.body);

  const malformed = await listConversations({
    authorization: `Bearer ${token}`,
    "organization-id": "not-a-uuid",
  });
  assertEquals(malformed.status, 400, malformed.body);
});

test("F27: a membership that was removed does not count", async () => {
  const token = await aliceToken();
  await withMembershipInB(async () => {});
  // Now deleted_at is set on alice's membership of B.
  const b = await listConversations({
    authorization: `Bearer ${token}`,
    "organization-id": fixture.orgB,
  });
  assertEquals(b.status, 403, b.body);
  const fallback = await listConversations({
    authorization: `Bearer ${token}`,
  });
  assertEquals([fallback.status, fallback.phone], [200, PHONE_A]);
});

test("F27: an API key names its own organization or none", async () => {
  const own = await listConversations({
    "api-key": API_KEY_A,
    "organization-id": fixture.orgA,
  });
  assertEquals([own.status, own.phone], [200, PHONE_A], own.body);

  const plain = await listConversations({ "api-key": API_KEY_A });
  assertEquals([plain.status, plain.phone], [200, PHONE_A], plain.body);

  const other = await listConversations({
    "api-key": API_KEY_A,
    "organization-id": fixture.orgB,
  });
  assertEquals(other.status, 403, other.body);
  assert(!other.body.includes(PHONE_B));
});
