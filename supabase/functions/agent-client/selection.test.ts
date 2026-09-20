// H1 — who answers a conversation is a property OF THE CONVERSATION.
//
// Before this, `selectAgent` answered "the oldest AI agent that is not
// inactive" on every message of every external conversation: no per-
// conversation assignment, `draft` agents picked as if they were live, and an
// AI replying inside WhatsApp groups to whoever wrote last.
//
// Pure test: no database, no network.
import { assertEquals } from "jsr:@std/assert@1";
import type {
  AgentRow,
  ConversationRow,
} from "../_shared/types/database_types.ts";
import type { AIAgentExtra } from "../_shared/types/extra_types.ts";
import type { AgentRowWithExtra } from "./protocols/base.ts";
import { type EntryConfig, selectAgent } from "./selection.ts";

/** Only the fields the selection reads; the rest is not part of the case. */
function agent(
  id: string,
  createdAt: string,
  extra: AIAgentExtra = { mode: "active" },
  overrides: Partial<AgentRow> = {},
): AgentRow {
  return {
    id,
    organization_id: "org-a",
    user_id: null,
    deleted_at: null,
    created_at: createdAt,
    name: id,
    extra,
    ...overrides,
  } as unknown as AgentRow;
}

function conversation(
  overrides: Partial<ConversationRow> = {},
): ConversationRow {
  return {
    id: "conv-1",
    organization_id: "org-a",
    service: "whatsapp",
    organization_address: "56911110000",
    address: "56922220000",
    type: "direct",
    assigned_agent_id: null,
    awaiting_human_since: null,
    ...overrides,
  } as unknown as ConversationRow;
}

function org(
  overrides: Partial<EntryConfig> & { attention?: Record<string, unknown> } =
    {},
): EntryConfig {
  const { attention, ...rest } = overrides;

  return {
    entry_agent_id: null,
    extra: attention ? { attention } : null,
    ...rest,
  } as EntryConfig;
}

const OLDEST = agent("agent-oldest", "2026-01-01T00:00:00.000Z");
const NEWER = agent("agent-newer", "2026-06-01T00:00:00.000Z");
const HUMAN = agent("agent-human", "2026-02-01T00:00:00.000Z", {}, {
  user_id: "user-1",
});
const DRAFT = agent("agent-draft", "2025-01-01T00:00:00.000Z", {
  mode: "draft",
});
const INACTIVE = agent("agent-inactive", "2025-06-01T00:00:00.000Z", {
  mode: "inactive",
});

Deno.test("H1: an eligible assigned agent answers, even when an older one exists", () => {
  const selection = selectAgent(
    conversation({ assigned_agent_id: NEWER.id } as Partial<ConversationRow>),
    [OLDEST, NEWER],
    undefined,
    org({ entry_agent_id: OLDEST.id }),
  );

  assertEquals(selection.agent?.id, NEWER.id);
  // Already assigned to it: nothing to persist.
  assertEquals(selection.assign, undefined);
});

Deno.test("H1: a conversation assigned to a human gets no AI answer", () => {
  const selection = selectAgent(
    conversation({ assigned_agent_id: HUMAN.id } as Partial<ConversationRow>),
    [OLDEST, HUMAN],
    undefined,
    org({ entry_agent_id: OLDEST.id }),
  );

  assertEquals(selection.agent, undefined);
  // The human keeps it: the AI does not steal it back.
  assertEquals(selection.assign, undefined);
});

Deno.test("H1: an assignment to an agent that is no longer eligible falls back to the entry agent", () => {
  const selection = selectAgent(
    conversation(
      { assigned_agent_id: INACTIVE.id } as Partial<ConversationRow>,
    ),
    [OLDEST, NEWER, INACTIVE],
    undefined,
    org({ entry_agent_id: NEWER.id }),
  );

  assertEquals(selection.agent?.id, NEWER.id);
  assertEquals(selection.assign, { agent_id: NEWER.id, cause: "entry" });
});

Deno.test("H1: with no assignment, the entry agent answers", () => {
  const selection = selectAgent(
    conversation(),
    [OLDEST, NEWER],
    undefined,
    org({ entry_agent_id: NEWER.id }),
  );

  assertEquals(selection.agent?.id, NEWER.id);
  assertEquals(selection.assign, { agent_id: NEWER.id, cause: "entry" });
});

Deno.test("H1: with no entry agent, the oldest eligible one answers", () => {
  const selection = selectAgent(
    conversation(),
    [NEWER, OLDEST],
    undefined,
    org(),
  );

  assertEquals(selection.agent?.id, OLDEST.id);
  assertEquals(selection.assign, { agent_id: OLDEST.id, cause: "entry" });
});

Deno.test("H1: an entry agent that is not eligible falls back to the oldest one", () => {
  const selection = selectAgent(
    conversation(),
    [OLDEST, NEWER, DRAFT],
    undefined,
    org({ entry_agent_id: DRAFT.id }),
  );

  assertEquals(selection.agent?.id, OLDEST.id);
});

// RED before H1: `selectAgent` excluded `inactive` only, so a draft agent —
// the mode the UI offers for "not ready yet" — answered contacts, and being
// the oldest row it won over every live agent.
Deno.test("H1: a draft agent is never selected", () => {
  const byAge = selectAgent(conversation(), [DRAFT, OLDEST], undefined, org());

  assertEquals(byAge.agent?.id, OLDEST.id);

  const assigned = selectAgent(
    conversation({ assigned_agent_id: DRAFT.id } as Partial<ConversationRow>),
    [DRAFT, OLDEST],
    undefined,
    org(),
  );

  assertEquals(assigned.agent?.id, OLDEST.id);

  const only = selectAgent(conversation(), [DRAFT], undefined, org());

  assertEquals(only.agent, undefined);
});

// RED before H1: nothing looked at `conversations.type`, so the AI answered
// inside WhatsApp groups — with per-conversation assignment and escalation to
// humans, a room full of participants has no clear semantics.
Deno.test("H1: no AI in a group unless the organization asked for it", () => {
  const group = conversation({ type: "group" } as Partial<ConversationRow>);

  const off = selectAgent(group, [OLDEST], undefined, org());

  assertEquals(off.agent, undefined);
  assertEquals(off.assign, undefined);

  const on = selectAgent(
    group,
    [OLDEST],
    undefined,
    org({ extra: { ai_in_groups: true } }),
  );

  assertEquals(on.agent?.id, OLDEST.id);
});

Deno.test("H1: a conversation with no type yet is treated as direct", () => {
  const selection = selectAgent(
    conversation({ type: null } as Partial<ConversationRow>),
    [OLDEST],
    undefined,
    org(),
  );

  assertEquals(selection.agent?.id, OLDEST.id);
});

// H4 — an assignment is not for ever. A conversation is one row per contact
// for the life of that contact (there is no "closed"), so without a TTL the
// agent that answered in March still owns the conversation in December,
// however much the organization changed since.
Deno.test("H4: an AI assignment expires when the contact has been away too long", () => {
  const assigned = conversation(
    { assigned_agent_id: NEWER.id } as Partial<ConversationRow>,
  );

  const stale = selectAgent(
    assigned,
    [OLDEST, NEWER],
    undefined,
    org({
      entry_agent_id: OLDEST.id,
      attention: { ai_assignment_ttl_days: 14 },
    }),
    "2026-09-01T12:00:00.000Z",
  );

  // 18 days without the contact: routed again, and recorded as an expiry.
  assertEquals(stale.agent?.id, OLDEST.id);
  assertEquals(stale.assign, { agent_id: OLDEST.id, cause: "expiry" });
});

Deno.test("H4: a conversation the contact wrote in recently keeps its agent", () => {
  const assigned = conversation(
    { assigned_agent_id: NEWER.id } as Partial<ConversationRow>,
  );

  const fresh = selectAgent(
    assigned,
    [OLDEST, NEWER],
    undefined,
    org({
      entry_agent_id: OLDEST.id,
      attention: { ai_assignment_ttl_days: 14 },
    }),
    "2026-09-17T12:00:00.000Z",
  );

  assertEquals(fresh.agent?.id, NEWER.id);
  assertEquals(fresh.assign, undefined);
});

Deno.test("H4: a human assignment does not expire this way", () => {
  // The human TTL is a cron's job (expire_human_assignments), measured on
  // what the person sent — not on the contact's silence.
  const assigned = conversation(
    { assigned_agent_id: HUMAN.id } as Partial<ConversationRow>,
  );

  const selection = selectAgent(
    assigned,
    [OLDEST, HUMAN],
    undefined,
    org({
      attention: { ai_assignment_ttl_days: 14 },
    }),
    "2026-01-01T12:00:00.000Z",
  );

  assertEquals(selection.agent, undefined);
  assertEquals(selection.assign, undefined);
});

Deno.test("H4: a conversation with no previous contact message is not stale", () => {
  const assigned = conversation(
    { assigned_agent_id: NEWER.id } as Partial<ConversationRow>,
  );

  assertEquals(
    selectAgent(assigned, [OLDEST, NEWER], undefined, org(), undefined)
      .agent?.id,
    NEWER.id,
  );
});

// H3 — an escalation is a promise to the contact that a person will come.
// Until somebody does, no AI answers: `awaiting_human_since` outranks even a
// live assignment (the escalation clears it, but a race could leave one).
Deno.test("H3: a conversation waiting for a human gets no AI answer", () => {
  const waiting = conversation(
    {
      assigned_agent_id: null,
      awaiting_human_since: "2026-09-19T12:00:00.000Z",
    } as Partial<ConversationRow>,
  );

  const selection = selectAgent(
    waiting,
    [OLDEST, NEWER],
    undefined,
    org({ entry_agent_id: OLDEST.id }),
  );

  assertEquals(selection.agent, undefined);
  // And nothing is routed: the conversation is not free to be taken.
  assertEquals(selection.assign, undefined);
});

Deno.test("H3: once a human hands it back, the AI answers again", () => {
  const returned = conversation(
    {
      assigned_agent_id: OLDEST.id,
      awaiting_human_since: null,
    } as Partial<ConversationRow>,
  );

  assertEquals(
    selectAgent(returned, [OLDEST], undefined, org()).agent?.id,
    OLDEST.id,
  );
});

Deno.test("H1: a local DM with a draft AI gets no answer", () => {
  const dmAI = DRAFT as AgentRowWithExtra;

  const selection = selectAgent(
    conversation({ service: "local", type: "direct" } as Partial<
      ConversationRow
    >),
    [DRAFT],
    dmAI,
    org(),
  );

  assertEquals(selection.agent, undefined);
});

Deno.test("H1: a local DM with a live AI still answers, and is not assigned", () => {
  const dmAI = OLDEST as AgentRowWithExtra;

  const selection = selectAgent(
    conversation({ service: "local", type: "direct" } as Partial<
      ConversationRow
    >),
    [OLDEST],
    dmAI,
    org(),
  );

  assertEquals(selection.agent?.id, OLDEST.id);
  assertEquals(selection.assign, undefined);
});
