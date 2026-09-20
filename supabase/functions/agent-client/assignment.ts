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
 * Persist a routing decision — compare-and-set, because the decision was made
 * from a row that was read seconds ago. `expect_from` states what the caller
 * believed the assignment was (nobody, or an agent that turned out not to
 * answer any more); if the row says otherwise, another invocation or a person
 * decided first and nothing is written.
 *
 * Returns whether this invocation owns the conversation afterwards. False
 * means somebody else does, and this one should not answer: the winner will.
 */
export async function assignConversation(
  client: SupabaseClient<Database>,
  conv: ConversationRow,
  agentId: string | null,
  cause: AssignmentCause,
  actorAgentId: string | null = null,
): Promise<boolean> {
  const expected = conv.assigned_agent_id;

  const { data, error } = await client.rpc("set_conversation_assignment", {
    p_conversation_id: conv.id,
    p_agent_id: agentId!,
    p_awaiting_human: false,
    p_actor_agent_id: actorAgentId!,
    p_reason: { cause, expect_from: expected },
  });

  if (error) {
    // Failing to record it is not a reason to leave the contact unanswered:
    // the next message routes again.
    log.warn("Failed to record the conversation assignment.", {
      conversation_id: conv.id,
      agent_id: agentId,
      cause,
      error: error.message,
    });

    return true;
  }

  const row = (Array.isArray(data) ? data[0] : data) as ConversationRow | null;

  // `row.id`, not `row`: a SQL composite that is NULL comes back from
  // PostgREST as an object with every field null, not as JSON null, so the
  // object alone does not say whether anything was written.
  if (!row?.id) {
    // Lost the race. Adopt what the row actually says, so the turn checks
    // downstream compare against reality rather than against an intention.
    const { data: current } = await client
      .from("conversations")
      .select("assigned_agent_id, awaiting_human_since")
      .eq("id", conv.id)
      .maybeSingle();

    conv.assigned_agent_id = current?.assigned_agent_id ?? null;
    conv.awaiting_human_since = current?.awaiting_human_since ?? null;

    log.info("Another invocation assigned this conversation first.", {
      conversation_id: conv.id,
      assigned_agent_id: conv.assigned_agent_id,
    });

    return conv.assigned_agent_id === agentId;
  }

  conv.assigned_agent_id = row.assigned_agent_id;
  conv.awaiting_human_since = row.awaiting_human_since;

  return true;
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

/**
 * H3 — did somebody take this conversation from us while we were thinking?
 *
 * The handler's `conv` is the agent's own view of the assignment: it is
 * updated by everything this invocation does (the routing write, its own
 * escalation). So anything the database says that this copy does not is
 * somebody ELSE's doing — a person answering by hand (the implicit takeover),
 * an explicit `assign_conversation`, or an expiry — and the answer we are
 * holding must not be sent on top of theirs.
 *
 * Checked before every LLM call and before storing what came back, because
 * both are things a person's reply has to win against.
 */
export async function takenFromUs(
  client: SupabaseClient<Database>,
  conv: ConversationRow,
): Promise<boolean> {
  // A local DM has no assignment to lose: the roster names the agent.
  if (conv.service === "local") {
    return false;
  }

  const { data, error } = await client
    .from("conversations")
    .select("assigned_agent_id, awaiting_human_since")
    .eq("id", conv.id)
    .maybeSingle();

  if (error || !data) {
    // Unreadable is not "taken": failing closed here would silence the agent
    // on a transient error.
    log.warn("Could not re-read the conversation's assignment.", {
      conversation_id: conv.id,
      error: error?.message,
    });

    return false;
  }

  return data.assigned_agent_id !== conv.assigned_agent_id ||
    (data.awaiting_human_since ?? null) !== (conv.awaiting_human_since ?? null);
}
