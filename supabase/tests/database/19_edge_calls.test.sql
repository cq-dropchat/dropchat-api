-- F12 — agent-client and media-preprocessor were called straight from the
-- message triggers with net.http_post.
--
-- Failure scenario: every call rode one pg_net worker per database with no
-- retry (a 503 or a lost connection dropped the agent's reply or the media
-- transcription for good), no fairness (one organization's burst queued in
-- front of everyone else's messages), no metric, and a 10 s timeout that
-- marked agent-client invocations that went on to finish as timed out.
--
-- Now the triggers insert into public.edge_calls. deliver_edge_calls(), run by
-- pg_cron every 5 seconds, settles the previous attempts from
-- net._http_response and sends what is due with SKIP LOCKED, at most
-- _per_org calls per organization per tick, retrying with backoff and
-- failing after the fifth attempt. edge_calls_health shows the backlog.
begin;
select plan(39);

create temp table marks as
select (select coalesce(max(id), 0) from net.http_request_queue) as queue_id;

create function pg_temp.requests(_path text) returns bigint language sql as $$
  select count(*) from net.http_request_queue q
  where q.id > (select queue_id from marks) and q.url like '%' || _path;
$$;

select has_table('public', 'edge_calls', 'edge_calls exists');

-- ---------------------------------------------------------------------------
-- The triggers enqueue here, not in pg_net.
-- ---------------------------------------------------------------------------

select set_config('request.headers', '{"x-request-id": "0f12f12f-0000-4000-8000-00000000a001"}', true);

insert into public.messages (
  id, organization_id, service, organization_address, conversation_address,
  sender_address, content, status
) values (
  'aaaaaaaa-0000-4000-8000-00000000f12a', tests.id('org_a'), 'whatsapp',
  tests.val('wa_a'), tests.val('contact_a2'), tests.val('contact_a2'),
  '{"version": "1", "type": "text", "kind": "text", "text": "hola"}',
  jsonb_build_object('pending', now())
);

select is(
  (select count(*)::int from public.edge_calls
   where record_id = 'aaaaaaaa-0000-4000-8000-00000000f12a' and function = 'agent-client'
     and status = 'pending' and organization_id = tests.id('org_a')),
  1,
  'an armed inbound message enqueues one agent-client call'
);
select is(
  (select payload #>> '{record,id}' from public.edge_calls
   where record_id = 'aaaaaaaa-0000-4000-8000-00000000f12a'),
  'aaaaaaaa-0000-4000-8000-00000000f12a',
  'with the trigger payload (the row as record)'
);
select is(
  (select forward_headers from public.edge_calls
   where record_id = 'aaaaaaaa-0000-4000-8000-00000000f12a'),
  '{"x-request-id": "0f12f12f-0000-4000-8000-00000000a001"}'::jsonb,
  'and the request id to forward (F26)'
);
select is(pg_temp.requests('/agent-client'), 0::bigint, 'and nothing in pg_net''s queue');

insert into public.messages (
  id, organization_id, service, organization_address, conversation_address,
  sender_address, content, status
) values (
  'aaaaaaaa-0000-4000-8000-00000000f12b', tests.id('org_a'), 'whatsapp',
  tests.val('wa_a'), tests.val('contact_a2'), tests.val('contact_a2'),
  jsonb_build_object('version', '1', 'type', 'file', 'kind', 'image',
    'file', jsonb_build_object('uri', 'internal://media/' || tests.val('media_a'), 'mime_type', 'image/jpeg', 'size', 1024)),
  jsonb_build_object('pending', now())
);

select is(
  (select array_agg(function order by function) from public.edge_calls
   where record_id = 'aaaaaaaa-0000-4000-8000-00000000f12b'),
  array['agent-client', 'media-preprocessor'],
  'an armed inbound file enqueues agent-client and media-preprocessor'
);
select is(pg_temp.requests('/media-preprocessor'), 0::bigint, 'media-preprocessor is not in pg_net''s queue');

insert into public.messages (
  id, organization_id, service, organization_address, conversation_address,
  agent_id, content, status
)
select
  'aaaaaaaa-0000-4000-8000-00000000f12c', tests.id('org_a'), 'local', oa.address,
  (select string_agg(x, ':' order by x) from unnest(array[
    tests.id('agent_alice')::text, tests.id('agent_robot_a')::text]) x),
  tests.id('agent_alice'),
  '{"version": "1", "type": "text", "kind": "text", "text": "hola robot"}',
  jsonb_build_object('pending', now())
from public.organizations_addresses oa
where oa.organization_id = tests.id('org_a') and oa.service = 'local'
limit 1;

select is(
  (select count(*)::int from public.edge_calls
   where record_id = 'aaaaaaaa-0000-4000-8000-00000000f12c' and function = 'agent-client'),
  1,
  'a local AI DM enqueues agent-client'
);
select is(pg_temp.requests('/agent-client'), 0::bigint, 'still nothing in pg_net''s queue');

select set_config('request.headers', '{}', true);

-- ---------------------------------------------------------------------------
-- Fairness: 100 calls of A queued before 1 of B.
-- ---------------------------------------------------------------------------

delete from public.edge_calls;

insert into public.edge_calls (organization_id, function, record_id, payload, created_at, next_attempt_at)
select tests.id('org_a'), 'agent-client', gen_random_uuid(), '{"record": {}}'::jsonb,
       now() - interval '1 minute' + g * interval '10 milliseconds',
       now() - interval '1 minute' + g * interval '10 milliseconds'
from generate_series(1, 100) g;

insert into public.edge_calls (id, organization_id, function, record_id, payload, forward_headers)
values ('bbbbbbbb-0000-4000-8000-00000000f12b', tests.id('org_b'), 'agent-client', gen_random_uuid(),
        '{"record": {"id": "b"}}'::jsonb, '{"x-request-id": "0f12f12f-0000-4000-8000-00000000b001"}');

select is(public.dispatch_edge_calls(20, 10), 11, 'one tick sends up to _per_org per organization');
select is(
  (select status from public.edge_calls where id = 'bbbbbbbb-0000-4000-8000-00000000f12b'),
  'sending',
  'B''s call goes out in the first tick, ahead of A''s backlog'
);
select is(
  (select count(*)::int from public.edge_calls where organization_id = tests.id('org_a') and status = 'sending'),
  10,
  'A gets its share, not the whole batch'
);
select is(pg_temp.requests('/agent-client'), 11::bigint, 'one pg_net request per call sent');

create temp table b_request as
select q.* from net.http_request_queue q
join public.edge_calls c on c.request_id = q.id
where c.id = 'bbbbbbbb-0000-4000-8000-00000000f12b';

select is(
  (select convert_from(body, 'utf8')::jsonb from b_request),
  '{"record": {"id": "b"}}'::jsonb,
  'the request body is the queued payload'
);
select ok(
  (select headers ->> 'authorization' like 'Bearer %' and headers ->> 'x-request-id' = '0f12f12f-0000-4000-8000-00000000b001'
   from b_request),
  'with the service token and the forwarded request id'
);
select is(
  (select attempts from public.edge_calls where id = 'bbbbbbbb-0000-4000-8000-00000000f12b'),
  1,
  'the attempt is counted'
);

select is(public.dispatch_edge_calls(20, 10), 10, 'the next tick continues A''s backlog');

-- ---------------------------------------------------------------------------
-- Settling from pg_net's responses.
-- ---------------------------------------------------------------------------

create temp table sent as
select c.id, c.request_id, row_number() over (order by c.request_id) as n
from public.edge_calls c where c.status = 'sending';

-- 1: 200 → done. 2: timed out → done (the function keeps running).
-- 3: 503 → retry. 4: connection error → retry. 5: 401 → failed at once.
-- 6: 429 → retry. The rest: no response yet.
insert into net._http_response (id, status_code, timed_out, error_msg, created)
select request_id,
  case n when 1 then 200 when 3 then 503 when 5 then 401 when 6 then 429 end,
  n = 2,
  case n when 4 then 'Couldn''t connect to server' end,
  now()
from sent where n <= 6;

select is(public.settle_edge_calls(), 6, 'settle handles the calls pg_net has answered');

select is((select status from public.edge_calls where id = (select id from sent where n = 1)), 'done', 'a 2xx is done');
select ok(
  (select status = 'done' and last_error like '%timed out%' from public.edge_calls where id = (select id from sent where n = 2)),
  'a pg_net timeout is done, not retried: the function keeps running'
);
select ok(
  (select status = 'pending' and next_attempt_at > now() and last_status_code = 503
   from public.edge_calls where id = (select id from sent where n = 3)),
  'a 5xx is retried later'
);
select ok(
  (select status = 'pending' and last_error like '%connect%' from public.edge_calls where id = (select id from sent where n = 4)),
  'a connection error is retried'
);
select is((select status from public.edge_calls where id = (select id from sent where n = 5)), 'failed', 'a 401 fails at once');
select is((select status from public.edge_calls where id = (select id from sent where n = 6)), 'pending', 'a 429 is retried');
select is(
  (select status from public.edge_calls where id = (select id from sent where n = 7)),
  'sending',
  'a call without a response yet stays in flight'
);

-- In flight for over two minutes with no response: retried.
update public.edge_calls set locked_until = now() - interval '1 second' where id = (select id from sent where n = 7);
select is(public.settle_edge_calls(), 1, 'a call whose lease ran out without a response is settled');
select is((select status from public.edge_calls where id = (select id from sent where n = 7)), 'pending', 'and retried');

-- ---------------------------------------------------------------------------
-- Backoff and failure.
-- ---------------------------------------------------------------------------

select ok(
  public.edge_call_retry_delay(1) < public.edge_call_retry_delay(2)
  and public.edge_call_retry_delay(2) < public.edge_call_retry_delay(3)
  and public.edge_call_retry_delay(3) < public.edge_call_retry_delay(4),
  'the backoff grows'
);

update public.edge_calls set attempts = 5, status = 'sending', request_id = 999999001
where id = (select id from sent where n = 3);
insert into net._http_response (id, status_code, timed_out, created) values (999999001, 500, false, now());
select public.settle_edge_calls();
select ok(
  (select status = 'failed' and last_status_code = 500 from public.edge_calls where id = (select id from sent where n = 3)),
  'the fifth failed attempt is final'
);

-- A retry that is not due yet is not sent.
select is(
  (select count(*)::int from public.edge_calls c
   where c.id in (select id from sent where n in (4, 6)) and c.status = 'sending'),
  0,
  'a tick before the retry is due does not send it'
) from (select public.dispatch_edge_calls(1000, 1000)) x;

-- ---------------------------------------------------------------------------
-- Health view.
-- ---------------------------------------------------------------------------

select ok(
  (select pending > 0 and oldest_pending_at is not null
   from public.edge_calls_health where function = 'agent-client' and organization_id = tests.id('org_a')),
  'edge_calls_health shows the backlog per function and organization'
);
select ok(
  (select failed >= 2 from public.edge_calls_health where function = 'agent-client' and organization_id = tests.id('org_a')),
  'and the failed calls'
);

select is(
  (select count(*)::int from cron.job where jobname = 'deliver-edge-calls' and schedule = '5 seconds'),
  1,
  'deliver-edge-calls runs every 5 seconds'
);

-- ---------------------------------------------------------------------------
-- Service only.
-- ---------------------------------------------------------------------------

create function pg_temp.refused(_who text) returns setof text language plpgsql as $$
begin
  return next throws_ok(
    $q$ select public.deliver_edge_calls() $q$,
    '42501', null, _who || ' cannot run the edge call worker'
  );
end;
$$;

select tests.authenticate_as('alice@test.local');
select pg_temp.refused('user A');
select throws_ok(
  $$ select count(*) from public.edge_calls $$,
  '42501', null, 'user A cannot read the queue'
);
select tests.clear_authentication();

select tests.authenticate_as('bob@test.local');
select pg_temp.refused('user B');
select tests.clear_authentication();

select tests.authenticate_with_api_key('test-key-a-owner-0000000000000000000');
select pg_temp.refused('API key A');
select tests.clear_authentication();

select tests.authenticate_with_api_key('test-key-b-member-000000000000000000');
select pg_temp.refused('API key B');
select tests.clear_authentication();

select tests.authenticate_as_anon();
select throws_ok(
  $$ select * from public.edge_calls_health $$,
  '42501', null, 'anon cannot read the health view'
);
select tests.clear_authentication();

select * from finish();
rollback;
