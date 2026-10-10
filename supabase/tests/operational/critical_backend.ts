// Backend integration fixture for browser assertions. Only providers are fake.
import "../../functions/_shared/testing/env.ts";
import { assert, assertEquals } from "jsr:@std/assert@1";
import postgres from "postgres";
import { createClient } from "@supabase/supabase-js";
import { decodeBase64 } from "jsr:@std/encoding/base64";
import {
  edgeRuntimeIsUp,
  env,
  fixture,
} from "../../functions/_shared/testing/env.ts";
import { metaRequest } from "../../functions/_shared/testing/sign.ts";
import {
  stubLlm,
  withTestAgent,
} from "../../functions/_shared/testing/agents.ts";
import { handler as webhook } from "../../functions/whatsapp-webhook/index.ts";
import { handler as agent } from "../../functions/agent-client/index.ts";
import { handler as dispatch } from "../../functions/whatsapp-dispatcher/index.ts";
import type {
  Database,
  MessageRow,
} from "../../functions/_shared/types/database_types.ts";
if (
  !/^http:\/\/(127\.0\.0\.1|localhost):54321$/.test(env.url) ||
  await edgeRuntimeIsUp()
) throw new Error("Disposable local stack without edge-runtime required");
const [mode, conv] = Deno.args;
if (!/^[a-f0-9-]{36}$/.test(conv)) {
  throw new Error("Test conversation UUID required");
}
const client = createClient<Database>(env.url, env.serviceRoleKey, {
  auth: { persistSession: false },
});
const change = (value: Record<string, unknown>, field = "messages") => ({
  object: "whatsapp_business_account",
  entry: [{
    id: fixture.wabaA,
    changes: [{
      field,
      value: {
        messaging_product: "whatsapp",
        metadata: {
          phone_number_id: fixture.waA,
          display_phone_number: "test",
        },
        ...value,
      },
    }],
  }],
});
async function deliver(payload: unknown) {
  const runtime = globalThis as unknown as { EdgeRuntime?: unknown };
  const saved = runtime.EdgeRuntime;
  const pending: Promise<unknown>[] = [];
  runtime.EdgeRuntime = { waitUntil: (p: Promise<unknown>) => pending.push(p) };
  try {
    const response = await webhook(
      await metaRequest(
        "http://localhost/whatsapp-webhook",
        payload,
        env.metaAppSecret,
      ),
    );
    assertEquals(response.status, 200);
    await Promise.all(pending);
  } finally {
    runtime.EdgeRuntime = saved;
  }
}
const request = (record: MessageRow, fn: string) =>
  new Request(`http://localhost/${fn}`, {
    method: "POST",
    headers: { authorization: `Bearer ${env.serviceRoleKey}` },
    body: JSON.stringify({ record }),
  });
const realFetch = globalThis.fetch;
try {
  if (mode === "media") {
    let active = 0, peak = 0, calls = 0;
    const png = decodeBase64(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jm8QAAAAASUVORK5CYII=",
    );
    const wav = new Uint8Array(8044);
    const view = new DataView(wav.buffer);
    for (
      const [offset, word] of [[0, "RIFF"], [8, "WAVE"], [12, "fmt "], [
        36,
        "data",
      ]] as const
    ) wav.set(new TextEncoder().encode(word), offset);
    view.setUint32(4, 8036, true);
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, 1, true);
    view.setUint32(24, 8000, true);
    view.setUint32(28, 8000, true);
    view.setUint16(32, 1, true);
    view.setUint16(34, 8, true);
    view.setUint32(40, 8000, true);
    wav.fill(128, 44);
    const document = new TextEncoder().encode("Controlled document fixture.\n");
    const media = (index: number) =>
      index === 17
        ? { bytes: wav, mime: "audio/wav" }
        : index === 18
        ? { bytes: document, mime: "text/plain" }
        : { bytes: png, mime: "image/png" };
    globalThis.fetch = async (input, init) => {
      const url = input instanceof Request ? input.url : String(input);
      if (
        url.startsWith("https://graph.facebook.com/") ||
        url.startsWith("https://fake-media.local/")
      ) {
        calls++;
        active++;
        peak = Math.max(peak, active);
        try {
          const name = url.split("/").at(-1)!;
          const index = Number(name.split("-").at(-1));
          await new Promise((r) => setTimeout(r, index === 19 ? 500 : 10));
          if (index === 3) {
            return Response.json({
              error: { message: "injected media failure" },
            }, { status: 503 });
          }
          if (url.startsWith("https://graph.facebook.com/")) {
            return Response.json({
              url: `https://fake-media.local/${name}`,
              mime_type: media(index).mime,
              file_size: media(index).bytes.length,
            });
          }
          return new Response(media(index).bytes, {
            headers: { "content-type": media(index).mime },
          });
        } finally {
          active--;
        }
      }
      if (!url.startsWith(env.url)) {
        throw new Error("Unexpected external request blocked by fixture");
      }
      return realFetch(input, init);
    };
    const mediaTimestamp = Math.floor((Date.now() - 30000) / 1000);
    const messages = Array.from({ length: 20 }, (_, i) => {
      const type = i === 17 ? "audio" : i === 18 ? "document" : "image";
      return {
        from: conv,
        id: `wamid.browser.${conv}.${i}`,
        timestamp: mediaTimestamp + i,
        type,
        [type]: {
          id: `media-${i}`,
          mime_type: media(i).mime,
          caption: `media-${i}`,
          ...(type === "document" ? { filename: "fixture.txt" } : {}),
        },
      };
    });
    const payload = change({
      messages: [{
        from: conv,
        id: `wamid.browser.${conv}.text`,
        timestamp: mediaTimestamp - 1,
        type: "text",
        text: { body: "backend text fixture" },
      }, ...messages],
    });
    await deliver(payload);
    await deliver(payload);
    const { data: rows } = await client.from("messages").select().eq(
      "organization_id",
      fixture.orgA,
    ).eq("conversation_id", conv).like("external_id", `wamid.browser.${conv}.%`)
      .throwOnError();
    assertEquals(rows.length, 21);
    assert(peak <= 4);
    assertEquals(
      rows.filter((r) =>
        r.status && typeof r.status === "object" && "error" in r.status
      ).length,
      1,
    );
    console.log(
      "E2E_RESULT " +
        JSON.stringify({
          rows: rows.length,
          peak,
          calls,
          audio: rows.find((r) => r.external_id?.endsWith(".17"))?.id,
          document: rows.find((r) => r.external_id?.endsWith(".18"))?.id,
          failed: rows.find((r) =>
            r.status && typeof r.status === "object" && "error" in r.status
          )?.id,
        }),
    );
  } else if (mode === "attention") {
    const llm = stubLlm(1);
    try {
      await withTestAgent(client, async () => {
        const { data: row } = await client.from("messages").select().eq(
          "conversation_id",
          conv,
        ).not("sender_address", "is", null).order("timestamp", {
          ascending: false,
        }).limit(1).single().throwOnError();
        assertEquals(
          (await agent(request(row as MessageRow, "agent-client"))).status,
          200,
        );
        assertEquals(llm.calls(), 0);
      });
    } finally {
      llm.restore();
    }
    console.log("E2E_RESULT " + JSON.stringify({ llm_calls: 0 }));
  } else if (mode === "attention-lifecycle") {
    const sql = postgres(
      "postgresql://postgres:postgres@127.0.0.1:54322/postgres",
      { max: 1 },
    );
    const org = fixture.orgA;
    const [{ extra }] =
      await sql`select extra from public.organizations where id=${org}`;
    const timeoutText = `controlled human timeout ${conv}`;
    try {
      await sql`update public.organizations set extra=jsonb_build_object('attention',jsonb_build_object('human_assignment_ttl_hours',72,'human_wait_minutes',1,'timezone','UTC','on_human_wait_timeout','notify_customer','human_wait_message',${timeoutText}::text,'business_hours',null)) where id=${org}`;
      await sql`select public.set_conversation_assignment(${conv},${fixture.agentAlice},false,null,'{"cause":"manual"}'::jsonb)`;
      await sql.begin(async (transaction) => {
        // postgres.js omits the transaction call signature in its Deno types.
        const tx = transaction as unknown as typeof sql;
        await tx`select set_config('app.assignment_writer','on',true)`;
        await tx`update public.conversations set assigned_at=now()-interval '4 days' where id=${conv} and organization_id=${org}`;
        await tx`update public.messages set timestamp=now()-interval '4 days' where conversation_id=${conv} and sender_address is null and agent_id=${fixture.agentAlice}`;
      });
      const [{ expiry }] =
        await sql`select public.expire_human_assignments() as expiry`;
      assertEquals(expiry, 1);
      const [{ assigned_agent_id }] =
        await sql`select assigned_agent_id from public.conversations where id=${conv}`;
      assertEquals(assigned_agent_id, null);
      assertEquals(
        (await sql`select public.expire_human_assignments() as n`)[0].n,
        0,
      );
      await sql`select public.set_conversation_assignment(${conv},null,true,${fixture.agentRobotA},'{"cause":"escalation"}'::jsonb)`;
      await sql.begin(async (transaction) => {
        // postgres.js omits the transaction call signature in its Deno types.
        const tx = transaction as unknown as typeof sql;
        await tx`select set_config('app.assignment_writer','on',true)`;
        await tx`update public.conversations set awaiting_human_since=now()-interval '2 minutes' where id=${conv}`;
      });
      await sql`update public.organizations set extra=jsonb_build_object('attention',jsonb_build_object('business_hours',jsonb_build_object('mon','[]'::jsonb,'tue','[]'::jsonb,'wed','[]'::jsonb,'thu','[]'::jsonb,'fri','[]'::jsonb,'sat','[]'::jsonb,'sun','[]'::jsonb))) where id=${org}`;
      const [{ closed }] =
        await sql`select public.sweep_awaiting_human() as closed`;
      assertEquals(closed, 0);
      await sql`update public.organizations set extra='{"attention":{"business_hours":null}}'::jsonb where id=${org}`;
      const [{ notified }] =
        await sql`select public.sweep_awaiting_human() as notified`;
      assertEquals(notified, 1);
      assertEquals(
        (await sql`select public.sweep_awaiting_human() as n`)[0].n,
        0,
      );
      assertEquals(
        (await sql`select count(*)::int as n from public.messages where conversation_id=${conv} and content->>'text'=${timeoutText}`)[
          0
        ].n,
        1,
      );
      console.log(
        "E2E_RESULT " +
          JSON.stringify({
            expiry,
            closed,
            notified,
            timeout_text: timeoutText,
          }),
      );
    } finally {
      await sql.begin(async (transaction) => {
        // postgres.js omits the transaction call signature in its Deno types.
        const tx = transaction as unknown as typeof sql;
        // Restore the exact fixture policy; ordinary writes are JSON merge patches.
        await tx`set local session_replication_role=replica`;
        await tx`update public.organizations set extra=${
          sql.json(extra)
        } where id=${org}`;
      });
      await sql.end();
    }
  } else if (mode === "dispatch") {
    const { data: row } = await client.from("messages").select().eq(
      "conversation_id",
      conv,
    ).is("sender_address", null).is("content->internal", null).order(
      "created_at",
      { ascending: false },
    ).limit(1).single().throwOnError();
    let sends = 0;
    const wamid = `wamid.browser.out.${row.id}`;
    globalThis.fetch = (input, init) => {
      const url = input instanceof Request ? input.url : String(input);
      if (
        url.startsWith("https://graph.facebook.com/") &&
        url.endsWith("/messages")
      ) {
        sends++;
        return Promise.resolve(
          sends === 1
            ? Response.json({
              error: { code: 130429, message: "fixture rate limit" },
            }, { status: 429 })
            : Response.json({ messages: [{ id: wamid }] }),
        );
      }
      if (!url.startsWith(env.url)) {
        throw new Error("Unexpected external request blocked by fixture");
      }
      return realFetch(input, init);
    };
    await dispatch(request(row as MessageRow, "whatsapp-dispatcher")).catch(
      () => {},
    );
    const { data: failed } = await client.from("messages").select().eq(
      "id",
      row.id,
    ).single().throwOnError();
    assert((failed.status as Record<string, unknown>).pending);
    assertEquals((failed.status as Record<string, unknown>).attempts, 1);
    // Controlled expired lease; ordinary sweep replays the same row, no fresh send.
    await client.from("messages").update({
      status: {
        dispatching: new Date(0).toISOString(),
        retry_at: new Date(0).toISOString(),
      },
    }).eq("id", row.id).throwOnError();
    assertEquals(
      (await dispatch(request(row as MessageRow, "whatsapp-dispatcher")))
        .status,
      200,
    );
    await deliver(
      change({
        statuses: [{
          id: wamid,
          status: "delivered",
          timestamp: String(Math.floor(Date.now() / 1000)),
          recipient_id: conv,
        }],
      }),
    );
    await deliver(
      change({
        message_echoes: [{
          from: fixture.waA,
          to: conv,
          id: wamid,
          timestamp: Math.floor(Date.now() / 1000),
          type: "text",
          text: { body: (row.content as { text: string }).text },
        }],
      }, "smb_message_echoes"),
    );
    const { data: rows } = await client.from("messages").select().eq(
      "organization_id",
      fixture.orgA,
    ).eq("external_id", wamid).throwOnError();
    assertEquals(rows.length, 1);
    assertEquals(rows[0].id, row.id);
    assert((rows[0].status as Record<string, unknown>).delivered);
    console.log(
      "E2E_RESULT " +
        JSON.stringify({
          sends,
          message_id: row.id,
          rows: rows.length,
          status: rows[0].status,
        }),
    );
  } else throw new Error("Unknown fixture mode");
} finally {
  globalThis.fetch = realFetch;
}
