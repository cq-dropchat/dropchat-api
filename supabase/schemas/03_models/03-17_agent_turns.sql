-- F16. One agent turn per conversation.
--
-- Every armed inbound message wakes agent-client. What kept two invocations
-- from answering twice was a created_at comparison the function made after
-- sleeping 3 seconds — racy for a duplicate invocation of one message and
-- for a message landing while the previous one was being answered, and both
-- raced to a paid LLM call.
--
-- One row per conversation that has ever woken the agent:
--   latest_*           debounce: the newest registered inbound message by
--                      (created_at, id), the same order the function used.
--                      Only its invocation may answer.
--   holder_message_id  lease: the invocation answering right now, until
--   lease_until        lease_until (renewed while it works; a crashed
--                      invocation simply lets it lapse).
--   handled_message_id the last message answered, so a duplicate
--                      invocation of it does not answer again.
--
-- Service role only (see 04-06_agent_turns.sql), like public.rate_limits.
create table public.agent_turns (
  conversation_id uuid not null,
  organization_id uuid not null,
  latest_message_id uuid not null,
  latest_created_at timestamp with time zone not null,
  holder_message_id uuid,
  lease_until timestamp with time zone,
  handled_message_id uuid,
  updated_at timestamp with time zone default now() not null
);

alter table only public.agent_turns
add constraint agent_turns_pkey
primary key (conversation_id);

alter table only public.agent_turns
add constraint agent_turns_conversation_id_fkey
foreign key (conversation_id)
references public.conversations(id)
on delete cascade;

alter table only public.agent_turns
add constraint agent_turns_organization_id_fkey
foreign key (organization_id)
references public.organizations(id)
on delete cascade;

alter table public.agent_turns enable row level security;

revoke all on table public.agent_turns from anon, authenticated;
