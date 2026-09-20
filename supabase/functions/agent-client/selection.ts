import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../_shared/types/database_types.ts";
import {
  type AgentRow,
  contactName,
  type ConversationRow,
  isInternal,
  type MessageRow,
} from "../_shared/supabase.ts";
import type { AgentRowWithExtra, ContactInfo } from "./protocols/base.ts";
import type { OrganizationExtra } from "../_shared/types/extra_types.ts";
import { fromContact } from "./conversation.ts";

export /**
 * Internal comms: the services where the peer is a colleague, not a contact.
 * `discord` and `teams` are in the service enum but have no ingestion yet —
 * listed so they start on the right side of the rule when they arrive.
 *
 * One carve-out: a `local` DM whose roster names an AI agent (see AI DM
 * DETECTION below). Mirrored workspaces stay excluded wholesale.
 */
const TEAM_CHAT_SERVICES = new Set<Database["public"]["Enums"]["service"]>([
  "local",
  "slack",
  "discord",
  "teams",
]);

// AI DM DETECTION (local only)
//
// A local direct's address IS its roster (two agent ids, sorted,
// ':'-joined), and direct rosters are immutable identity — so the address
// alone answers "is this a DM with an AI?". The rule: exactly ONE live AI
// in the roster, and the author is the other slot. Requiring exactly one
// also refuses an AI–AI room (a service-role insert can mint one), which
// would otherwise be two armed repliers ping-ponging with an LLM bill
// attached. This re-verifies what handle_local_message_to_agent already
// checked: the trigger is the doorbell, this is the authority.
export function findDmAI(
  conv: ConversationRow,
  agents: AgentRow[],
  incoming: MessageRow,
): AgentRowWithExtra | undefined {
  const roster = conv.service === "local" ? conv.address?.split(":") ?? [] : [];

  const rosterAIs = roster.length === 2
    ? agents.filter((a) =>
      roster.includes(a.id) && a.user_id === null && a.deleted_at === null
    )
    : [];

  return rosterAIs.length === 1 && rosterAIs[0].id !== incoming.agent_id
    ? rosterAIs[0] as AgentRowWithExtra
    : undefined;
}

// RETRIEVE CONTACT (external services only)
//
// The conversation's address is a soft reference (no FK, so no PostgREST
// embed): the contact comes from its own query. On a direct chat the
// conversation's address IS the contact's address; a group address simply
// matches no contacts_addresses row and the contact stays null.
//
// A local roster would match nothing either — the peer is a colleague, not
// a contact — so the DM path skips the query and shapes the author's agent
// row like a contact instead: the protocol handlers only want a name.
export async function loadContact(
  client: SupabaseClient<Database>,
  conv: ConversationRow,
  incoming: MessageRow,
): Promise<ContactInfo | undefined> {
  let contact: ContactInfo | undefined;

  if (conv.service === "local") {
    // F23: the author is a member, not in the AI-only embed. A name is all
    // the protocol handlers read.
    const { data: author } = incoming.agent_id
      ? await client
        .from("agents")
        .select("name")
        .eq("id", incoming.agent_id)
        .eq("organization_id", conv.organization_id)
        .maybeSingle()
        .throwOnError()
      : { data: null };

    if (author) {
      contact = { name: author.name };
    }
  } else {
    const { data: contact_address } = await client
      .from("contacts_addresses")
      .select("extra")
      .eq("organization_id", conv.organization_id)
      .eq("organization_address", conv.organization_address)
      .eq("service", conv.service)
      .eq("address", conv.address)
      .maybeSingle()
      .throwOnError();

    if (contact_address) {
      contact = { name: contactName(contact_address.extra) };
    }
  }

  return contact;
}

// AGENT SELECTION (H1)
//
// Who answers is a property OF THE CONVERSATION, not a fresh decision per
// message. The order:
//
//   local DM   the address names the agent; nothing to assign.
//   group      nobody, unless the organization turned `ai_in_groups` on.
//   waiting    nobody, while awaiting_human_since is set (H3).
//   assigned   an eligible AI answers; a human keeps it (the AI stays out);
//              an agent that is no longer eligible falls through to routing.
//   otherwise  the entry agent if it is eligible, else the oldest eligible
//              one — and the result is PERSISTED by the caller, so the next
//              message of this conversation does not re-decide.
//
// Eligible means: nobody's membership (no user_id), not retired
// (deleted_at), and a mode that is neither `inactive` nor `draft`. `draft`
// was selectable before H1 — the mode the UI offers for "not ready yet"
// answered real contacts, and being the oldest row it won over every live
// agent.
//
// Pure: the caller resolves the assigned agent's row (it may be a human, who
// is not in the AI-only embed) and performs the write.

/** The vocabulary of `set_conversation_assignment`; M1 aggregates on it. */
export type AssignmentCause =
  | "routing"
  | "entry"
  | "escalation"
  | "manual"
  | "takeover"
  | "expiry";

/** What the selection needs from the organization. */
export type EntryConfig = {
  entry_agent_id: string | null;
  extra: OrganizationExtra | null;
};

export type AgentSelection = {
  agent: AgentRowWithExtra | undefined;
  /**
   * Set when the conversation's assignment has to be written. Absent when
   * the conversation already points at the agent that answers — or when
   * nobody answers, which is not a decision worth recording.
   */
  assign?: { agent_id: string | null; cause: AssignmentCause };
};

export function isEligibleAI(agent: AgentRow): boolean {
  const mode = (agent as AgentRowWithExtra).extra?.mode;

  return agent.user_id === null &&
    agent.deleted_at === null &&
    mode !== "inactive" &&
    mode !== "draft";
}

export function selectAgent(
  conv: ConversationRow,
  agents: AgentRow[],
  dmAI: AgentRowWithExtra | undefined,
  org: EntryConfig,
): AgentSelection {
  if (conv.service === "local") {
    // A DM's roster IS the decision; an assignment would have nothing to add.
    return { agent: dmAI && isEligibleAI(dmAI) ? dmAI : undefined };
  }

  // WAITING FOR A PERSON (H3)
  //
  // The agent told the contact a person would come. Answering anyway makes
  // that a lie, and the conversation is not free to be routed either — it is
  // held for whoever takes it.
  if (conv.awaiting_human_since) {
    return { agent: undefined };
  }

  // NO AI IN GROUPS (H1)
  //
  // Nothing looked at `conversations.type` before, so the AI answered inside
  // WhatsApp groups, to whoever wrote last. With one agent assigned per
  // conversation and escalation to a human, a room of participants has no
  // clear semantics — who is the contact being handed over? Opt-in per
  // organization for the cases that do want it.
  if (conv.type && conv.type !== "direct" && !org.extra?.ai_in_groups) {
    return { agent: undefined };
  }

  const eligible = agents.filter(isEligibleAI) as AgentRowWithExtra[];

  if (conv.assigned_agent_id) {
    const assigned = agents.find((a) => a.id === conv.assigned_agent_id);

    if (assigned && isEligibleAI(assigned)) {
      return { agent: assigned as AgentRowWithExtra };
    }

    // A human holds it (a membership row, or an id the AI-only embed did not
    // carry and the caller resolved as a member): the AI does not take it
    // back. Only an explicit hand-back (H3) or a lifecycle expiry (H4) does.
    if (assigned && assigned.user_id !== null) {
      return { agent: undefined };
    }

    // Anything else — retired, inactive, draft, or an agent that no longer
    // exists — is a dead assignment, and the conversation routes again.
  }

  const entry = eligible.find((a) => a.id === org.entry_agent_id);

  const agent = entry ??
    eligible
      .slice()
      .sort((a, b) => +new Date(a.created_at) - +new Date(b.created_at))
      .at(0);

  return agent
    ? { agent, assign: { agent_id: agent.id, cause: "entry" } }
    : { agent: undefined };
}

// Authorship is space-relative: outside, the peer is whoever carries a
// sender_address; in a local DM the peer is any member row that is not the
// AI's own — and never an internal one (a note is addressed to nobody).
export function peerPredicate(
  conv: ConversationRow,
  dmAI: AgentRowWithExtra | undefined,
): (m: MessageRow) => boolean {
  return (m: MessageRow) =>
    conv.service === "local"
      ? m.agent_id !== null && m.agent_id !== dmAI?.id && !isInternal(m)
      : fromContact(m);
}
