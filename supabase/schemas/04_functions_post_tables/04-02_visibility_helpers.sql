-- Who sees a conversation: the ACCOUNT rule decides by default, and a
-- conversation may override it.
--
--   Account (organizations_addresses.agent_id):
--     null => public — a shared inbox, visible to the whole org
--     set  => private — a personal account, visible to its owner
--
--   Restriction (get_restricted_conversations below):
--     the account rule is suppressed for conversations two services host on
--     an ownerless account without meaning "shared with the whole org".
--     Those are visible to conversations_agents participants only.
--
-- The restriction exists because one ownerless account can host both modes:
--
--   slack  The workspace anchor is ownerless and holds the bot — the
--          shared-inbox connection, exactly like a common WhatsApp number —
--          while each member's T…:U… row is personal. Every conversation
--          hangs off the anchor regardless of which connection it arrived
--          through, so "is this shared?" is a fact about the conversation.
--          The bot's presence IS that fact, and is what the webhook actually
--          observes (member_joined/left_channel), so it is what we store.
--          Absent means absent: a conversation the bot is not in is not
--          shared, which is the fail-closed direction.
--
--   local  One ownerless account per org hosts the whole internal chat, so
--          the account says nothing. Shape decides instead, exactly as it
--          would in Slack or Teams: `channel` is open to the org, everything
--          else (direct, group) is for its participants.
--
-- Both services are named explicitly, rather than reading a flag every
-- ingestor would have to remember to write — an absent flag fails open, and
-- this must fail closed. A new service that needs a restriction adds a line
-- here; one that does not, adds nothing.
--
-- There is deliberately NO role bypass: owners/admins cannot read a member's
-- personal conversations. API keys authenticate without auth.uid(), so they
-- only ever see shared-inbox content.
--
-- SHAPE: these return SETS and take no per-row arguments, so the policies can
-- call them as `x in (select …)` — an InitPlan evaluated once per query and
-- then hash-probed per row, the same trick that makes get_authorized_orgs
-- cheap. A boolean helper taking the row's columns cannot get that treatment:
-- it is re-invoked per row, and being SECURITY DEFINER it cannot be inlined
-- either.

-- Accounts whose conversations the caller can see, as (organization_id,
-- service, address) triples: the org's shared inboxes, plus personal accounts
-- the caller owns. Conversations under these are visible unless their override
-- says private.
--
-- service is in the tuple because it is in the account key: the same address
-- string can name a shared 'whatsapp' account and a personal 'whatsapp-web'
-- one, and matching on the pair alone would let either decide for both.
create function rls.get_visible_addresses()
returns table (organization_id uuid, service public.service, address text)
language sql
stable
security definer
set search_path to ''
as $$
  -- Shared inboxes: any ownerless account in an org the caller belongs to. No
  -- auth.uid() in the ownerless test itself, so this is the only rule an API
  -- key can satisfy.
  --
  -- The org filter is redundant with every policy that calls this — each one
  -- already ANDs `organization_id in get_authorized_orgs(…)`. It stays because
  -- it is what makes the function safe on its own: SECURITY DEFINER, so RLS
  -- does not apply inside it, and without the filter it answers with every
  -- shared inbox in the DATABASE — other tenants' org ids and account
  -- addresses, WhatsApp business numbers among them. Until P8 moved it to the
  -- `rls` schema that was not hypothetical: PostgREST published it at
  -- /rpc/get_visible_addresses for anyone with the anon key.
  select oa.organization_id, oa.service, oa.address
  from public.organizations_addresses oa
  where oa.agent_id is null
    and oa.organization_id in (select rls.get_authorized_orgs('member'))
  union
  -- Personal accounts owned by the caller (their Slack identity, a personal
  -- WhatsApp/mailbox).
  select oa.organization_id, oa.service, oa.address
  from public.organizations_addresses oa
  join public.agents a on a.id = oa.agent_id
  where a.user_id = auth.uid() and a.deleted_at is null;
$$;

-- Conversations the caller participates in: a conversations_agents row names
-- an agent that is the caller. Mirrors channel/DM membership on the external
-- service, and is the only way into a restricted conversation.
create function rls.get_participant_conversations()
returns setof uuid
language sql
stable
security definer
set search_path to ''
as $$
  select ca.conversation_id
  from public.conversations_agents ca
  join public.agents a on a.id = ca.agent_id
  where a.user_id = auth.uid() and a.deleted_at is null;
$$;

-- S1 — the drills that are mine: (organization, address) pairs a `sandbox`
-- conversation of my own is addressed by.
--
-- A drill's address IS the agent id of the member who opened it. That is a
-- deliberate choice over a string convention like `sim:<id>`: a format
-- spelled in SQL and again in TypeScript is a vocabulary duplicated by hand
-- between the two repos, which this project already has one of and does not
-- need a second. An id compared to an id has no format to drift.
--
-- Empty for API keys, like rls.get_own_agents: they authenticate without
-- auth.uid() and are nobody in particular, so no drill is theirs. Returned as
-- pairs rather than bare ids so a caller who belongs to two organizations
-- cannot reach into one of them with the other's agent id.
create function rls.get_own_sandbox_addresses()
returns table (organization_id uuid, address text)
language sql
stable
security definer
set search_path to ''
as $$
  select a.organization_id, a.id::text
  from public.agents a
  where a.user_id = auth.uid() and a.deleted_at is null;
$$;

-- Conversations whose account rule is suppressed — see the two cases at the
-- top of this file. Scoped to the caller's orgs so the set stays bounded.
--
-- Members can influence neither branch. `extra` is writable in principle, but
-- 05-03 grants UPDATE on conversations to no API role except on `local`, so
-- nobody can claim the bot is in a channel it is not in; and `type` is
-- restored from the old row on every API-role update
-- (preserve_conversation_addressing), so a participant cannot retype a private
-- room as a channel and publish it to the organization.
-- The restriction rule for one conversation's columns (F10: shared with the
-- realtime broadcast trigger, so the two cannot drift). Immutable SQL: inlined
-- into get_restricted_conversations.
create function rls.is_restricted_conversation(
  conv_service public.service,
  conv_type text,
  conv_extra jsonb
) returns boolean
language sql
immutable
set search_path to ''
as $$
  select
    -- Slack: shared iff the bot is in it.
    (
      conv_service = 'slack'::public.service
      and not coalesce((conv_extra->>'is_bot_member')::boolean, false)
    )
    -- local: shared iff it is a public channel.
    or (
      conv_service = 'local'::public.service
      and conv_type is distinct from 'channel'
    );
$$;

create function rls.get_restricted_conversations()
returns setof uuid
language sql
stable
security definer
set search_path to ''
as $$
  select c.id
  from public.conversations c
  where c.organization_id in (select rls.get_authorized_orgs('member'))
    and rls.is_restricted_conversation(c.service, c.type, c.extra);
$$;

-- Boolean form, for callers that hold a single row rather than a query to
-- filter (is_media_visible). Same rules, expressed through the same two
-- functions so the two forms cannot drift apart. Do NOT use this in a policy
-- over a large table: per-row arguments defeat the InitPlan.
create function rls.is_conversation_visible(
  conv_id uuid,
  conv_org uuid,
  conv_addr text,
  conv_service public.service
) returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select
    (
      (conv_org, conv_service, conv_addr) in (
        select v.organization_id, v.service, v.address
        from rls.get_visible_addresses() v
      )
      and conv_id not in (select rls.get_restricted_conversations())
    )
    or conv_id in (select rls.get_participant_conversations());
$$;

-- Whether the caller may download a media object (storage path
-- organizations/<org>/attachments/<file>). Rule: an object nobody references
-- stays org-scoped (covers freshly uploaded files whose message doesn't
-- exist yet, and v0-content legacy media, which only v1 file parts can
-- reference here); a referenced object requires at least one referencing
-- message whose conversation the caller can see. SECURITY DEFINER on
-- purpose: with invoker rights the invisible referencing messages would be
-- hidden by RLS and the check could not distinguish "unreferenced" from
-- "referenced but private".
create function rls.is_media_visible(object_name text) returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  with refs as (
    select m.conversation_id, m.organization_id, m.service, m.organization_address
    from public.messages m
    where m.content->'file'->>'uri' = 'internal://media/' || object_name
  )
  select
    not exists (select 1 from refs)
    or exists (
      select 1 from refs r
      where rls.is_conversation_visible(
        r.conversation_id, r.organization_id, r.organization_address, r.service
      )
    );
$$;
