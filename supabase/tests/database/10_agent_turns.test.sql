-- F16 — one agent turn per conversation.
--
-- Failure scenario: every armed inbound message wakes agent-client, and the
-- only thing standing between two invocations and two LLM answers was a
-- created_at comparison made after a 3-second sleep, in the function. A
-- duplicate invocation of the same message, or a message landing while the
-- previous one is being answered, got two concurrent (paid) responses.
--
-- The turn now lives in public.agent_turns: each invocation registers its
-- message (the newest one wins), then claims a renewable lease. Only the
-- newest message's invocation can claim, only one at a time, and a message
-- answered once is not answered again.
begin;
select plan(26);

select has_table('public', 'agent_turns', 'agent_turns exists');

-- Two inbound messages in conv_a1, the second one newer.
create temp table turn_msgs (name text primary key, id uuid, created_at timestamptz);
insert into turn_msgs values
  ('m1', 'aaaaaaaa-0000-4000-8000-00000000f1b1', now() - interval '2 seconds'),
  ('m2', 'aaaaaaaa-0000-4000-8000-00000000f1b2', now() - interval '1 second'),
  ('m3', 'aaaaaaaa-0000-4000-8000-00000000f1b3', now());
grant select on turn_msgs to anon, authenticated;

create function pg_temp.m(_name text) returns uuid language sql as $$
  select id from turn_msgs where name = _name
$$;
create function pg_temp.at(_name text) returns timestamptz language sql as $$
  select created_at from turn_msgs where name = _name
$$;

-- ---------------------------------------------------------------------------
-- Debounce: the newest registered message owns the turn.
-- ---------------------------------------------------------------------------

select public.begin_agent_turn(tests.id('conv_a1'), pg_temp.m('m1'), pg_temp.at('m1'));
select public.begin_agent_turn(tests.id('conv_a1'), pg_temp.m('m2'), pg_temp.at('m2'));
-- m1's invocation registering late does not take the turn back.
select public.begin_agent_turn(tests.id('conv_a1'), pg_temp.m('m1'), pg_temp.at('m1'));

select is(
  (select latest_message_id from public.agent_turns where conversation_id = tests.id('conv_a1')),
  pg_temp.m('m2'),
  'the newest message by created_at is the latest, whatever the registration order'
);
select is(
  (select organization_id from public.agent_turns where conversation_id = tests.id('conv_a1')),
  tests.id('org_a'),
  'the turn carries the conversation''s organization'
);

select is(public.claim_agent_turn(tests.id('conv_a1'), pg_temp.m('m1')), 'superseded', 'an older message cannot claim');
select is(public.claim_agent_turn(tests.id('conv_a1'), pg_temp.m('m2')), 'claimed', 'the newest message claims');
select is(public.claim_agent_turn(tests.id('conv_a1'), pg_temp.m('m2')), 'busy', 'a duplicate invocation of it waits');

select ok(
  (select lease_until > now() from public.agent_turns where conversation_id = tests.id('conv_a1')),
  'the claim takes a lease'
);

select is(public.renew_agent_turn(tests.id('conv_a1'), pg_temp.m('m2')), 'renewed', 'the holder renews while it is the latest');
select is(public.renew_agent_turn(tests.id('conv_a1'), pg_temp.m('m1')), 'lost', 'a non-holder cannot renew');

-- ---------------------------------------------------------------------------
-- A message arriving mid-answer: the holder yields, the newcomer waits.
-- ---------------------------------------------------------------------------

select public.begin_agent_turn(tests.id('conv_a1'), pg_temp.m('m3'), pg_temp.at('m3'));

select is(public.claim_agent_turn(tests.id('conv_a1'), pg_temp.m('m3')), 'busy', 'the newcomer waits for the holder');
select is(public.renew_agent_turn(tests.id('conv_a1'), pg_temp.m('m2')), 'superseded', 'the holder learns it is superseded at its next check');

select public.release_agent_turn(tests.id('conv_a1'), pg_temp.m('m2'), false);

select is(
  (select holder_message_id from public.agent_turns where conversation_id = tests.id('conv_a1')),
  null,
  'release drops the lease'
);
select is(public.claim_agent_turn(tests.id('conv_a1'), pg_temp.m('m3')), 'claimed', 'and the newcomer claims');

-- A release by a non-holder changes nothing.
select public.release_agent_turn(tests.id('conv_a1'), pg_temp.m('m2'), true);
select is(
  (select holder_message_id from public.agent_turns where conversation_id = tests.id('conv_a1')),
  pg_temp.m('m3'),
  'only the holder releases'
);

-- ---------------------------------------------------------------------------
-- Answered once.
-- ---------------------------------------------------------------------------

select public.release_agent_turn(tests.id('conv_a1'), pg_temp.m('m3'), true);

select is(public.claim_agent_turn(tests.id('conv_a1'), pg_temp.m('m3')), 'handled', 'a handled message is not answered again');

-- ---------------------------------------------------------------------------
-- A crashed holder: the lease expires.
-- ---------------------------------------------------------------------------

select public.begin_agent_turn(tests.id('conv_b1'), pg_temp.m('m1'), pg_temp.at('m1'));
select is(public.claim_agent_turn(tests.id('conv_b1'), pg_temp.m('m1')), 'claimed', 'conversations are independent');

update public.agent_turns
set lease_until = now() - interval '1 second'
where conversation_id = tests.id('conv_b1');

select is(public.claim_agent_turn(tests.id('conv_b1'), pg_temp.m('m1')), 'claimed', 'an expired lease is claimable again');
select is(public.renew_agent_turn(tests.id('conv_b1'), pg_temp.m('m1')), 'renewed', 'and renewable by the new holder');

select is(
  public.claim_agent_turn('aaaaaaaa-0000-4000-8000-0000000000ff', pg_temp.m('m1')),
  'superseded',
  'a conversation with no registered turn has nothing to claim'
);

-- ---------------------------------------------------------------------------
-- Closed to API roles: the table and the functions are service-role only.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('alice@test.local');
select throws_ok(
  $$ select count(*) from public.agent_turns $$,
  '42501', null, 'user A cannot read turns'
);
select throws_ok(
  $$ select public.claim_agent_turn(tests.id('conv_a1'), pg_temp.m('m3')) $$,
  '42501', null, 'user A cannot claim a turn'
);

select tests.clear_authentication();
select tests.authenticate_as('bob@test.local');
select throws_ok(
  $$ select count(*) from public.agent_turns $$,
  '42501', null, 'user B cannot read turns'
);
select throws_ok(
  $$ select public.begin_agent_turn(tests.id('conv_a1'), pg_temp.m('m3'), now()) $$,
  '42501', null, 'user B cannot register a turn'
);

select tests.clear_authentication();
select tests.authenticate_with_api_key('test-key-a-owner-0000000000000000000');
select throws_ok(
  $$ select public.release_agent_turn(tests.id('conv_a1'), pg_temp.m('m3'), false) $$,
  '42501', null, 'API key A cannot release a turn'
);

select tests.clear_authentication();
select tests.authenticate_with_api_key('test-key-b-member-000000000000000000');
select throws_ok(
  $$ select public.renew_agent_turn(tests.id('conv_b1'), pg_temp.m('m1')) $$,
  '42501', null, 'API key B cannot renew a turn'
);

select tests.clear_authentication();
select tests.authenticate_as_anon();
select throws_ok(
  $$ select count(*) from public.agent_turns $$,
  '42501', null, 'anon cannot read turns'
);

select tests.clear_authentication();

select * from finish();
rollback;
