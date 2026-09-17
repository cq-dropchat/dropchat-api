// F10 — the broadcast channels, end to end through the local Realtime
// server: two signed-in clients (user A, user B from
// supabase/tests/fixtures; test-only passwords) join private channels; a
// message inserted in organization A reaches A's org channel only, a status
// update arrives as a notice without content, and the conversation channel
// carries the full row.
import "../_shared/testing/env.ts";
import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  createClient,
  type RealtimeChannel,
  type SupabaseClient,
} from "@supabase/supabase-js";
import type { Database } from "../_shared/types/database_types.ts";
import { env, fixture, supabaseIsUp } from "../_shared/testing/env.ts";

const up = await supabaseIsUp();

async function realtimeIsUp(): Promise<boolean> {
  if (!up) return false;
  try {
    const res = await fetch(`${env.url}/realtime/v1/api/ping`, {
      headers: { apikey: env.anonKey },
    });
    await res.body?.cancel();
    return res.status < 500;
  } catch {
    return false;
  }
}

const realtime = await realtimeIsUp();

type Notice = Record<string, unknown>;

async function signedIn(email: string, password: string) {
  const client = createClient<Database>(env.url, env.anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await client.auth.signInWithPassword({
    email,
    password,
  });
  if (error) throw error;
  await client.realtime.setAuth(data.session.access_token);
  return client;
}

/** Joins a private channel; resolves with its status and received payloads. */
function join(client: SupabaseClient<Database>, topic: string) {
  const received: Notice[] = [];
  let channel!: RealtimeChannel;
  const status = new Promise<string>((resolve) => {
    channel = client
      .channel(topic, { config: { private: true } })
      .on("broadcast", { event: "*" }, ({ payload }) => {
        received.push(payload as Notice);
      })
      .subscribe((state) => {
        if (state !== "CLOSED") resolve(state);
      });
  });
  return { channel, received, status };
}

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function until(check: () => boolean, ms = 5000) {
  const deadline = Date.now() + ms;
  while (!check() && Date.now() < deadline) await wait(100);
}

Deno.test({
  name:
    "F10: broadcast channels on local Realtime — org notices only to members, no content; the conversation channel carries the row",
  ignore: !realtime,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const service = createClient<Database>(env.url, env.serviceRoleKey, {
      auth: { persistSession: false },
    });
    const alice = await signedIn("alice@test.local", "alice");
    const bob = await signedIn("bob@test.local", "bob");

    const aliceOrg = join(alice, `org:${fixture.orgA}`);
    const aliceConv = join(alice, `conv:${fixture.convA1}`);
    const bobOrgA = join(bob, `org:${fixture.orgA}`);
    let messageId: string | undefined;

    try {
      assertEquals(await aliceOrg.status, "SUBSCRIBED");
      assertEquals(await aliceConv.status, "SUBSCRIBED");
      assert(
        (await bobOrgA.status) !== "SUBSCRIBED",
        "user B joined organization A's channel",
      );

      const { data: message } = await service
        .from("messages")
        .insert({
          organization_id: fixture.orgA,
          service: "whatsapp",
          organization_address: fixture.waA,
          conversation_address: fixture.contactA1,
          sender_address: fixture.contactA1,
          content: {
            version: "1",
            type: "text",
            kind: "text",
            text: "f10 contenido privado",
          },
          status: { delivered: new Date().toISOString() },
        })
        .select("id")
        .single()
        .throwOnError();
      messageId = message.id;

      await service
        .from("messages")
        .update({ status: { read: new Date().toISOString() } })
        .eq("id", messageId)
        .throwOnError();

      await until(() =>
        aliceOrg.received.filter((n) => n.id === messageId).length >= 2 &&
        aliceConv.received.length >= 2
      );

      const notices = aliceOrg.received.filter((n) => n.id === messageId);
      assertEquals(notices.map((n) => n.op), ["INSERT", "UPDATE"]);
      assertEquals(notices[1].status_changed, ["read"]);
      for (const notice of notices) {
        assert(!("content" in notice));
        assert(!JSON.stringify(notice).includes("f10 contenido privado"));
      }

      const rows = aliceConv.received.filter((n) =>
        (n.record as Notice | undefined)?.id === messageId
      );
      assert(
        JSON.stringify(rows[0]).includes("f10 contenido privado"),
        "the conversation channel carries the row",
      );

      assertEquals(bobOrgA.received.length, 0, "user B received A's notices");
    } finally {
      for (const c of [aliceOrg, aliceConv, bobOrgA]) {
        await c.channel.unsubscribe();
      }
      alice.realtime.disconnect();
      bob.realtime.disconnect();
      if (messageId) {
        await service.from("messages").delete().eq("id", messageId);
      }
    }
  },
});
