// F28 — Instagram: a rejected token (Graph code 190) flagged the account
// `extra.needs_reauth`, but every later message still called Graph with the
// dead token, one failure each. Now, while the flag is present, sends fail at
// once without calling Graph and read receipts are skipped; a re-login or a
// successful refresh lifts it.
//
// Runs against a local Supabase with supabase/tests/fixtures loaded; Graph and
// the Instagram OAuth endpoints are stubbed. Tokens are obviously fake.
import "../_shared/testing/env.ts"; // before index.ts: keys are read at import
import { assert, assertEquals } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import type { Database, MessageRow } from "../_shared/types/database_types.ts";
import { env, fixture, supabaseIsUp } from "../_shared/testing/env.ts";
import { handler } from "./index.ts";
import {
  performInstagramLogin,
  refreshTokens,
} from "../instagram-management/login.ts";

const up = await supabaseIsUp();

const IG_ACCOUNT = "17841400000000928";
const IG_CONTACT = "990000000000928";
const TOKEN = "IGAA-test-secret-f28";

function service() {
  return createClient<Database>(env.url, env.serviceRoleKey, {
    auth: { persistSession: false },
  });
}

type Client = ReturnType<typeof service>;

type Route = (req: Request) => Promise<Response> | Response | undefined;

/** Answers Instagram's hosts; counts Send API calls. Anything else is real. */
function stubInstagram(route: Route) {
  const realFetch = globalThis.fetch;
  let sends = 0;
  globalThis.fetch = async (input, init) => {
    const req = input instanceof Request ? input : new Request(input, init);
    const url = new URL(req.url);
    if (
      url.hostname === "graph.instagram.com" ||
      url.hostname === "api.instagram.com"
    ) {
      if (url.pathname.endsWith(`/${IG_ACCOUNT}/messages`)) sends++;
      const response = await route(req);
      if (response) return response;
      return Response.json({ error: { message: "unrouted", code: 100 } }, {
        status: 400,
      });
    }
    return realFetch(input, init);
  };
  return { sends: () => sends, restore: () => (globalThis.fetch = realFetch) };
}

const EXPIRED = () =>
  Response.json({
    error: {
      message: "Error validating access token: Session has expired",
      type: "OAuthException",
      code: 190,
    },
  }, { status: 401 });

const SENT = () =>
  Response.json({
    recipient_id: IG_CONTACT,
    message_id: `mid.f28.${Date.now()}`,
  });

async function withAccount(fn: (client: Client) => Promise<void>) {
  const client = service();
  await client
    .from("organizations_addresses")
    .insert({
      organization_id: fixture.orgA,
      service: "instagram",
      address: IG_ACCOUNT,
      status: "connected",
      extra: {
        ig_user_id: IG_ACCOUNT,
        username: "f28_test",
        access_token: TOKEN,
        token_expires_at: new Date(Date.now() + 30 * 86_400_000).toISOString(),
      },
    })
    .throwOnError();
  try {
    await fn(client);
  } finally {
    await client.from("logs").delete().eq("organization_id", fixture.orgA)
      .eq("organization_address", IG_ACCOUNT);
    await client
      .from("organizations_addresses")
      .delete()
      .eq("organization_id", fixture.orgA)
      .eq("service", "instagram")
      .eq("address", IG_ACCOUNT)
      .throwOnError();
  }
}

async function outgoing(client: Client, text = "hola") {
  const { data } = await client
    .from("messages")
    .insert({
      organization_id: fixture.orgA,
      service: "instagram",
      organization_address: IG_ACCOUNT,
      conversation_address: IG_CONTACT,
      sender_address: null,
      agent_id: fixture.agentAlice,
      content: { version: "1", type: "text", kind: "text", text },
      status: { pending: new Date().toISOString() },
    })
    .select()
    .single()
    .throwOnError();
  return data as MessageRow;
}

function request(record: MessageRow) {
  return new Request("http://localhost/instagram-dispatcher", {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.serviceRoleKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      type: "INSERT",
      table: "messages",
      schema: "public",
      record,
      old_record: null,
    }),
  });
}

async function extraOf(client: Client) {
  const { data } = await client
    .from("organizations_addresses")
    .select("extra, status")
    .eq("organization_id", fixture.orgA)
    .eq("service", "instagram")
    .eq("address", IG_ACCOUNT)
    .single()
    .throwOnError();
  return data as { extra: Record<string, unknown>; status: string };
}

async function statusOf(client: Client, id: string) {
  const { data } = await client
    .from("messages")
    .select("status")
    .eq("id", id)
    .single()
    .throwOnError();
  return data.status as Record<string, unknown>;
}

const integration = {
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
};

Deno.test({
  ...integration,
  name:
    "F28: a 190 flags the Instagram account, and the next message fails without calling Graph",
  fn: () =>
    withAccount(async (client) => {
      const first = await outgoing(client);
      const second = await outgoing(client, "otra vez");
      const graph = stubInstagram(EXPIRED);
      try {
        await handler(request(first));
        assert((await statusOf(client, first.id)).failed, "a 190 is permanent");

        const { extra, status } = await extraOf(client);
        assert(extra.needs_reauth, "the account was not flagged");
        assertEquals(status, "connected", "inbound must keep flowing");

        await handler(request(second));
        assertEquals(graph.sends(), 1, "Graph was called with a dead token");
        const secondStatus = await statusOf(client, second.id);
        assert(secondStatus.failed);
        assertEquals(secondStatus.pending, undefined);
        assert(
          JSON.stringify(secondStatus.errors).includes("190"),
          JSON.stringify(secondStatus.errors),
        );
        assert(
          !JSON.stringify(secondStatus.errors).includes(TOKEN),
          "token leaked into the message status",
        );

        const { data: logs } = await client
          .from("logs")
          .select("level, category")
          .eq("organization_id", fixture.orgA)
          .eq("organization_address", IG_ACCOUNT)
          .eq("category", "dispatch")
          .throwOnError();
        assertEquals(logs.length, 1, "one log line, when the flag is set");
      } finally {
        graph.restore();
      }
    }),
});

Deno.test({
  ...integration,
  name: "F28: read receipts are skipped while the Instagram account is flagged",
  fn: () =>
    withAccount(async (client) => {
      await client
        .from("organizations_addresses")
        .update({ extra: { needs_reauth: new Date().toISOString() } })
        .eq("organization_id", fixture.orgA)
        .eq("service", "instagram")
        .eq("address", IG_ACCOUNT)
        .throwOnError();

      let calls = 0;
      const graph = stubInstagram(() => {
        calls++;
        return Response.json({ recipient_id: IG_CONTACT });
      });
      try {
        const inbound = {
          id: crypto.randomUUID(),
          organization_id: fixture.orgA,
          service: "instagram",
          organization_address: IG_ACCOUNT,
          conversation_address: IG_CONTACT,
          sender_address: IG_CONTACT,
          external_id: "mid.f28.inbound",
          content: { version: "1", type: "text", kind: "text", text: "hola" },
          status: { read: new Date().toISOString() },
        } as unknown as MessageRow;
        const response = await handler(request(inbound));
        assertEquals(response.status, 200);
        assertEquals(calls, 0, "a read receipt went out with a dead token");
      } finally {
        graph.restore();
      }
    }),
});

Deno.test({
  ...integration,
  name: "F28: a token renewed while the send was in flight is not flagged",
  fn: () =>
    withAccount(async (client) => {
      const message = await outgoing(client);
      const graph = stubInstagram(async () => {
        // The owner re-logs in while Graph rejects the old token.
        await client
          .from("organizations_addresses")
          .update({ extra: { access_token: `${TOKEN}-renewed` } })
          .eq("organization_id", fixture.orgA)
          .eq("service", "instagram")
          .eq("address", IG_ACCOUNT)
          .throwOnError();
        return EXPIRED();
      });
      try {
        await handler(request(message));
        assertEquals((await extraOf(client)).extra.needs_reauth, undefined);
      } finally {
        graph.restore();
      }
    }),
});

Deno.test({
  ...integration,
  name: "F28: re-logging in lifts the Instagram flag and sends again",
  fn: () =>
    withAccount(async (client) => {
      const failing = await outgoing(client);
      let graph = stubInstagram(EXPIRED);
      try {
        await handler(request(failing));
        assert((await extraOf(client)).extra.needs_reauth);
      } finally {
        graph.restore();
      }

      graph = stubInstagram((req) => {
        const url = new URL(req.url);
        if (url.pathname === "/oauth/access_token") {
          return Response.json({
            access_token: "IGAA-test-short-lived",
            user_id: IG_ACCOUNT,
            permissions: "instagram_business_basic",
          });
        }
        if (url.pathname === "/access_token") {
          return Response.json({
            access_token: `${TOKEN}-relogin`,
            token_type: "bearer",
            expires_in: 5_184_000,
          });
        }
        if (url.pathname.endsWith("/me")) {
          return Response.json({ user_id: IG_ACCOUNT, username: "f28_test" });
        }
        if (url.pathname.endsWith("/me/subscribed_apps")) {
          return Response.json({ success: true });
        }
        if (url.pathname.endsWith(`/${IG_ACCOUNT}/messages`)) return SENT();
      });
      try {
        await performInstagramLogin(client as never, {
          code: "fake-oauth-code",
          redirect_uri: "https://app.example.com/instagram/callback",
          organization_id: fixture.orgA,
        } as never);
        assertEquals(
          (await extraOf(client)).extra.needs_reauth,
          undefined,
          "re-login did not lift the flag",
        );

        const next = await outgoing(client, "de nuevo");
        await handler(request(next));
        assertEquals(graph.sends(), 1);
        assert((await statusOf(client, next.id)).accepted);
      } finally {
        graph.restore();
      }
    }),
});

Deno.test({
  ...integration,
  name:
    "F28: a successful refresh lifts the flag; a transient refresh failure does not set it",
  fn: () =>
    withAccount(async (client) => {
      const nearExpiry = new Date(Date.now() + 86_400_000).toISOString();
      await client
        .from("organizations_addresses")
        .update({ extra: { token_expires_at: nearExpiry } })
        .eq("organization_id", fixture.orgA)
        .eq("service", "instagram")
        .eq("address", IG_ACCOUNT)
        .throwOnError();

      // Graph is down: the token may well be fine, sends must not stop.
      let graph = stubInstagram(() =>
        Response.json({
          error: {
            message: "Service unavailable",
            code: 2,
            is_transient: true,
          },
        }, { status: 503 })
      );
      try {
        await refreshTokens(client as never);
        assertEquals((await extraOf(client)).extra.needs_reauth, undefined);
      } finally {
        graph.restore();
      }

      // The token is dead: flagged.
      graph = stubInstagram(EXPIRED);
      try {
        await refreshTokens(client as never);
        assert((await extraOf(client)).extra.needs_reauth);
      } finally {
        graph.restore();
      }

      // A refresh that works lifts it, and sends go out again.
      graph = stubInstagram((req) => {
        const url = new URL(req.url);
        if (url.pathname === "/refresh_access_token") {
          return Response.json({
            access_token: `${TOKEN}-refreshed`,
            token_type: "bearer",
            expires_in: 5_184_000,
          });
        }
        if (url.pathname.endsWith(`/${IG_ACCOUNT}/messages`)) return SENT();
      });
      try {
        await refreshTokens(client as never);
        assertEquals((await extraOf(client)).extra.needs_reauth, undefined);
        const next = await outgoing(client);
        await handler(request(next));
        assertEquals(graph.sends(), 1);
        assert((await statusOf(client, next.id)).accepted);
      } finally {
        graph.restore();
      }
    }),
});
