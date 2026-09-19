import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../_shared/types/database_types.ts";
import {
  type ConversationRow,
  isInternal,
  type MessageRow,
  type TextPart,
} from "../_shared/supabase.ts";
import type { AgentRowWithExtra } from "./protocols/base.ts";

const MESSAGES_TIME_LIMIT = 7 * 24 * 60 * 60 * 1000; // 7 days
const MESSAGES_QUANTITY_LIMIT = 50;

/**
 * timestamp vs created_at
 *
 *  - timestamp is given by the service (i.e. WhatsApp) servers.
 *  - created_at is the insertion timestamp in our database.
 *
 *  The contact might send several messages very close in time. The goal is to react
 *  once for the whole batch. Each message will trigger a function. Only one of them
 *  should go through. The selection criteria is the function corresponding to the
 *  newest message by created_at.
 *
 *  The newest message might not be the one with the latest timestamp. The order of
 *  arrival is not guaranteed. Anyway, messages are ordered by timestamp, hence the
 *  agent will get the conversation history in the correct order.
 */

/**
 * Authorship. `sender_address` is a contact reference: set when the peer
 * authored the row, null when the account itself did. `content.internal`
 * marks record-only rows (tool traces, agent errors), which are recorded but
 * never spoken.
 *
 * These two are the CONTACT-space predicates. In a local DM the peer lives in
 * member space instead — see `fromPeer` in the handler, which picks the space
 * by service.
 */
export const fromContact = (m: { sender_address: string | null }) =>
  m.sender_address !== null;

export const spokenByUs = (
  m: { sender_address: string | null; content: unknown },
) => m.sender_address === null && !isInternal(m);

export function getNewestIncomingMessage(
  incoming: MessageRow,
  messages: MessageRow[],
  fromPeer: (m: MessageRow) => boolean,
): MessageRow {
  const incomingCreatedAt = new Date(incoming.created_at);

  const sortedMessages = messages
    .filter(fromPeer)
    .filter((m) => new Date(m.created_at) >= incomingCreatedAt)
    .sort((a, b) => {
      const dateA = +new Date(a.created_at);
      const dateB = +new Date(b.created_at);

      if (dateA !== dateB) {
        return dateB - dateA; // descending by created_at
      }

      // If created_at is the same, order by id descending
      if (a.id < b.id) return 1;
      if (a.id > b.id) return -1;
      return 0;
    });

  // P1: the incoming row is the message this invocation was woken for, so it
  // is the newest by definition — even when the window came back without it
  // (a clock skew used to make that `undefined`, and the caller crashed on
  // `.id`). Anything the window does carry still wins on its own merits.
  return sortedMessages[0] ?? incoming;
}

/**
 * The window's upper bound: scheduled messages must stay out, and the
 * incoming one must stay in.
 *
 * P1: `timestamp` is stamped by the DATABASE (`now()`), and this process has
 * its own clock. With the database ahead, `now()` here was already past —
 * from the row's point of view — and the very message that woke this
 * invocation read as "scheduled": it fell out of its own context window. The
 * ceiling is therefore the later of the two instants, and the incoming row's
 * string is used verbatim so its microseconds are not truncated below itself.
 */
function windowCeiling(incoming: MessageRow): string {
  const now = new Date().toISOString();

  return +new Date(incoming.timestamp) >= +new Date(now)
    ? incoming.timestamp
    : now;
}

/** The context window: up to 50 v1 messages of the last 7 days, oldest first. */
export async function loadRecentMessages(
  client: SupabaseClient<Database>,
  incoming: MessageRow,
): Promise<MessageRow[]> {
  const { data: messagesMixedVersions } = await client
    .from("messages")
    .select()
    .eq("conversation_id", incoming.conversation_id)
    // H1: assignment notes are a record of who answers, addressed to the
    // people reading the chat — not something the model should read as a
    // turn. Filtered in the query so both protocols get the same history.
    .not("content->>kind", "eq", "assignment")
    .gt(
      "timestamp",
      new Date(+new Date() - MESSAGES_TIME_LIMIT).toISOString(),
    ) // Time constraint for the conversation.
    .lte("timestamp", windowCeiling(incoming)) // Scheduled messages have a future timestamp.
    .order("timestamp", { ascending: false })
    .limit(MESSAGES_QUANTITY_LIMIT) // Size constraint for the conversation.
    .throwOnError();

  // v0 is out of support: rows that predate the v1 content schema are
  // simply not part of the context window any more.
  const messages = messagesMixedVersions
    .filter((m) => m.content.version === "1") as MessageRow[];

  // Query was done in descending order to apply the limit.
  // We need the messages in chronological order, though.
  messages.reverse();

  return messages;
}

/**
 * SESSION RESTART if /new is found — USEFUL FOR WHATSAPP TESTING. Drops the
 * window before the newest `/new` and resets the conversation's memory.
 */
export async function restartSessionIfAsked(
  client: SupabaseClient<Database>,
  conv: ConversationRow,
  incoming: MessageRow,
  messages: MessageRow[],
  fromPeer: (m: MessageRow) => boolean,
): Promise<void> {
  // content.text may be absent despite type === "text": legacy whatsapp-web
  // bridge builds emitted reactions as a TextPart with no text at all. One
  // such row in the window crashed this scan — and with it every later
  // inbound message of the conversation.
  const firstMessageIndex = messages.findLastIndex(
    (m) =>
      fromPeer(m) &&
      m.content.type === "text" &&
      typeof m.content.text === "string" &&
      m.content.text.startsWith("/new"),
  );

  if (firstMessageIndex > -1) {
    const firstMessage = messages[firstMessageIndex].content as TextPart;

    firstMessage.text = firstMessage.text.replace("/new", "");

    messages.splice(0, firstMessageIndex);

    // Also, reset the conversation memory
    // The handler set `conv.extra` to {} when it was null; the same object is
    // in the request context, so the reset is seen there too.
    const extra = conv.extra!;

    if (extra.memory && Object.keys(extra.memory).length) {
      extra.memory = {};

      await client
        .from("conversations")
        .update({ extra })
        .eq("id", incoming.conversation_id)
        .throwOnError();
    }
  }
}

/**
 * A peer message newer than the one being answered, whose own invocation
 * has not registered yet. The fromPeer predicate, as database filters.
 */
export async function findNewerPeerMessage(
  client: SupabaseClient<Database>,
  conv: ConversationRow,
  agent: AgentRowWithExtra,
  incoming: MessageRow,
): Promise<MessageRow | null> {
  const newerQuery = client
    .from("messages")
    .select()
    .eq("conversation_id", incoming.conversation_id)
    .gt("created_at", incoming.created_at);

  // The fromPeer predicate, expressed as filters the database can apply.
  if (conv.service === "local") {
    newerQuery
      .not("agent_id", "is", null)
      .neq("agent_id", agent.id)
      .is("content->internal", null);
  } else {
    newerQuery.not("sender_address", "is", null);
  }

  const { data: new_message } = await newerQuery
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle()
    .throwOnError();

  return new_message as MessageRow | null;
}
