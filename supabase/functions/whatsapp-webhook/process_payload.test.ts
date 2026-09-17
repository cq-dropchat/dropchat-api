// F29 (step 3) — characterization of whatsapp-webhook's processPayload,
// written before splitting index.ts (1,275 lines) into modules.
//
// It drives every branch the split moves — each message type the mapper
// knows, live/echo/history edits and revokes, statuses, errors at three
// levels, media downloads (one of them failing), state sync, user_id_update
// and account_update — and snapshots what lands in the database. The split
// must leave the snapshot unchanged.
//
// Runs against a local Supabase with supabase/tests/fixtures loaded. The
// Graph API is stubbed. Regenerate only for an intended change:
//   deno test -A whatsapp-webhook/process_payload.test.ts -- --update
import "../_shared/testing/env.ts"; // before index.ts: keys are read at import
import { assertSnapshot } from "jsr:@std/testing@1/snapshot";
import { createClient } from "@supabase/supabase-js";
import type { Database, MetaWebhookPayload } from "../_shared/supabase.ts";
import { env, fixture, supabaseIsUp } from "../_shared/testing/env.ts";
import { processPayload } from "./index.ts";

const up = await supabaseIsUp();

const T = 1757000000; // payload timestamps: 2025-09-04
const C1 = "5491129000001"; // contacts written by this test only
const C2 = "5491129000002";
const C3 = "5491129000003";

function stubGraph() {
  const realFetch = globalThis.fetch;
  globalThis.fetch = (input, init) => {
    const url = input instanceof Request ? input.url : String(input);
    if (url.startsWith("https://graph.facebook.com/")) {
      const id = url.split("/").pop()!;
      if (id === "F29MEDIA404") {
        return Promise.resolve(
          Response.json({ error: { code: 100 } }, { status: 404 }),
        );
      }
      return Promise.resolve(Response.json({
        messaging_product: "whatsapp",
        url:
          `https://lookaside.fbsbx.com/whatsapp_business/attachments/?mid=${id}`,
        mime_type: "application/octet-stream",
        sha256: "0".repeat(64),
        file_size: 12,
        id,
      }));
    }
    if (url.startsWith("https://lookaside.fbsbx.com/")) {
      const mid = new URL(url).searchParams.get("mid")!;
      return Promise.resolve(
        new Response(new TextEncoder().encode(`F29-${mid}`.padEnd(12))),
      );
    }
    return realFetch(input, init);
  };
  return () => (globalThis.fetch = realFetch);
}

const metadata = {
  display_phone_number: "5491100000001",
  phone_number_id: fixture.waA,
};

const at = (i: number) => String(T + i);

function change(field: string, value: Record<string, unknown>) {
  return { field, value: { messaging_product: "whatsapp", ...value } };
}

function payload(...changes: unknown[]) {
  return {
    object: "whatsapp_business_account",
    entry: [{ id: fixture.wabaA, changes }],
  } as unknown as MetaWebhookPayload;
}

const LIVE = payload(
  change("messages", {
    metadata,
    contacts: [
      { profile: { name: "Uno" }, wa_id: C1, user_id: "AR.F29.1" },
      { profile: { name: "Dos", username: "dos" }, user_id: "AR.F29.2" },
    ],
    messages: [
      {
        from: C1,
        from_user_id: "AR.F29.1",
        id: "wamid.F29.text",
        timestamp: at(1),
        type: "text",
        text: { body: "*hola* ~mundo~" },
      },
      {
        from: C1,
        from_user_id: "AR.F29.1",
        id: "wamid.F29.reply",
        timestamp: at(2),
        type: "text",
        text: { body: "respuesta" },
        context: { id: "wamid.F29.text", forwarded: true },
      },
      {
        from: C1,
        from_user_id: "AR.F29.1",
        id: "wamid.F29.react",
        timestamp: at(3),
        type: "reaction",
        reaction: { message_id: "wamid.F29.text", emoji: "👍" },
      },
      {
        from: C1,
        from_user_id: "AR.F29.1",
        id: "wamid.F29.unreact",
        timestamp: at(4),
        type: "reaction",
        reaction: { message_id: "wamid.F29.text" },
      },
      {
        from: C1,
        from_user_id: "AR.F29.1",
        id: "wamid.F29.image",
        timestamp: at(5),
        type: "image",
        image: {
          id: "F29IMAGE",
          mime_type: "image/jpeg",
          sha256: "x",
          caption: "_foto_",
        },
      },
      {
        from: C1,
        from_user_id: "AR.F29.1",
        id: "wamid.F29.audio",
        timestamp: at(6),
        type: "audio",
        audio: {
          id: "F29AUDIO",
          mime_type: "audio/ogg; codecs=opus",
          voice: true,
        },
      },
      {
        from: C1,
        from_user_id: "AR.F29.1",
        id: "wamid.F29.video",
        timestamp: at(7),
        type: "video",
        video: {
          id: "F29VIDEO",
          mime_type: "video/mp4",
          sha256: "x",
          filename: "v.mp4",
        },
      },
      {
        from: C1,
        from_user_id: "AR.F29.1",
        id: "wamid.F29.document",
        timestamp: at(8),
        type: "document",
        document: {
          id: "F29MEDIA404",
          mime_type: "application/pdf",
          sha256: "x",
          filename: "f.pdf",
          caption: "doc",
        },
      },
      {
        from: C1,
        from_user_id: "AR.F29.1",
        id: "wamid.F29.sticker",
        timestamp: at(9),
        type: "sticker",
        sticker: {
          id: "F29STICKER",
          mime_type: "image/webp",
          sha256: "x",
          animated: false,
        },
      },
      {
        from: C1,
        from_user_id: "AR.F29.1",
        id: "wamid.F29.location",
        timestamp: at(10),
        type: "location",
        location: {
          address: "Calle 1",
          name: "Casa",
          latitude: -34.6,
          longitude: -58.4,
        },
      },
      {
        from: C1,
        from_user_id: "AR.F29.1",
        id: "wamid.F29.contacts",
        timestamp: at(11),
        type: "contacts",
        contacts: [{
          name: { formatted_name: "Ana" },
          phones: [{ phone: "+54 9 11", type: "CELL" }],
        }],
      },
      {
        from: C1,
        from_user_id: "AR.F29.1",
        id: "wamid.F29.interactive",
        timestamp: at(12),
        type: "interactive",
        interactive: {
          type: "button_reply",
          button_reply: { id: "b1", title: "Sí" },
        },
      },
      {
        from: C1,
        from_user_id: "AR.F29.1",
        id: "wamid.F29.button",
        timestamp: at(13),
        type: "button",
        button: { text: "Ok", payload: "ok" },
      },
      {
        from: C1,
        from_user_id: "AR.F29.1",
        id: "wamid.F29.order",
        timestamp: at(14),
        type: "order",
        order: { catalog_id: "c", product_items: [] },
      },
      {
        from: C1,
        from_user_id: "AR.F29.1",
        id: "wamid.F29.placeholder",
        timestamp: at(15),
        type: "media_placeholder",
      },
      {
        from: C1,
        from_user_id: "AR.F29.1",
        id: "wamid.F29.unsupported",
        timestamp: at(16),
        type: "unsupported",
        unsupported: { type: "poll" },
        errors: [{
          code: 131051,
          title: "Unsupported",
          message: "Unsupported",
          error_data: { details: "poll" },
        }],
      },
      {
        from: C1,
        from_user_id: "AR.F29.1",
        id: "wamid.F29.system",
        timestamp: at(17),
        type: "system",
        system: { body: "changed", type: "user_changed_number" },
      },
      {
        from: C1,
        from_user_id: "AR.F29.1",
        id: "wamid.F29.errors",
        timestamp: at(18),
        type: "errors",
        errors: [{
          code: 131051,
          title: "Unsupported message type",
          message: "Unsupported message type",
          error_data: { details: "x" },
        }],
      },
      {
        from_user_id: "AR.F29.2",
        id: "wamid.F29.bsuid",
        timestamp: at(19),
        type: "text",
        text: { body: "sin teléfono" },
      },
      {
        from: C1,
        from_user_id: "AR.F29.1",
        id: "wamid.F29.edit",
        timestamp: at(20),
        type: "edit",
        edit: {
          original_message_id: "wamid.F29.text",
          message: { type: "text", text: { body: "hola editado" } },
        },
      },
      {
        from: C1,
        from_user_id: "AR.F29.1",
        id: "wamid.F29.edit.unsupported",
        timestamp: at(21),
        type: "edit",
        edit: {
          original_message_id: "wamid.F29.text",
          message: { type: "sticker", sticker: {} },
        },
      },
      {
        from: C1,
        from_user_id: "AR.F29.1",
        id: "wamid.F29.revoke",
        timestamp: at(22),
        type: "revoke",
        revoke: { original_message_id: "wamid.F29.reply" },
      },
    ],
  }),
  change("messages", {
    metadata,
    statuses: [
      {
        id: "wamid.F29.out.status",
        status: "delivered",
        timestamp: at(30),
        recipient_id: C1,
      },
      {
        id: "wamid.F29.out.failed",
        status: "failed",
        timestamp: at(31),
        recipient_user_id: "AR.F29.2",
        errors: [{
          code: 131026,
          title: "Undeliverable",
          message: "Undeliverable",
          error_data: { details: "x" },
        }],
      },
    ],
  }),
  change("messages", {
    metadata,
    errors: [{
      code: 131000,
      title: "Something went wrong",
      message: "Something went wrong",
      error_data: { details: "x" },
    }],
  }),
  change("smb_message_echoes", {
    metadata,
    message_echoes: [
      {
        from: "5491100000001",
        to: C1,
        to_user_id: "AR.F29.1",
        id: "wamid.F29.echo",
        timestamp: at(40),
        type: "text",
        text: { body: "desde la app" },
      },
      {
        from: "5491100000001",
        to: C1,
        to_user_id: "AR.F29.1",
        id: "wamid.F29.echo.edit",
        timestamp: at(41),
        type: "edit",
        edit: {
          original_message_id: "wamid.F29.echo",
          message: { type: "text", text: { body: "desde la app, editado" } },
        },
      },
      {
        from: "5491100000001",
        to: C1,
        to_user_id: "AR.F29.1",
        id: "wamid.F29.echo.errors",
        timestamp: at(42),
        type: "errors",
        errors: [{
          code: 131051,
          title: "Unsupported message type",
          message: "Unsupported message type",
          error_data: { details: "x" },
        }],
      },
    ],
  }),
  change("history", {
    metadata,
    history: [
      {
        metadata: { phase: 0, chunk_order: 1, progress: 100 },
        threads: [{
          id: C2,
          context: { wa_id: C2, user_id: "AR.F29.3", username: "tres" },
          messages: [
            {
              from: C2,
              from_user_id: "AR.F29.3",
              id: "wamid.F29.hist.in",
              timestamp: at(50),
              type: "text",
              text: { body: "viejo" },
              history_context: { status: "READ" },
            },
            {
              from: "5491100000001",
              to: C2,
              to_user_id: "AR.F29.3",
              id: "wamid.F29.hist.out",
              timestamp: at(51),
              type: "text",
              text: { body: "respuesta vieja" },
              history_context: { status: "PLAYED" },
            },
            {
              from: "5491100000001",
              to: C2,
              to_user_id: "AR.F29.3",
              id: "wamid.F29.hist.pending",
              timestamp: at(52),
              type: "text",
              text: { body: "pendiente" },
              history_context: { status: "PENDING" },
            },
            {
              from: C2,
              from_user_id: "AR.F29.3",
              id: "wamid.F29.hist.edit",
              timestamp: at(53),
              type: "edit",
              edit: {
                original_message_id: "wamid.F29.hist.in",
                message: { type: "text", text: { body: "viejo editado" } },
              },
              history_context: { status: "READ" },
            },
            {
              from: C2,
              from_user_id: "AR.F29.3",
              id: "wamid.F29.hist.revoke",
              timestamp: at(54),
              type: "revoke",
              revoke: { original_message_id: "wamid.F29.hist.out" },
              history_context: { status: "READ" },
            },
            {
              from: C2,
              from_user_id: "AR.F29.3",
              id: "wamid.F29.hist.errors",
              timestamp: at(55),
              type: "errors",
              errors: [{
                code: 131051,
                title: "Unsupported message type",
                message: "Unsupported message type",
                error_data: { details: "x" },
              }],
              history_context: { status: "ERROR" },
            },
          ],
        }],
      },
      {
        errors: [{
          code: 2593107,
          title: "History sync declined",
          message: "History sync declined",
          error_data: { details: "x" },
        }],
      },
    ],
  }),
  change("history", {
    metadata,
    message_echoes: [
      {
        from: "5491100000001",
        to: C2,
        to_user_id: "AR.F29.3",
        id: "wamid.F29.hist.echo",
        timestamp: at(56),
        type: "text",
        text: { body: "eco del historial" },
      },
    ],
  }),
  change("smb_app_state_sync", {
    metadata,
    state_sync: [
      {
        type: "contact",
        contact: {
          full_name: "Contacto Tres",
          first_name: "Contacto",
          phone_number: C3,
          user_id: "AR.F29.4",
        },
        action: "add",
        metadata: { timestamp: at(60) },
      },
      {
        type: "contact",
        contact: {
          full_name: "Sin Teléfono",
          first_name: "Sin",
          user_id: "AR.F29.5",
          username: "sintel",
        },
        action: "remove",
        metadata: { timestamp: at(61) },
      },
    ],
  }),
  // Not in orgAddressMap: skipped with a warning.
  change("messages", {
    metadata: { display_phone_number: "0", phone_number_id: "999999999999998" },
    messages: [{
      from: C1,
      from_user_id: "AR.F29.1",
      id: "wamid.F29.unknown.account",
      timestamp: at(70),
      type: "text",
      text: { body: "x" },
    }],
  }),
  change("account_update", {
    event: "PARTNER_APP_INSTALLED",
    waba_info: {
      waba_id: fixture.wabaA,
      owner_business_id: "1",
      partner_app_id: "2",
    },
  }),
  change("account_update", { event: "ACCOUNT_RECONNECTED" }),
);

const BSUID_CHANGE = payload(
  change("user_id_update", {
    metadata,
    user_id_update: [{
      wa_id: C1,
      detail: "user id changed",
      user_id: { previous: "AR.F29.1", current: "AR.F29.1b" },
      timestamp: at(80),
    }],
  }),
);

/** Replaces values that depend on when the test ran, not on the payload. */
function stable(value: unknown, since: number): unknown {
  if (typeof value === "string") {
    if (/^\d{4}-\d{2}-\d{2}T/.test(value) && Date.parse(value) >= since) {
      return "<now>";
    }
    return value;
  }
  if (Array.isArray(value)) return value.map((v) => stable(v, since));
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([k, v]) => [k, stable(v, since)]),
    );
  }
  return value;
}

Deno.test({
  name:
    "F29: processPayload writes the same rows for every branch (characterization)",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn(t) {
    const client = createClient<Database>(env.url, env.serviceRoleKey, {
      auth: { persistSession: false },
    });
    const since = Date.now() - 1000;
    const sinceIso = new Date(since).toISOString();
    const restore = stubGraph();
    const quiet = {
      log: console.log,
      warn: console.warn,
      error: console.error,
    };
    console.log = console.warn = console.error = () => {};

    try {
      await processPayload(client, LIVE);
      await processPayload(client, BSUID_CHANGE);

      const { data: messages } = await client
        .from("messages")
        .select(
          "external_id, service, organization_address, conversation_address, sender_address, content, status, timestamp",
        )
        .eq("organization_id", fixture.orgA)
        .like("external_id", "wamid.F29.%")
        .order("external_id")
        .throwOnError();

      const { data: contacts } = await client
        .from("contacts_addresses")
        .select("organization_address, service, address, status, extra")
        .eq("organization_id", fixture.orgA)
        .like("address", "5491129%")
        .order("address")
        .throwOnError();

      const { data: bsuidContacts } = await client
        .from("contacts_addresses")
        .select("organization_address, service, address, status, extra")
        .eq("organization_id", fixture.orgA)
        .like("address", "AR.F29.%")
        .order("address")
        .throwOnError();

      const { data: logs } = await client
        .from("logs")
        .select(
          "organization_address, service, category, level, message, metadata",
        )
        .eq("organization_id", fixture.orgA)
        .gte("created_at", sinceIso)
        .order("category")
        .order("message")
        .throwOnError();

      const { data: account } = await client
        .from("organizations_addresses")
        .select("status")
        .eq("organization_id", fixture.orgA)
        .eq("address", fixture.waA)
        .single()
        .throwOnError();

      await assertSnapshot(
        t,
        stable(
          { messages, contacts, bsuidContacts, logs, account },
          since,
        ),
      );
    } finally {
      Object.assign(console, quiet);
      restore();
      await client.from("messages").delete().eq("organization_id", fixture.orgA)
        .like("external_id", "wamid.F29.%");
      for (const prefix of ["5491129%", "AR.F29.%"]) {
        await client.from("conversations").delete().eq(
          "organization_id",
          fixture.orgA,
        ).like("address", prefix);
        await client.from("contacts_addresses").delete().eq(
          "organization_id",
          fixture.orgA,
        ).like("address", prefix);
      }
      await client.from("logs").delete().eq("organization_id", fixture.orgA)
        .gte("created_at", sinceIso);
    }
  },
});
