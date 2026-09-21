import type { SQLToolConfig } from "../../agent-client/tools/sql.ts";

//===================================
// Extra
//===================================

export type Memory = {
  [key: string]: string | undefined | Memory;
};

export type PreprocessingConfig = {
  mode?: "active" | "inactive";
  model?: "gemini-2.5-pro" | "gemini-2.5-flash";
  api_key?: string;
  language?: string;
  extra_prompt?: string;
};

/**
 * H4: when the organization is reachable, and how long an assignment lasts.
 * Every reader goes through the defaults (A6) — in SQL
 * `public.attention_config`, in TypeScript `attentionConfig` — so a missing
 * key is never a missing rule.
 */
export type AttentionConfig = {
  /** IANA name; the market's zone by default. */
  timezone?: string;
  /**
   * Weekly schedule, as local [from, to] pairs per day (several per day for
   * a lunch break). Absent — or null — means 24/7, which is what an
   * organization that never configured one gets.
   */
  business_hours?:
    | Partial<
      Record<
        "mon" | "tue" | "wed" | "thu" | "fri" | "sat" | "sun",
        [string, string][]
      >
    >
    | null;
  /** Days without the contact writing before the conversation routes again. */
  ai_assignment_ttl_days?: number;
  /** Hours without the person writing before it goes back to routing; 0 = never. */
  human_assignment_ttl_hours?: number;
  /** Business minutes a contact waits for a person after an escalation. */
  human_wait_minutes?: number;
  on_human_wait_timeout?: "notify_customer" | "return_to_ai";
  human_wait_message?: string;
  /** A2: answering by hand takes the conversation. */
  auto_takeover?: boolean;
};

export type OrganizationExtra = {
  attention?: AttentionConfig;
  media_preprocessing?: PreprocessingConfig;
  error_messages_direction?: "internal" | "outgoing";
  /**
   * H1: whether the AI answers in conversations that are not `direct`
   * (WhatsApp groups, channels). Off by default — with one agent assigned per
   * conversation and escalation to a human, a room of participants has no
   * clear semantics, and before H1 the AI answered in them by accident,
   * having never looked at `conversations.type`.
   */
  ai_in_groups?: boolean;
  /**
   * H2: how the organization sounds — tone, tú/usted, how it signs off. One
   * voice of the brand (D3), so it leads the system prompt of every agent,
   * ahead of the agent's own instructions.
   */
  brand_voice?: string;
};

export type WhatsAppOrganizationAddressExtra = {
  waba_id?: string;
  business_id?: string;
  phone_number?: string;
  verified_name?: string;
  flow_type?: "only_waba" | "new_phone_number" | "existing_phone_number";
  access_token?: string; // Meta system-user token
  callback_url?: string | null;
  verify_token?: string | null;
  // F28: set by the dispatcher when Meta rejects this account's token (190);
  // outgoing messages fail without calling Meta until a new token clears it.
  dispatch_auth_failure?: { code: number; message: string; at: string };
};

export type InstagramOrganizationAddressExtra = {
  ig_user_id?: string;
  username?: string;
  name?: string;
  profile_picture_url?: string;
  access_token?: string; // Per-IG-account OAuth user token (long-lived, 60 days)
  token_expires_at?: string; // ISO; when the long-lived token expires
  token_refreshed_at?: string; // ISO; last successful refresh (or initial issue)
  scopes?: string[]; // granted permissions
  needs_reauth?: string; // ISO; set when a refresh failed and re-login is required
};

// Slack has two row shapes: the workspace anchor (address = team id,
// agent_id null) and per-member identities (address = `${team}:${user}`,
// agent_id set) — the latter holds the member's xoxp user token. Token keys
// accept null so a disconnect can clear them through the merge_update
// trigger.
export type SlackOrganizationAddressExtra = {
  // anchor
  team_name?: string;
  enterprise_id?: string | null;
  // personal
  team_id?: string;
  slack_user_id?: string;
  access_token?: string | null; // xoxp user token
  refresh_token?: string | null; // present when token rotation is enabled
  expires_at?: string; // ISO; rotated-token expiry
  scopes?: string; // comma-separated granted user scopes
};

// Union — the column accepts either shape; consumers narrow via the row's
// `service` column (or via a cast at service-specific read sites).
export type OrganizationAddressExtra =
  | WhatsAppOrganizationAddressExtra
  | InstagramOrganizationAddressExtra
  | SlackOrganizationAddressExtra;

/**
 * Only the service role writes this on every service but `local` — RLS grants
 * members no UPDATE on conversations elsewhere (see 05-03), which is what lets
 * ingestor-owned facts share the bag with cosmetic ones.
 *
 * The channel's SHAPE is not here: it is the `type` column, in one
 * cross-service vocabulary (direct/multiple/group/channel/broadcast).
 */
export type ConversationExtra = {
  memory?: Memory;
  /**
   * UI preferences, org-wide — which is not what they mean. Per-member is
   * where they belong, and not on conversations_agents: rows there GRANT
   * VISIBILITY, so members write that table on `local` alone (05-12), while a
   * preference must be settable on anything you can see. They need a table of
   * their own.
   */
  archived?: string;
  pinned?: string;
  /**
   * A member-defined room (`type` = 'direct') with more than two people —
   * Slack's mpim. The arity a mirror service's opaque channel id cannot show;
   * only ever written true, absent means 1:1. `local` never writes it: a
   * roster address carries its own arity.
   */
  is_multiple?: boolean;
  // Slack (service = 'slack'; address = channel id)
  /**
   * Whether our bot is a member of this channel. The whole shared-inbox
   * decision for Slack: the workspace anchor is ownerless, so it is the bot's
   * presence — not the account — that makes a conversation org-visible.
   * Absent means absent (fail closed), so the webhook writes it on every
   * conversation it creates, including `false`.
   */
  is_bot_member?: boolean;
  /** Slack channel archived. Named apart from the `archived` UI preference above. */
  channel_archived?: boolean;
  topic?: string;
  purpose?: string;
  /** im only: the counterpart Slack user id */
  user?: string;
};

export type WhatsAppContactAddressExtra = {
  name?: string;
  username?: string;
  phone_number?: string;
  bsuid?: string;
  address_type?: "phone" | "bsuid";
  synced?: { // if the contact address was synced from WhatsApp
    name: string;
    action: "add" | "remove";
  };
  replaces_address?: string;
  replaced_by_address?: string;
};

export type InstagramContactAddressExtra = {
  name?: string;
  username?: string;
  biography?: string;
  profile_picture_url?: string;
  // ISO timestamp — set on every fetch (success or failure) so the TTL guard
  // suppresses retries until the refresh window elapses.
  name_fetched_at?: string;
  replaces_address?: string;
  replaced_by_address?: string;
};

export type SlackContactAddressExtra = {
  name?: string;
  picture?: string;
  team_id?: string;
  synced?: { // directory sync (same trigger mechanism as WhatsApp)
    name: string;
    action: "add" | "remove";
  };
};

// Union — the column accepts either shape; consumers narrow via the row's
// `service` column (or via the per-service Row/Insert aliases below).
export type ContactAddressExtra =
  | WhatsAppContactAddressExtra
  | InstagramContactAddressExtra
  | SlackContactAddressExtra;

// The display name of a contacts_addresses row: the name the user saved in
// the service's address book (synced) wins over the name the contact set for
// themself (push name, profile).
export function contactName(
  extra: ContactAddressExtra | null | undefined,
): string | undefined {
  if (!extra) return undefined;
  const synced = "synced" in extra ? extra.synced : undefined;
  return synced?.name ?? extra.name;
}

// Function tools have a JSON input (data part).
export type LocalFunctionToolConfig = {
  provider: "local";
  type: "function";
  name: string;
};

// Custom tools have a free-grammar input (text part).
export type LocalCustomToolConfig = {
  provider: "local";
  type: "custom";
  name: string;
};

export type LocalSimpleToolConfig =
  | LocalFunctionToolConfig
  | LocalCustomToolConfig;

export type LocalMCPToolConfig = {
  provider: "local";
  type: "mcp";
  label: string; // server label
  config: {
    url: string;
    product?: "calendar" | "sheets";
    headers?: Record<string, string>;
    allowed_tools?: string[];
    files?: string[];
    email?: string;
  };
};

export type LocalSQLToolConfig = {
  provider: "local";
  type: "sql";
  label: string; // database label
  config: SQLToolConfig;
};

export type LocalHTTPToolConfig = {
  provider: "local";
  type: "http";
  label: string; // client label
  config: {
    headers?: Record<string, string>;
    url?: string;
    methods?: string[];
  };
};

export type LocalSpecialToolConfig = LocalSQLToolConfig | LocalHTTPToolConfig;

export type ToolConfig =
  | LocalSimpleToolConfig
  | LocalSpecialToolConfig
  | LocalMCPToolConfig;

/**
 * A member's own settings. `role` is not here — it is a column, because it is
 * access control — and neither are invitations, which are their own table.
 *
 * H5: what a member wants to be told about. Written by the member themselves
 * (the "members can update themselves" policy of 05-04), so an admin cannot
 * decide for somebody else what interrupts them.
 */
export type MemberExtra = {
  notifications?: {
    /**
     * Browser notifications when a conversation starts waiting for a person
     * (H3's escalation). Absent means on: somebody has to see a handover,
     * and the count in the tab's title is shown either way.
     */
    escalation?: boolean;
  };
};

export type AIAgentExtra = {
  mode?: "active" | "draft" | "inactive";
  /**
   * Debounce: how long to wait for the contact to finish typing before
   * answering, so a burst of messages gets one reply. Was an organization
   * setting; it is the agent's own behaviour.
   */
  response_delay_seconds?: number;
  /**
   * Sent once, on the first inbound message of a conversation, before the
   * agent is asked anything. Also was an organization setting — which meant
   * an organization with no AI agent could still greet; now the greeting
   * belongs to whoever would have answered.
   */
  welcome_message?: string;
  description?: string;
  api_url?: string;
  api_key?: string;
  model?: string;
  protocol?: "chat_completions" | "responses";
  max_messages?: number;
  temperature?: number;
  max_tokens?: number;
  /**
   * NOT WIRED YET. The call sites are written and commented out in both
   * protocols (`reasoning_effort` in chat-completions, the same idea in
   * responses), waiting for a provider matrix that says which models accept
   * it. Until then, setting this changes nothing — kept because the parked
   * code refers to it, not because anything reads it.
   */
  thinking?: "minimal" | "low" | "medium" | "high";
  /**
   * Whether one turn may produce several messages. Default true: the agent is
   * given a `respond` tool and `tool_choice: "required"`, so it answers by
   * calling it with an array — which is how a bot sends three bubbles instead
   * of one wall of text.
   *
   * Set false for models a provider will not let you force a tool on —
   * reasoning-mode models reject `tool_choice: "required"` outright. The agent
   * then answers in plain text and each turn is a single message. Either mode
   * leaves the same rows behind (the `respond` call is not a tool trace), so
   * this is safe to flip on a conversation already underway.
   */
  multi_message_response?: boolean;
  /**
   * H3: whether this agent may hand a conversation to a person
   * (escalate_to_human). Default true — an agent that cannot escalate has
   * only silence to offer when it is out of its depth.
   */
  can_escalate?: boolean;
  instructions?: string;
  tools?: ToolConfig[];
};
