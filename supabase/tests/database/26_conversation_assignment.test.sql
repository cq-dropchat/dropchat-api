-- H1 — a conversation's assignment, and the one gate that writes it.
--
-- Failure scenario without this: who answers is decided fresh on every
-- message ("the oldest AI agent"), so nothing can hand a conversation to a
-- human, hand it back, or say who did. Adding columns is not enough — if any
-- API role could write them, an assignment could land with no audit note, and
-- H3's escalation would be a suggestion rather than a fact.
--
-- What is pinned here: the composite references refuse another tenant's
-- agent; no API role writes the columns or calls the gate; every change
-- leaves exactly one note; and the backfill picks the agent the old rule
-- picked.
begin;
select plan(50);

select has_column('public', 'conversations', 'assigned_agent_id', 'conversations.assigned_agent_id exists');
select has_column('public', 'conversations', 'assigned_at', 'conversations.assigned_at exists');
select has_column('public', 'organizations', 'entry_agent_id', 'organizations.entry_agent_id exists');

-- ---------------------------------------------------------------------------
-- The references are composite: an agent of another organization is not
-- nameable, by anyone, service role included.
-- ---------------------------------------------------------------------------

-- The guard trigger refuses a direct UPDATE before the reference is even
-- checked, so the flag it looks for is set here to get it out of the way:
-- what this asserts is the CONSTRAINT, not the guard (which has its own
-- cases below).
select throws_ok(
  format(
    $sql$
      select set_config('app.assignment_writer', 'on', true);
      update public.conversations set assigned_agent_id = %L where id = %L;
    $sql$,
    tests.id('agent_bob'), tests.id('conv_a1')
  ),
  '23503',
  null,
  'a conversation cannot be assigned to another organization''s agent'
);

select throws_ok(
  format(
    'select public.set_conversation_assignment(%L, %L, false, null, ''{"cause": "manual"}''::jsonb)',
    tests.id('conv_a1'), tests.id('agent_bob')
  ),
  '23503',
  null,
  'and the gate refuses it too, before writing anything'
);

select throws_ok(
  format(
    'update public.organizations set entry_agent_id = %L where id = %L',
    tests.id('agent_bob'), tests.id('org_a')
  ),
  '23503',
  null,
  'an organization cannot name another organization''s agent as its entry agent'
);

-- ---------------------------------------------------------------------------
-- The gate writes; a direct UPDATE does not.
-- ---------------------------------------------------------------------------

select lives_ok(
  format(
    'select public.set_conversation_assignment(%L, %L, false, null, ''{"cause": "entry"}''::jsonb)',
    tests.id('conv_a1'), tests.id('agent_robot_a')
  ),
  'the gate assigns a conversation to an agent of its own organization'
);

select is(
  (select assigned_agent_id from public.conversations where id = tests.id('conv_a1')),
  tests.id('agent_robot_a'),
  'the assignment is stored'
);

select ok(
  (select assigned_at is not null from public.conversations where id = tests.id('conv_a1')),
  'assigned_at is stamped'
);

select is(
  (
    select count(*)::int
    from public.messages
    where conversation_id = tests.id('conv_a1')
      and content ->> 'kind' = 'assignment'
  ),
  1,
  'the change left exactly one audit note'
);

select is(
  (
    select content -> 'data'
    from public.messages
    where conversation_id = tests.id('conv_a1')
      and content ->> 'kind' = 'assignment'
  ),
  jsonb_build_object(
    'from', null,
    'to', tests.id('agent_robot_a')::text,
    'awaiting_human', false,
    'by', null,
    'cause', 'entry'
  ),
  'the note records from, to, awaiting_human, by and cause'
);

select ok(
  (
    select (content ->> 'internal')::boolean
      and (status = '{}'::jsonb)
    from public.messages
    where conversation_id = tests.id('conv_a1')
      and content ->> 'kind' = 'assignment'
  ),
  'the note is internal and unarmed, so nothing dispatches it'
);

-- A category and a free-text reason ride along (H3's escalation); the keys
-- are absent, not null, when nothing was given.
select lives_ok(
  format(
    'select public.set_conversation_assignment(%L, null, true, %L, ''{"cause": "escalation", "category": "reclamo", "reason": "el pedido llego danado"}''::jsonb)',
    tests.id('conv_a1'), tests.id('agent_robot_a')
  ),
  'the gate can unassign and mark a conversation as awaiting a human'
);

select is(
  (
    select content -> 'data' ->> 'category'
    from public.messages
    where conversation_id = tests.id('conv_a1')
      and content ->> 'kind' = 'assignment'
      and content -> 'data' ->> 'cause' = 'escalation'
  ),
  'reclamo',
  'the escalation note carries its category'
);

select ok(
  (
    select not (content -> 'data' ? 'category')
    from public.messages
    where conversation_id = tests.id('conv_a1')
      and content ->> 'kind' = 'assignment'
      and content -> 'data' ->> 'cause' = 'entry'
  ),
  'a note with no category has no category key'
);

select is(
  (
    select count(*)::int
    from public.messages
    where conversation_id = tests.id('conv_a1')
      and content ->> 'kind' = 'assignment'
  ),
  2,
  'each change leaves its own note'
);

-- An unknown cause is refused: M1 aggregates on this vocabulary.
select throws_ok(
  format(
    'select public.set_conversation_assignment(%L, %L, false, null, ''{"cause": "vibes"}''::jsonb)',
    tests.id('conv_a1'), tests.id('agent_robot_a')
  ),
  '22023',
  null,
  'an unknown cause is refused'
);

-- The routing path does not overwrite a concurrent assignment.
select public.set_conversation_assignment(
  tests.id('conv_a2'), tests.id('agent_robot_a'), false, null, '{"cause": "entry"}'::jsonb
);

-- `.id is null` and not `row is null`: a composite is NULL only when every
-- field is, so testing the row itself would answer about the nulls inside it.
select is(
  (
    select (public.set_conversation_assignment(
      tests.id('conv_a2'), tests.id('agent_alice'), false, null,
      '{"cause": "entry", "expect_from": null}'::jsonb
    )).id
  ),
  null,
  'expect_from skips a conversation somebody assigned meanwhile'
);

-- …and writes when the row still says what the caller believed: this is how
-- a conversation pinned to an agent that no longer answers is re-routed.
select is(
  (
    select (public.set_conversation_assignment(
      tests.id('conv_a2'), tests.id('agent_alice'), false, null,
      jsonb_build_object(
        'cause', 'entry', 'expect_from', tests.id('agent_robot_a')
      )
    )).assigned_agent_id
  ),
  tests.id('agent_alice'),
  'expect_from writes over the assignment it expected to find'
);

select public.set_conversation_assignment(
  tests.id('conv_a2'), tests.id('agent_robot_a'), false, null,
  '{"cause": "manual"}'::jsonb
);

select is(
  (select assigned_agent_id from public.conversations where id = tests.id('conv_a2')),
  tests.id('agent_robot_a'),
  'and leaves the winner''s assignment in place'
);

-- The service role cannot bypass the gate either: the guard trigger is the
-- rule, not the RLS policy.
select throws_ok(
  format(
    'update public.conversations set assigned_agent_id = %L where id = %L',
    tests.id('agent_alice'), tests.id('conv_a1')
  ),
  '42501',
  null,
  'a direct UPDATE of the assignment is refused even for the service role'
);

-- ---------------------------------------------------------------------------
-- Who may call it: nobody but the service role.
-- ---------------------------------------------------------------------------

-- A `local` channel of org A, which alice CAN update (05-03) — the one place
-- where an API role holds UPDATE on this table at all, and so the only place
-- where the guard trigger is the thing doing the refusing.
insert into public.conversations (
  id, organization_id, service, organization_address, address, type, name
)
values (
  'aaaaaaaa-0000-4000-8000-0000000000ce',
  tests.id('org_a'),
  'local',
  (
    select address
    from public.organizations_addresses
    where organization_id = tests.id('org_a') and service = 'local'
  ),
  'aaaaaaaa-0000-4000-8000-0000000000ce',
  'channel',
  'General'
);

select tests.authenticate_as('alice@test.local');

select lives_ok(
  $$update public.conversations set name = 'General 2'
    where id = 'aaaaaaaa-0000-4000-8000-0000000000ce'$$,
  'user A can still rename a local conversation'
);

select throws_ok(
  format(
    'select public.set_conversation_assignment(%L, %L)',
    tests.id('conv_a1'), tests.id('agent_robot_a')
  ),
  '42501',
  null,
  'user A (owner) cannot call the gate'
);

-- Alice holds UPDATE on `local` conversations (05-03). The guard is what
-- stops her writing the columns through it.
select throws_ok(
  format(
    'update public.conversations set assigned_agent_id = %L where id = %L',
    tests.id('agent_robot_a'), 'aaaaaaaa-0000-4000-8000-0000000000ce'
  ),
  '42501',
  null,
  'user A cannot write the assignment through the local UPDATE policy'
);

select tests.clear_authentication();
select tests.authenticate_as('bob@test.local');

select throws_ok(
  format(
    'select public.set_conversation_assignment(%L, %L)',
    tests.id('conv_a1'), tests.id('agent_robot_a')
  ),
  '42501',
  null,
  'user B cannot call the gate'
);

select tests.clear_authentication();
select tests.authenticate_with_api_key(tests.val('key_a_owner'));

select throws_ok(
  format(
    'select public.set_conversation_assignment(%L, %L)',
    tests.id('conv_a1'), tests.id('agent_robot_a')
  ),
  '42501',
  null,
  'API key A (owner) cannot call the gate'
);

select tests.clear_authentication();
select tests.authenticate_with_api_key(tests.val('key_b_member'));

select throws_ok(
  format(
    'select public.set_conversation_assignment(%L, %L)',
    tests.id('conv_a1'), tests.id('agent_robot_a')
  ),
  '42501',
  null,
  'API key B cannot call the gate'
);

select tests.clear_authentication();
select tests.authenticate_as_anon();

select throws_ok(
  format(
    'select public.set_conversation_assignment(%L, %L)',
    tests.id('conv_a1'), tests.id('agent_robot_a')
  ),
  '42501',
  null,
  'anon cannot call the gate'
);

select tests.clear_authentication();

-- ---------------------------------------------------------------------------
-- The backfill picks the agent the old rule picked.
--
-- The fixture reloads organizations and agents AFTER the migration ran, so
-- there is no one-time run left to observe: what is pinned here is the RULE,
-- replayed (statement quoted from
-- migrations/20260919220328_h1_conversation_assignment.sql) against an agent
-- set that makes every clause matter.
-- ---------------------------------------------------------------------------

insert into public.agents (id, organization_id, user_id, name, created_at, extra)
values
  -- Older than Robot A and in draft: the rule before H1 selected draft
  -- agents, so this IS who answered yesterday and must stay the entry agent.
  (
    'aaaaaaaa-0000-4000-8000-00000000a0d1',
    tests.id('org_a'), null, 'Robot draft',
    (select created_at from public.agents where id = tests.id('agent_robot_a'))
      - interval '1 day',
    '{"mode": "draft"}'::jsonb
  ),
  -- Older still, but inactive: never selected, then or now.
  (
    'aaaaaaaa-0000-4000-8000-00000000a0d2',
    tests.id('org_a'), null, 'Robot inactive',
    (select created_at from public.agents where id = tests.id('agent_robot_a'))
      - interval '2 days',
    '{"mode": "inactive"}'::jsonb
  ),
  -- Oldest of all, and retired.
  (
    'aaaaaaaa-0000-4000-8000-00000000a0d3',
    tests.id('org_a'), null, 'Robot retired',
    (select created_at from public.agents where id = tests.id('agent_robot_a'))
      - interval '3 days',
    '{"mode": "active"}'::jsonb
  );

update public.agents
set deleted_at = now()
where id = 'aaaaaaaa-0000-4000-8000-00000000a0d3';

update public.organizations o
set entry_agent_id = (
  select a.id
  from public.agents a
  where a.organization_id = o.id
    and a.user_id is null
    and a.deleted_at is null
    and coalesce(a.extra ->> 'mode', 'active') <> 'inactive'
  order by a.created_at, a.id
  limit 1
)
where o.entry_agent_id is null;

select is(
  (select entry_agent_id from public.organizations where id = tests.id('org_a')),
  'aaaaaaaa-0000-4000-8000-00000000a0d1'::uuid,
  'the backfill keeps the agent the old rule chose — draft included, because that is who answered'
);

select is(
  (select entry_agent_id from public.organizations where id = tests.id('org_b')),
  null,
  'an organization whose only agent is a human gets no entry agent'
);

-- ---------------------------------------------------------------------------
-- H3 — assign_conversation: the member-facing door, and the implicit takeover.
--
-- Failure scenario: without an RPC, a person who has to step into a
-- conversation cannot tell the AI to stop — no API role can write the columns
-- — so the agent keeps answering over them. Without the takeover trigger,
-- stepping in by hand (the thing a person actually does) leaves the
-- conversation assigned to the AI.
-- ---------------------------------------------------------------------------

select has_column(
  'public', 'conversations', 'awaiting_human_since',
  'conversations.awaiting_human_since exists'
);

-- A personal account of alice's, so amber (a member of the same org) cannot
-- see its conversations: the visibility rule the RPC has to honour.
insert into public.organizations_addresses (
  organization_id, service, address, agent_id, status
)
values (
  tests.id('org_a'), 'whatsapp', '56900000001', tests.id('agent_alice'),
  'connected'
);

insert into public.conversations (
  id, organization_id, service, organization_address, address, type, name
)
values (
  'aaaaaaaa-0000-4000-8000-0000000000cf',
  tests.id('org_a'), 'whatsapp', '56900000001', '56955555555', 'direct',
  'Privada de Alice'
);

-- Start from a conversation the AI holds.
select public.set_conversation_assignment(
  tests.id('conv_a1'), tests.id('agent_robot_a'), false, null,
  '{"cause": "entry"}'::jsonb
);

select tests.authenticate_as('alice@test.local');

select lives_ok(
  format(
    'select public.assign_conversation(%L, %L)',
    tests.id('conv_a1'), tests.id('agent_alice')
  ),
  'user A (owner) takes a conversation she can see'
);

select is(
  (select assigned_agent_id from public.conversations where id = tests.id('conv_a1')),
  tests.id('agent_alice'),
  'and the conversation is hers'
);

select is(
  (
    select count(*)::int
    from public.messages
    where conversation_id = tests.id('conv_a1')
      and content -> 'data' ->> 'cause' = 'manual'
      and content -> 'data' ->> 'by' = tests.id('agent_alice')::text
      and content -> 'data' ->> 'to' = tests.id('agent_alice')::text
  ),
  1,
  'the note says who did it'
);

select throws_ok(
  format(
    'select public.assign_conversation(%L, %L)',
    tests.id('conv_a1'), tests.id('agent_bob')
  ),
  '23503',
  null,
  'an agent of another organization is refused'
);

-- A retired AI cannot be handed a conversation: nothing would answer it.
insert into public.agents (id, organization_id, user_id, name, extra, deleted_at)
values (
  'aaaaaaaa-0000-4000-8000-00000000a0e1', tests.id('org_a'), null,
  'Robot retirado', '{"mode": "active"}'::jsonb, now()
);

select throws_ok(
  format(
    'select public.assign_conversation(%L, %L)',
    tests.id('conv_a1'), 'aaaaaaaa-0000-4000-8000-00000000a0e1'
  ),
  'P0001',
  null,
  'a retired agent is refused'
);

insert into public.agents (id, organization_id, user_id, name, extra)
values (
  'aaaaaaaa-0000-4000-8000-00000000a0e2', tests.id('org_a'), null,
  'Robot borrador', '{"mode": "draft"}'::jsonb
);

select throws_ok(
  format(
    'select public.assign_conversation(%L, %L)',
    tests.id('conv_a1'), 'aaaaaaaa-0000-4000-8000-00000000a0e2'
  ),
  'P0001',
  null,
  'a draft agent is refused — it does not answer'
);

select tests.clear_authentication();
select tests.authenticate_as('amber@test.local');

select throws_ok(
  format(
    'select public.assign_conversation(%L, %L)',
    'aaaaaaaa-0000-4000-8000-0000000000cf', tests.id('agent_amber')
  ),
  '42501',
  null,
  'a member of the organization who cannot SEE the conversation is refused'
);

select tests.clear_authentication();
select tests.authenticate_as('bob@test.local');

select throws_ok(
  format(
    'select public.assign_conversation(%L, %L)',
    tests.id('conv_a1'), tests.id('agent_bob')
  ),
  '42501',
  null,
  'user B cannot assign a conversation of organization A'
);

select tests.clear_authentication();
select tests.authenticate_with_api_key(tests.val('key_a_member'));

select lives_ok(
  format(
    'select public.assign_conversation(%L, null)',
    tests.id('conv_a1')
  ),
  'API key A hands the conversation back to routing'
);

select is(
  (select assigned_agent_id from public.conversations where id = tests.id('conv_a1')),
  null,
  'and nobody holds it'
);

select tests.clear_authentication();
select tests.authenticate_with_api_key(tests.val('key_b_member'));

select throws_ok(
  format(
    'select public.assign_conversation(%L, %L)',
    tests.id('conv_a1'), tests.id('agent_robot_a')
  ),
  '42501',
  null,
  'API key B cannot assign a conversation of organization A'
);

select tests.clear_authentication();
select tests.authenticate_as_anon();

select throws_ok(
  format(
    'select public.assign_conversation(%L, %L)',
    tests.id('conv_a1'), tests.id('agent_robot_a')
  ),
  '42501',
  null,
  'anon cannot assign anything'
);

select tests.clear_authentication();

-- ---------------------------------------------------------------------------
-- Escalation clears the assignment and starts the clock.
-- ---------------------------------------------------------------------------

select public.set_conversation_assignment(
  tests.id('conv_a2'), null, true, tests.id('agent_robot_a'),
  '{"cause": "escalation", "category": "reclamo"}'::jsonb
);

select ok(
  (
    select awaiting_human_since is not null and assigned_agent_id is null
    from public.conversations where id = tests.id('conv_a2')
  ),
  'an escalation leaves the conversation waiting for a human and held by nobody'
);

select public.set_conversation_assignment(
  tests.id('conv_a2'), tests.id('agent_robot_a'), false, null,
  '{"cause": "manual"}'::jsonb
);

select is(
  (select awaiting_human_since from public.conversations where id = tests.id('conv_a2')),
  null,
  'assigning somebody clears the wait'
);

-- ---------------------------------------------------------------------------
-- The implicit takeover (A2): answering by hand takes the conversation.
-- ---------------------------------------------------------------------------

create function pg_temp.outgoing(_agent uuid, _text text, _internal boolean default false)
returns void language plpgsql as $$
begin
  insert into public.messages (
    organization_id, conversation_id, service, organization_address,
    conversation_address, agent_id, status, content
  )
  values (
    tests.id('org_a'), tests.id('conv_a1'), 'whatsapp', tests.val('wa_a'),
    tests.val('contact_a1'), _agent,
    case when _internal then '{}'::jsonb else jsonb_build_object('pending', now()) end,
    jsonb_strip_nulls(jsonb_build_object(
      'version', '1', 'type', 'text', 'kind', 'text', 'text', _text,
      'internal', case when _internal then true else null end
    ))
  );
end;
$$;

select public.set_conversation_assignment(
  tests.id('conv_a1'), tests.id('agent_robot_a'), false, null,
  '{"cause": "entry"}'::jsonb
);

-- The AI answering does not change anything.
select pg_temp.outgoing(tests.id('agent_robot_a'), 'te ayudo con eso');

select is(
  (select assigned_agent_id from public.conversations where id = tests.id('conv_a1')),
  tests.id('agent_robot_a'),
  'the AI answering does not trigger a takeover'
);

-- An internal note by a human does not either: it was never sent.
select pg_temp.outgoing(tests.id('agent_alice'), 'nota para el equipo', true);

select is(
  (select assigned_agent_id from public.conversations where id = tests.id('conv_a1')),
  tests.id('agent_robot_a'),
  'an internal note does not trigger a takeover'
);

-- A human answering by hand does.
select pg_temp.outgoing(tests.id('agent_alice'), 'hola, soy Alice');

select is(
  (select assigned_agent_id from public.conversations where id = tests.id('conv_a1')),
  tests.id('agent_alice'),
  'a human answering by hand takes the conversation'
);

-- By cause, not by "the last one": notes written in the same transaction
-- share created_at, so "latest" is not a total order here.
select is(
  (
    select count(*)::int
    from public.messages
    where conversation_id = tests.id('conv_a1')
      and content ->> 'kind' = 'assignment'
      and content -> 'data' ->> 'cause' = 'takeover'
      and content -> 'data' ->> 'to' = tests.id('agent_alice')::text
  ),
  1,
  'and the note says why, and who now holds it'
);

-- With auto_takeover off, nothing moves.
select public.set_conversation_assignment(
  tests.id('conv_a1'), tests.id('agent_robot_a'), false, null,
  '{"cause": "manual"}'::jsonb
);

update public.organizations
set extra = jsonb_build_object('attention', jsonb_build_object('auto_takeover', false))
where id = tests.id('org_a');

select pg_temp.outgoing(tests.id('agent_alice'), 'otra vez Alice');

select is(
  (select assigned_agent_id from public.conversations where id = tests.id('conv_a1')),
  tests.id('agent_robot_a'),
  'with auto_takeover off, answering by hand changes nothing'
);

select * from finish();
rollback;
