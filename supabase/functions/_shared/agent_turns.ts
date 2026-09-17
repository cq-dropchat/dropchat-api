// F16. One agent turn per conversation, decided in the database
// (public.agent_turns, see supabase/schemas/04_functions_post_tables/
// 04-06_agent_turns.sql for the protocol).
//
// Before: agent-client slept 3 seconds and compared created_at in memory.
// A duplicate invocation of one message, or a message arriving while the
// previous one was being answered, raced to two paid LLM calls.
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "./types/database_types.ts";

type Client = SupabaseClient<Database>;

export type ClaimResult = "claimed" | "superseded" | "handled" | "busy";
export type RenewResult = "renewed" | "superseded" | "lost";

export type TurnMessage = {
  conversation_id: string;
  id: string;
  created_at: string;
};

/** Registers the message as a candidate for the turn: the newest one wins. */
export async function beginAgentTurn(
  client: Client,
  message: TurnMessage,
): Promise<void> {
  await client
    .rpc("begin_agent_turn", {
      _conversation_id: message.conversation_id,
      _message_id: message.id,
      _created_at: message.created_at,
    })
    .throwOnError();
}

export async function claimAgentTurn(
  client: Client,
  message: TurnMessage,
): Promise<ClaimResult> {
  const { data } = await client
    .rpc("claim_agent_turn", {
      _conversation_id: message.conversation_id,
      _message_id: message.id,
    })
    .throwOnError();
  return data as ClaimResult;
}

export type WaitOptions = {
  /** Between claims while another invocation holds the turn. */
  pollMs?: number;
  /** Give up after this long; the holder's lease is 90 s and renewable. */
  maxWaitMs?: number;
};

/**
 * Claims the turn, waiting while another invocation holds it: that holder
 * either finishes (and this message is answered with its reply in the
 * history) or notices it was superseded and yields.
 */
export async function waitForAgentTurn(
  client: Client,
  message: TurnMessage,
  { pollMs = 1000, maxWaitMs = 120_000 }: WaitOptions = {},
): Promise<ClaimResult | "timeout"> {
  const deadline = Date.now() + maxWaitMs;

  while (true) {
    const result = await claimAgentTurn(client, message);
    if (result !== "busy") return result;
    if (Date.now() + pollMs > deadline) return "timeout";
    await new Promise((resolve) => setTimeout(resolve, pollMs));
  }
}

/** Extends the lease; anything but "renewed" means stop before the next LLM call. */
export async function renewAgentTurn(
  client: Client,
  message: TurnMessage,
): Promise<RenewResult> {
  const { data } = await client
    .rpc("renew_agent_turn", {
      _conversation_id: message.conversation_id,
      _message_id: message.id,
    })
    .throwOnError();
  return data as RenewResult;
}

/** Drops the lease. `handled`: the message was answered and must not be again. */
export async function releaseAgentTurn(
  client: Client,
  message: TurnMessage,
  handled: boolean,
): Promise<void> {
  await client
    .rpc("release_agent_turn", {
      _conversation_id: message.conversation_id,
      _message_id: message.id,
      _handled: handled,
    })
    .throwOnError();
}
