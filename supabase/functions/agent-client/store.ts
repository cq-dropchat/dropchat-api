import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../_shared/types/database_types.ts";
import * as log from "../_shared/logger.ts";
import {
  type ConversationRow,
  isInternal,
  type MessageInsert,
  type MessageRow,
} from "../_shared/supabase.ts";
import type { AgentRowWithExtra, ResponseContext } from "./protocols/base.ts";

/** An iteration that failed leaves a record-only error row, never spoken. */
export function agentErrorMessages(
  conv: ConversationRow,
  organization_id: string,
  agent: AgentRowWithExtra,
  error: unknown,
): MessageInsert[] {
  return [
    {
      organization_id,
      service: conv.service,
      organization_address: conv.organization_address,
      conversation_address: conv.address,
      // Agent errors are record-only: OpenBSP is a communication layer,
      // and internal rows never dispatch — errors are never spoken to
      // the end user.
      agent_id: agent.id,
      content: {
        version: "1" as const,
        // The declared record-only marker — this is the row that had no
        // other way to say it (an error carries no `tool`).
        internal: true as const,
        type: "text",
        kind: "text",
        text: error instanceof Error ? error.message : String(error),
      },
    },
  ];
}

/**
 * Stores one iteration's messages and appends them to the context window.
 * Returns false when they could not be stored: the loop stops.
 */
export async function storeIterationMessages(
  client: SupabaseClient<Database>,
  conv: ConversationRow,
  messages: MessageRow[],
  response: ResponseContext,
): Promise<boolean> {
  if (response.messages?.length) {
    log.info("Agent response", response.messages.at(-1)?.content);

    const output_messages = response.messages.map((message, index) => ({
      ...message,
      ...(isInternal(message) && { status: {} }),
      // Make sure the messages have the correct addressing
      organization_id: conv.organization_id,
      conversation_id: conv.id,
      organization_address: conv.organization_address,
      conversation_address: conv.address,
      // Disambiguate by milliseconds index to ensure the insertion order.
      timestamp: new Date(Date.now() + index).toISOString(),
    }));

    try {
      // Insert and select the inserted messages
      const { data: inserted_messages } = await client
        .from("messages")
        .insert(output_messages)
        .select()
        .order("timestamp")
        .throwOnError();

      // Append generated messages to the context
      messages.push(...inserted_messages);
    } catch (storageError) {
      log.error("Failed to store agent response", storageError as Error);
      return false;
    }
  }

  return true;
}
