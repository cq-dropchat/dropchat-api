import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../_shared/types/database_types.ts";
import * as log from "../_shared/logger.ts";
import type { ConversationRow, MessageRow } from "../_shared/supabase.ts";
import { renewAgentTurn } from "../_shared/agent_turns.ts";
import type { AgentRowWithExtra } from "./protocols/base.ts";

/**
 * Marks the incoming message read and typing, and keeps it alive every 30 s
 * together with the agent turn's lease. The caller clears the interval.
 */
export function startTyping(
  client: SupabaseClient<Database>,
  conv: ConversationRow,
  agent: AgentRowWithExtra,
  incoming: MessageRow,
): ReturnType<typeof setInterval> {
  const indicateTyping = async (unread?: boolean) => {
    const ts = new Date().toISOString();

    const { error: typingIndicatorError } = await client
      .from("messages")
      .update({
        status: {
          // In team chat a read belongs to ONE member, so it is a map keyed
          // by the reader (the AI's agent id); outside it stays the scalar
          // receipt the peer's service understands.
          ...(unread && {
            read: conv.service === "local" ? { [agent.id]: ts } : ts,
          }),
          typing: ts,
        },
      })
      .eq("id", incoming.id);

    if (typingIndicatorError) {
      log.warn(
        "Failed to update incoming message typing indicator status.",
        typingIndicatorError,
      );
    }
  };

  indicateTyping(true);

  // The typing indicator will be dismissed once an agent respond,
  // or after 25 seconds. Hence, keep it alive. Some extra delay
  // is added to avoid race conditions with the response.
  //
  // The same keep-alive renews the turn's 90-second lease, which a single
  // LLM call with its retries can outlast.
  return setInterval(() => {
    indicateTyping();
    renewAgentTurn(client, incoming).catch((renewError) =>
      log.warn("Failed to renew the agent turn.", renewError)
    );
  }, 30000);
}
