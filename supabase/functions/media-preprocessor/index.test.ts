// F12 — media-preprocessor marked `status.preprocessing` but never checked
// it: two invocations for one message (the queue retrying an attempt whose
// response was lost, next to the `preprocess-pending-messages` sweep) both
// downloaded the file and both called Gemini. Now the first claims the
// message; a second one while it runs, or after it finished, does nothing.
//
// Runs against a local Supabase (Storage included) with
// supabase/tests/fixtures loaded: organization A has media preprocessing
// active with its own (fake) key. Gemini is stubbed.
import "../_shared/testing/env.ts"; // before index.ts: keys are read at import
import { assert, assertEquals } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import type { Database, MessageRow } from "../_shared/types/database_types.ts";
import { env, fixture, supabaseIsUp } from "../_shared/testing/env.ts";
import { handler } from "./index.ts";

const up = await supabaseIsUp();

function service() {
  return createClient<Database>(env.url, env.serviceRoleKey, {
    auth: { persistSession: false },
  });
}

function stubGemini(respond: () => Response, latencyMs = 200) {
  const realFetch = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async (input, init) => {
    const url = input instanceof Request ? input.url : String(input);
    if (url.startsWith("https://generativelanguage.googleapis.com/")) {
      calls++;
      await new Promise((r) => setTimeout(r, latencyMs));
      return respond();
    }
    return realFetch(input, init);
  };
  return { calls: () => calls, restore: () => (globalThis.fetch = realFetch) };
}

const DESCRIBED = () =>
  Response.json({
    responseId: `f12-${crypto.randomUUID()}`,
    candidates: [{
      content: {
        role: "model",
        parts: [{
          text: JSON.stringify({ description: "una foto de prueba" }),
        }],
      },
      finishReason: "STOP",
    }],
    usageMetadata: {
      promptTokenCount: 10,
      candidatesTokenCount: 5,
      totalTokenCount: 15,
    },
  });

function request(record: MessageRow) {
  return new Request("http://localhost/media-preprocessor", {
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

async function withImageMessage(
  fn: (
    client: ReturnType<typeof service>,
    message: MessageRow,
  ) => Promise<void>,
) {
  const client = service();
  const name =
    `organizations/${fixture.orgA}/attachments/f12-mp-${crypto.randomUUID()}`;
  const { error } = await client.storage
    .from("media")
    .upload(
      name,
      new Blob([new Uint8Array([0xff, 0xd8, 0xff, 0xd9])], {
        type: "image/jpeg",
      }),
    );
  if (error) throw error;

  const { data } = await client
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
          uri: `internal://media/${name}`,
          mime_type: "image/jpeg",
          size: 4,
        },
      },
      status: { pending: new Date().toISOString() },
    })
    .select()
    .single()
    .throwOnError();

  try {
    await fn(client, data as MessageRow);
  } finally {
    await client.from("edge_calls").delete().eq("record_id", data.id);
    await client.from("messages").delete().eq("id", data.id);
    await client.storage.from("media").remove([name]);
  }
}

Deno.test({
  name:
    "F12: media-preprocessor invoked twice for one message preprocesses it once",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  fn: () =>
    withImageMessage(async (client, message) => {
      const gemini = stubGemini(DESCRIBED);
      try {
        const [first, second] = await Promise.all([
          handler(request(message)),
          handler(request(message)),
        ]);
        assertEquals([first.status, second.status], [200, 200]);
        assertEquals(gemini.calls(), 1, "Gemini was called twice");

        // And once it is done, a late retry does nothing either.
        await handler(request(message));
        assertEquals(gemini.calls(), 1);

        const { data } = await client
          .from("messages")
          .select("content, status")
          .eq("id", message.id)
          .single()
          .throwOnError();
        assert((data.status as Record<string, unknown>).preprocessed);
        assertEquals(
          (data.content as { artifacts?: unknown[] }).artifacts?.length,
          1,
        );
      } finally {
        gemini.restore();
      }
    }),
});

Deno.test({
  name:
    "F12: a transient Gemini error releases the claim so the queue's retry runs",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  fn: () =>
    withImageMessage(async (client, message) => {
      let gemini = stubGemini(
        () =>
          Response.json({
            error: { code: 503, message: "overloaded", status: "UNAVAILABLE" },
          }, { status: 503 }),
        0,
      );
      try {
        const failed = await handler(request(message)).catch(() => null);
        assertEquals(failed, null, "a retryable error must fail the call");
      } finally {
        gemini.restore();
      }

      gemini = stubGemini(DESCRIBED, 0);
      try {
        await handler(request(message));
        assert(gemini.calls() >= 1, "the retry was skipped");
        const { data } = await client
          .from("messages")
          .select("status")
          .eq("id", message.id)
          .single()
          .throwOnError();
        assert((data.status as Record<string, unknown>).preprocessed);
      } finally {
        gemini.restore();
      }
    }),
});
