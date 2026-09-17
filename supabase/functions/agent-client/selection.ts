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

// AGENT SELECTION
//
// External: the oldest active AI agent in the organization — an AI agent
// being one that is nobody's membership (no user_id) and has not been
// retired (deleted_at). There is no per-conversation override: nothing can
// write one, since members hold no UPDATE on conversations outside `local`.
//
// Local DM: there is nothing to select — the address names the agent.
//
// Selected before the delay because the delay is the agent's own.
export function selectAgent(
  conv: ConversationRow,
  agents: AgentRow[],
  dmAI: AgentRowWithExtra | undefined,
): AgentRowWithExtra | undefined {
  return conv.service === "local"
    ? (dmAI?.extra?.mode !== "inactive" ? dmAI : undefined)
    : agents
      .filter((a) =>
        a.user_id === null && a.deleted_at === null &&
        a.extra?.mode !== "inactive"
      )
      .sort((a, b) => +new Date(a.created_at) - +new Date(b.created_at))
      .at(0) as AgentRowWithExtra | undefined;
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
