// P1 — the context window is bounded by the FUNCTION's clock
// (`timestamp <= now()`, to leave scheduled messages out), but the row's
// `timestamp` is the DATABASE's `now()`. When the database clock runs ahead,
// the very row that triggered the invocation falls outside the window;
// `getNewestIncomingMessage` then filtered a list that no longer contained
// it, returned `undefined`, and the handler crashed on `newestMessage.id`
// (TypeError, 500, no answer for the contact).
//
// Pure test: no database, no network.
import { assertEquals } from "jsr:@std/assert@1";
import type { MessageRow } from "../_shared/types/database_types.ts";
import { fromContact, getNewestIncomingMessage } from "./conversation.ts";

/** Only the fields these functions read; the rest is not part of the case. */
function message(
  id: string,
  createdAt: string,
  senderAddress: string | null = "5491100000102",
): MessageRow {
  return {
    id,
    created_at: createdAt,
    timestamp: createdAt,
    sender_address: senderAddress,
    content: { version: "1", type: "text", kind: "text", text: id },
  } as unknown as MessageRow;
}

const INCOMING = message("m-incoming", "2026-09-17T12:00:00.000Z");

Deno.test("P1: the incoming message is the newest when the window missed it", () => {
  // The database clock ran ahead: the window ends before the incoming row's
  // timestamp, so `loadRecentMessages` returned the history without it.
  const window = [
    message("m-older-1", "2026-09-17T11:58:00.000Z"),
    message("m-older-2", "2026-09-17T11:59:30.000Z"),
  ];

  const newest = getNewestIncomingMessage(INCOMING, window, fromContact);

  assertEquals(newest?.id, INCOMING.id);
});

Deno.test("P1: an empty window still answers with the incoming message", () => {
  const newest = getNewestIncomingMessage(INCOMING, [], fromContact);

  assertEquals(newest?.id, INCOMING.id);
});

Deno.test("P1: a newer peer message still wins over the incoming one", () => {
  // The skew fix must not swallow the F16 debounce: when the window does
  // carry a newer peer message, that one is the newest.
  const window = [
    message("m-older", "2026-09-17T11:59:30.000Z"),
    INCOMING,
    message("m-newer", "2026-09-17T12:00:02.000Z"),
  ];

  const newest = getNewestIncomingMessage(INCOMING, window, fromContact);

  assertEquals(newest?.id, "m-newer");
});

Deno.test("P1: our own messages never win, skewed window or not", () => {
  // Same created_at as the incoming row: the id tiebreaker would pick it if
  // the peer filter did not drop it first.
  const window = [
    message("m-zzz-ours", "2026-09-17T12:00:01.000Z", null),
  ];

  const newest = getNewestIncomingMessage(INCOMING, window, fromContact);

  assertEquals(newest?.id, INCOMING.id);
});

Deno.test("agent reads include tenant and a stable keyset/order", async () => {
  const { createClient } = await import("@supabase/supabase-js");
  const { loadRecentMessages, findNewerPeerMessage } = await import(
    "./conversation.ts"
  );
  const requests: URL[] = [];
  const client = createClient("http://localhost:54321", "test", {
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
    auth: { persistSession: false },
  });
  const incoming = {
    ...INCOMING,
    id: "aaaaaaaa-0000-4000-8000-000000000001",
    organization_id: "org-a",
    conversation_id: "conv-a",
  };
  await loadRecentMessages(client, incoming);
  await findNewerPeerMessage(
    client,
    { service: "whatsapp" } as Parameters<typeof findNewerPeerMessage>[1],
    {} as Parameters<typeof findNewerPeerMessage>[2],
    incoming,
  );
  assertEquals(requests.map((url) => url.searchParams.get("organization_id")), [
    "eq.org-a",
    "eq.org-a",
  ]);
  assertEquals(requests[0].searchParams.get("order"), "timestamp.desc,id.desc");
  assertEquals(requests[1].searchParams.get("order"), "created_at.asc,id.asc");
  assertEquals(
    requests[1].searchParams.get("or"),
    `(created_at.gt."${incoming.created_at}",and(created_at.eq."${incoming.created_at}",id.gt.${incoming.id}))`,
  );
});
