-- P2 — a `local` conversation whose visibility depends on participants, born
-- without a creator to record, is a row nobody can ever see.
--
-- The participants of a `local` conversation come from its shape: a `direct`
-- takes them from its roster address, a `group` from the creator
-- (auth.uid()), and a `channel` needs none — it is organization-wide. A
-- writer with no agent of its own (an API key, the service role) therefore
-- leaves a `group`, and a `direct` that stated no roster, with zero
-- participants: get_participant_conversations does not return it, and
-- get_restricted_conversations restricts it for being `local` without a
-- channel. Not even the organization's owner can see or repair it.
--
-- The insert now fails instead.
begin;
select plan(13);

-- The `local` account of organization A; one is minted per organization.
create temporary view p2_local as
select address
from public.organizations_addresses
where organization_id = tests.id('org_a') and service = 'local';

-- Every actor below reads it, including the ones that hold nothing in A: the
-- view is the test's own scaffolding, not part of what is under test.
grant select on p2_local to public;

-- ---------------------------------------------------------------------------
-- API key of A: the shapes that need a creator are refused
-- ---------------------------------------------------------------------------

select tests.authenticate_with_api_key(tests.val('key_a_member'));

-- A peerless `local` message mints its conversation in
-- before_insert_on_messages, and with no roster stated it is a `direct`
-- addressed to itself: a note to self for nobody.
select throws_ok(
  $$
    insert into public.messages (
      organization_id, service, organization_address, content, status
    ) values (
      tests.id('org_a'), 'local',
      (select address from p2_local),
      '{"version":"1","type":"text","kind":"text","text":"hola"}',
      '{}'
    )
  $$,
  'PT422', null,
  'API key A cannot start a rosterless local conversation with a message'
);

select throws_ok(
  $$
    insert into public.conversations (
      organization_id, organization_address, service, type, name
    ) values (
      tests.id('org_a'), (select address from p2_local), 'local', 'group',
      'grupo sin nadie'
    )
  $$,
  'PT422', null,
  'API key A cannot create a local group'
);

-- ---------------------------------------------------------------------------
-- API key of A: the shapes that carry their own participants still work
-- ---------------------------------------------------------------------------

-- A roster names the participants outright, so no creator is needed.
select lives_ok(
  $$
    insert into public.messages (
      organization_id, service, organization_address, conversation_address,
      content, status
    ) values (
      tests.id('org_a'), 'local',
      (select address from p2_local),
      tests.id('agent_alice')::text || ':' || tests.id('agent_amber')::text,
      '{"version":"1","type":"text","kind":"text","text":"hola"}',
      '{}'
    )
  $$,
  'API key A can start a local direct by stating its roster'
);

select lives_ok(
  $$
    insert into public.conversations (
      organization_id, organization_address, service, type, name
    ) values (
      tests.id('org_a'), (select address from p2_local), 'local', 'channel',
      'canal de la api key'
    )
  $$,
  'API key A can create a local channel'
);

select tests.clear_authentication();

select is(
  (
    select count(*)
    from public.conversations_agents ca
    join public.conversations c on c.id = ca.conversation_id
    where c.organization_id = tests.id('org_a')
      and c.service = 'local'
      and c.type = 'direct'
      and c.address =
        tests.id('agent_alice')::text || ':' || tests.id('agent_amber')::text
  ),
  2::bigint,
  'the roster became the two participants'
);

-- ---------------------------------------------------------------------------
-- A member creates the same shapes: unchanged
-- ---------------------------------------------------------------------------

select tests.authenticate_as('alice@test.local');

select lives_ok(
  $$
    insert into public.messages (
      organization_id, service, organization_address, content, status
    ) values (
      tests.id('org_a'), 'local',
      (select address from p2_local),
      '{"version":"1","type":"text","kind":"text","text":"nota para mí"}',
      '{}'
    )
  $$,
  'a member still opens a note to self'
);

select lives_ok(
  $$
    insert into public.conversations (
      organization_id, organization_address, service, type, name
    ) values (
      tests.id('org_a'), (select address from p2_local), 'local', 'group',
      'grupo de alice'
    )
  $$,
  'a member still creates a local group'
);

select is(
  (
    select count(*)
    from public.conversations c
    where c.organization_id = tests.id('org_a')
      and c.service = 'local'
      and c.name = 'grupo de alice'
      and exists (
        select 1 from public.conversations_agents ca
        where ca.conversation_id = c.id
          and ca.agent_id = tests.id('agent_alice')
      )
  ),
  1::bigint,
  'the member who created the group is in it'
);

-- A member sees the channel the API key opened, which is the point of a
-- channel: it needs no participants because everyone is in it.
select is(
  (
    select count(*)
    from public.conversations
    where organization_id = tests.id('org_a')
      and name = 'canal de la api key'
  ),
  1::bigint,
  'a member sees the API key''s channel'
);

select tests.clear_authentication();

-- ---------------------------------------------------------------------------
-- The other tenant and anon: refused by RLS, before the shape is considered
-- ---------------------------------------------------------------------------

select tests.authenticate_as('bob@test.local');
select throws_ok(
  $$
    insert into public.conversations (
      organization_id, organization_address, service, type, name
    ) values (
      tests.id('org_a'), (select address from p2_local), 'local', 'group', 'de B'
    )
  $$,
  '42501', null, 'user B cannot create a local conversation in A'
);
select tests.clear_authentication();

select tests.authenticate_with_api_key(tests.val('key_b_member'));
select throws_ok(
  $$
    insert into public.conversations (
      organization_id, organization_address, service, type, name
    ) values (
      tests.id('org_a'), (select address from p2_local), 'local', 'group', 'de B'
    )
  $$,
  '42501', null, 'API key B cannot create a local conversation in A'
);
select tests.clear_authentication();

select tests.authenticate_as_anon();
select throws_ok(
  $$
    insert into public.conversations (
      organization_id, organization_address, service, type, name
    ) values (
      tests.id('org_a'), (select address from p2_local), 'local', 'group', 'anon'
    )
  $$,
  '42501', null, 'anon cannot create a local conversation'
);
select tests.clear_authentication();

-- ---------------------------------------------------------------------------
-- The invariant this is all for
-- ---------------------------------------------------------------------------

select is(
  (
    select count(*)
    from public.conversations c
    where c.service = 'local'
      and c.type is distinct from 'channel'
      and not exists (
        select 1 from public.conversations_agents ca
        where ca.conversation_id = c.id
      )
  ),
  0::bigint,
  'no local conversation is left without participants unless it is a channel'
);

select * from finish();
rollback;
