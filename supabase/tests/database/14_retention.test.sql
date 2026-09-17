-- F15 — tables that only grow.
--
-- Failure scenario: every pg_net call from a trigger also inserted a row in
-- supabase_functions.hooks, which nothing reads (~3 M rows/day at 2 M
-- messages/day). public.logs and public.onboarding_tokens had no retention.
--
-- Now: the triggers enqueue their request and write nothing else; the hourly
-- `purge-expired-rows` job empties what hooks already holds and expires logs
-- (90 days) and onboarding tokens (30 days past expiry), in batches.
--
-- The enqueue itself is asserted here too — it is the first hop of trace (a),
-- and the queue row (URL and payload) is visible inside this transaction
-- before pg_net's worker can take it.
begin;
select plan(18);

create temp table marks as
select
  (select coalesce(max(id), 0) from supabase_functions.hooks) as hook_id,
  (select coalesce(max(id), 0) from net.http_request_queue) as queue_id;

-- ---------------------------------------------------------------------------
-- The triggers enqueue, and write nothing else.
-- ---------------------------------------------------------------------------

-- An armed inbound message: agent-client.
insert into public.messages (
  id, organization_id, service, organization_address, conversation_address,
  sender_address, content, status
) values (
  'aaaaaaaa-0000-4000-8000-00000000f15a', tests.id('org_a'), 'whatsapp',
  tests.val('wa_a'), tests.val('contact_a2'), tests.val('contact_a2'),
  '{"version": "1", "type": "text", "kind": "text", "text": "hola"}',
  jsonb_build_object('pending', now())
);

-- F12: agent-client calls go through edge_calls (19_edge_calls covers the
-- worker that sends them).
select is(
  (select count(*)::int from public.edge_calls c
   where c.function = 'agent-client'
     and c.payload #>> '{record,id}' = 'aaaaaaaa-0000-4000-8000-00000000f15a'),
  1,
  'an armed inbound message enqueues agent-client with the row as record'
);

-- An armed outgoing message: the dispatcher.
insert into public.messages (
  id, organization_id, service, organization_address, conversation_address,
  sender_address, agent_id, content, status
) values (
  'aaaaaaaa-0000-4000-8000-00000000f15b', tests.id('org_a'), 'whatsapp',
  tests.val('wa_a'), tests.val('contact_a2'), null, tests.id('agent_alice'),
  '{"version": "1", "type": "text", "kind": "text", "text": "hola, ¿en qué te ayudo?"}',
  jsonb_build_object('pending', now())
);

select is(
  (select count(*)::int from net.http_request_queue q
   where q.id > (select queue_id from marks)
     and q.url like '%/whatsapp-dispatcher'
     and convert_from(q.body, 'utf8')::jsonb #>> '{record,id}' = 'aaaaaaaa-0000-4000-8000-00000000f15b'),
  1,
  'an armed outgoing message enqueues the dispatcher with the row as record'
);

-- A local AI DM (local_message_to_agent, the third writer).
insert into public.messages (
  organization_id, service, organization_address, conversation_address,
  agent_id, content, status
)
select
  tests.id('org_a'), 'local', oa.address,
  (select string_agg(x, ':' order by x) from unnest(array[
    tests.id('agent_alice')::text, tests.id('agent_robot_a')::text]) x),
  tests.id('agent_alice'),
  '{"version": "1", "type": "text", "kind": "text", "text": "hola robot"}',
  jsonb_build_object('pending', now())
from public.organizations_addresses oa
where oa.organization_id = tests.id('org_a') and oa.service = 'local'
limit 1;

select ok(
  (select count(*) from public.edge_calls c where c.function = 'agent-client') >= 2,
  'a local AI DM enqueues agent-client'
);

select is(
  (select count(*)::int from supabase_functions.hooks where id > (select hook_id from marks)),
  0,
  'none of them writes to supabase_functions.hooks'
);

-- ---------------------------------------------------------------------------
-- Retention.
-- ---------------------------------------------------------------------------

select has_function('public', 'purge_expired_rows', array['integer'], 'purge_expired_rows exists');

-- What the table already holds from before this change.
insert into supabase_functions.hooks (hook_table_id, hook_name, request_id)
select 'public.messages'::regclass::oid::int, 'legacy', g from generate_series(1, 5) g;

insert into public.logs (organization_id, level, category, message, created_at) values
  (tests.id('org_a'), 'error', 'f15', 'old', now() - interval '91 days'),
  (tests.id('org_a'), 'error', 'f15', 'older', now() - interval '400 days'),
  (tests.id('org_a'), 'error', 'f15', 'recent', now() - interval '89 days');

insert into public.onboarding_tokens (name, organization_id, expires_at, status, service) values
  ('f15-long-expired', tests.id('org_a'), now() - interval '31 days', 'expired', 'whatsapp'),
  ('f15-used-long-ago', tests.id('org_a'), now() - interval '60 days', 'used', 'whatsapp'),
  ('f15-just-expired', tests.id('org_a'), now() - interval '1 day', 'expired', 'whatsapp'),
  ('f15-active', tests.id('org_a'), now() + interval '7 days', 'active', 'whatsapp');

-- A small batch leaves work for the next run.
select is(
  (public.purge_expired_rows(2) ->> 'hooks')::int,
  2,
  'one run deletes at most its batch per table'
);

-- Runs until nothing is left to purge.
do $$
begin
  for i in 1..1000 loop
    exit when (select (r->>'hooks')::int + (r->>'logs')::int + (r->>'onboarding_tokens')::int = 0
               from (select public.purge_expired_rows(1000) as r) x);
  end loop;
end;
$$;

select is((select count(*)::int from supabase_functions.hooks), 0, 'hooks is emptied');

select is(
  (select count(*)::int from public.logs where category = 'f15' and message in ('old', 'older')),
  0, 'logs older than 90 days are deleted'
);
select is(
  (select count(*)::int from public.logs where category = 'f15' and message = 'recent'),
  1, 'a log inside the window stays'
);

select is(
  (select count(*)::int from public.onboarding_tokens where name in ('f15-long-expired', 'f15-used-long-ago')),
  0, 'tokens expired more than 30 days ago are deleted, used or not'
);
select is(
  (select count(*)::int from public.onboarding_tokens where name = 'f15-just-expired'),
  1, 'a token expired yesterday stays (support can still see why a link failed)'
);
select is(
  (select count(*)::int from public.onboarding_tokens where name = 'f15-active'),
  1, 'an active token stays'
);

select is(
  (select count(*)::int from cron.job where jobname = 'purge-expired-rows'),
  1, 'the purge is scheduled'
);

-- ---------------------------------------------------------------------------
-- Service role only.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('alice@test.local');
select throws_ok(
  $$ select public.purge_expired_rows(10) $$,
  '42501', null, 'an owner cannot run the purge'
);
select tests.clear_authentication();

select tests.authenticate_as('bob@test.local');
select throws_ok(
  $$ select public.purge_expired_rows(10) $$,
  '42501', null, 'user B cannot run the purge'
);
select tests.clear_authentication();

select tests.authenticate_with_api_key('test-key-a-owner-0000000000000000000');
select throws_ok(
  $$ select public.purge_expired_rows(10) $$,
  '42501', null, 'API key A (owner) cannot run the purge'
);
select tests.clear_authentication();

select tests.authenticate_with_api_key('test-key-b-member-000000000000000000');
select throws_ok(
  $$ select public.purge_expired_rows(10) $$,
  '42501', null, 'API key B cannot run the purge'
);
select tests.clear_authentication();

select tests.authenticate_as_anon();
select throws_ok(
  $$ select public.purge_expired_rows(10) $$,
  '42501', null, 'anon cannot run the purge'
);
select tests.clear_authentication();

select * from finish();
rollback;
