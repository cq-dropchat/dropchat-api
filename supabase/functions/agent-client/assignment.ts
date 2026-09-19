// H1 — the I/O half of the assignment: resolving who holds a conversation,
// and writing the decision down.
//
// The decision itself is pure (selection.ts). Everything here is one call to
// public.set_conversation_assignment, which updates the columns AND records
// the audit note in a single transaction — no API role can write them any
// other way (the guard trigger refuses it).
import type { SupabaseClient } from "@supabase/supabase-js";
import * as log from "../_shared/logger.ts";
import type { Database } from "../_shared/types/database_types.ts";
import type {
  AgentRow,
  ConversationRow,
  MessageRow,
} from "../_shared/supabase.ts";
import type { AssignmentCause } from "./selection.ts";

/**
 * The agent a conversation is assigned to, when the AI-only embed did not
 * carry it — because it is a member (a human took the conversation) or an AI
 * that has since been retired.
 *
 * Narrow on purpose (F23): `extra` is not read, so no member row's secrets
 * are fetched to answer "is this a human?".
 */
export async function loadAssignedAgent(
  client: SupabaseClient<Database>,
  conv: ConversationRow,
  agents: AgentRow[],
): Promise<AgentRow | undefined> {
  const assigned = conv.assigned_agent_id;

  if (!assigned || agents.some((a) => a.id === assigned)) {
    return undefined;
  }

  const { data } = await client
    .from("agents")
    .select("id, user_id, deleted_at, created_at, organization_id")
    .eq("id", assigned)
    .eq("organization_id", conv.organization_id)
    .maybeSingle()
    .throwOnError();

  return (data ?? undefined) as AgentRow | undefined;
}

/**
 * Persist a routing decision, unless somebody else's invocation got there
 * first: two inbound messages of the same conversation can be answered by
 * two invocations, and the loser must not overwrite the winner's assignment
 * (`if_unassigned`).
 *
 * Failing to record it is not a reason to leave the contact unanswered: the
 * next message routes again.
 */
export async function assignConversation(
  client: SupabaseClient<Database>,
  conv: ConversationRow,
  agentId: string | null,
  cause: AssignmentCause,
  actorAgentId: string | null = null,
): Promise<void> {
  const { error } = await client.rpc("set_conversation_assignment", {
    p_conversation_id: conv.id,
    p_agent_id: agentId!,
    p_awaiting_human: false,
    p_actor_agent_id: actorAgentId!,
    p_reason: { cause, if_unassigned: true },
  });

  if (error) {
    log.warn("Failed to record the conversation assignment.", {
      conversation_id: conv.id,
      agent_id: agentId,
      cause,
      error: error.message,
    });

    return;
  }

  conv.assigned_agent_id = agentId;
}

/**
 * `/new` restarts the session, and who answers is part of what it restarts:
 * a conversation a human took, or one pinned to an agent that has since
 * changed, would otherwise keep that decision across the reset.
 */
export async function clearAssignmentOnRestart(
  client: SupabaseClient<Database>,
  conv: ConversationRow,
  messages: MessageRow[],
  before: number,
): Promise<void> {
  // `restartSessionIfAsked` drops everything before the `/new`, so a shorter
  // window is how this learns that a restart happened.
  if (messages.length === before || !conv.assigned_agent_id) {
    return;
  }

  const { error } = await client.rpc("set_conversation_assignment", {
    p_conversation_id: conv.id,
    p_agent_id: null as unknown as string,
    p_awaiting_human: false,
    p_actor_agent_id: null as unknown as string,
    p_reason: { cause: "manual" },
  });

  if (error) {
    log.warn("Failed to clear the assignment on /new.", {
      conversation_id: conv.id,
      error: error.message,
    });

    return;
  }

  conv.assigned_agent_id = null;
}
