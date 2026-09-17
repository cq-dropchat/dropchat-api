-- F26 — x-request-id across the database hop.
--
-- Failure scenario: a WhatsApp message crosses webhook → insert → trigger →
-- agent-client → insert → trigger → dispatcher, and every hop logged its own
-- request id: the triggers posted to the next function without the id of the
-- request that wrote the row, so the chain could not be followed in
-- function_logs.
--
-- Now: PostgREST exposes the caller's headers in `request.headers`; the
-- triggers that call Edge Functions (and the dispatch sweep) forward
-- `x-request-id` when it is a UUID, and send nothing otherwise (cron, psql, a
-- client-chosen non-UUID value), so the receiver mints one.
begin;
select plan(13);

create temp table marks as
select (select coalesce(max(id), 0) from net.http_request_queue) as queue_id;

-- The queue rows enqueued since `marks` for a record id.
create function pg_temp.forwarded(_url text, _record uuid) returns text[]
language sql as $$
  select array_agg(coalesce(q.headers ->> 'x-request-id', '<none>') order by q.id)
  from net.http_request_queue q
  where q.id > (select queue_id from marks)
    and q.url like '%' || _url
    and convert_from(q.body, 'utf8')::jsonb #>> '{record,id}' = _record::text;
$$;

select has_function('public', 'request_id_header', array[]::text[], 'request_id_header exists');

-- ---------------------------------------------------------------------------
-- A request id in request.headers is forwarded by every writer.
-- ---------------------------------------------------------------------------

select set_config(
  'request.headers',
  '{"x-request-id": "0f26f26f-0000-4000-8000-00000000a001", "user-agent": "postgrest-test"}',
  true
);

-- edge_function('/agent-client'): an armed inbound message.
insert into public.messages (
  id, organization_id, service, organization_address, conversation_address,
  sender_address, content, status
) values (
  'aaaaaaaa-0000-4000-8000-00000000f26a', tests.id('org_a'), 'whatsapp',
  tests.val('wa_a'), tests.val('contact_a2'), tests.val('contact_a2'),
  '{"version": "1", "type": "text", "kind": "text", "text": "hola"}',
  jsonb_build_object('pending', now())
);

select is(
  pg_temp.forwarded('/agent-client', 'aaaaaaaa-0000-4000-8000-00000000f26a'),
  array['0f26f26f-0000-4000-8000-00000000a001'],
  'edge_function forwards x-request-id to agent-client'
);

-- dispatcher_edge_function: an armed outgoing message.
insert into public.messages (
  id, organization_id, service, organization_address, conversation_address,
  sender_address, agent_id, content, status
) values (
  'aaaaaaaa-0000-4000-8000-00000000f26b', tests.id('org_a'), 'whatsapp',
  tests.val('wa_a'), tests.val('contact_a2'), null, tests.id('agent_alice'),
  '{"version": "1", "type": "text", "kind": "text", "text": "hola, ¿en qué te ayudo?"}',
  jsonb_build_object('pending', now())
);

select is(
  pg_temp.forwarded('/whatsapp-dispatcher', 'aaaaaaaa-0000-4000-8000-00000000f26b'),
  array['0f26f26f-0000-4000-8000-00000000a001'],
  'dispatcher_edge_function forwards x-request-id'
);

select is(
  (select headers ->> 'authorization' like 'Bearer %' from net.http_request_queue
   where id > (select queue_id from marks) and url like '%/whatsapp-dispatcher'
   order by id desc limit 1),
  true,
  'the service token is still sent next to it'
);

-- local_message_to_agent: an AI DM.
insert into public.messages (
  id, organization_id, service, organization_address, conversation_address,
  agent_id, content, status
)
select
  'aaaaaaaa-0000-4000-8000-00000000f26c', tests.id('org_a'), 'local', oa.address,
  (select string_agg(x, ':' order by x) from unnest(array[
    tests.id('agent_alice')::text, tests.id('agent_robot_a')::text]) x),
  tests.id('agent_alice'),
  '{"version": "1", "type": "text", "kind": "text", "text": "hola robot"}',
  jsonb_build_object('pending', now())
from public.organizations_addresses oa
where oa.organization_id = tests.id('org_a') and oa.service = 'local'
limit 1;

select is(
  pg_temp.forwarded('/agent-client', 'aaaaaaaa-0000-4000-8000-00000000f26c'),
  array['0f26f26f-0000-4000-8000-00000000a001'],
  'local_message_to_agent forwards x-request-id'
);

-- dispatch_pending_messages: a candidate one minute old (trigger held so
-- only the sweep enqueues it).
alter table public.messages disable trigger handle_outgoing_message_to_dispatcher;
insert into public.messages (
  id, organization_id, service, organization_address, conversation_address,
  sender_address, agent_id, content, status, timestamp
) values (
  'aaaaaaaa-0000-4000-8000-00000000f26d', tests.id('org_a'), 'whatsapp',
  tests.val('wa_a'), tests.val('contact_a2'), null, tests.id('agent_alice'),
  '{"version": "1", "type": "text", "kind": "text", "text": "barrido"}',
  jsonb_build_object('pending', now()), now() - interval '5 minutes'
);
alter table public.messages enable trigger handle_outgoing_message_to_dispatcher;

select public.dispatch_pending_messages();

select is(
  pg_temp.forwarded('/whatsapp-dispatcher', 'aaaaaaaa-0000-4000-8000-00000000f26d'),
  array['0f26f26f-0000-4000-8000-00000000a001'],
  'dispatch_pending_messages forwards x-request-id when run inside a request'
);

-- Upper case is a valid UUID too; it goes out normalized.
select set_config('request.headers', '{"x-request-id": "0F26F26F-0000-4000-8000-00000000A002"}', true);
select is(
  public.request_id_header(),
  '{"x-request-id": "0f26f26f-0000-4000-8000-00000000a002"}'::jsonb,
  'an upper-case UUID is forwarded lower-cased'
);

-- ---------------------------------------------------------------------------
-- Nothing is forwarded without a valid id.
-- ---------------------------------------------------------------------------

select set_config('request.headers', '{}', true);

insert into public.messages (
  id, organization_id, service, organization_address, conversation_address,
  sender_address, agent_id, content, status
) values (
  'aaaaaaaa-0000-4000-8000-00000000f26e', tests.id('org_a'), 'whatsapp',
  tests.val('wa_a'), tests.val('contact_a2'), null, tests.id('agent_alice'),
  '{"version": "1", "type": "text", "kind": "text", "text": "sin id"}',
  jsonb_build_object('pending', now())
);

select is(
  pg_temp.forwarded('/whatsapp-dispatcher', 'aaaaaaaa-0000-4000-8000-00000000f26e'),
  array['<none>'],
  'without x-request-id the dispatcher request carries none'
);

-- Cron and psql: request.headers is not set at all.
select set_config('request.headers', '', true);
select is(public.request_id_header(), '{}'::jsonb, 'an unset request.headers forwards nothing');

select public.dispatch_pending_messages();
select is(
  pg_temp.forwarded('/whatsapp-dispatcher', 'aaaaaaaa-0000-4000-8000-00000000f26d'),
  array['0f26f26f-0000-4000-8000-00000000a001', '<none>'],
  'the sweep from cron forwards nothing'
);

-- A client controls the header's text: anything but a UUID is dropped.
select set_config(
  'request.headers',
  '{"x-request-id": "abc\r\nx-injected: 1"}',
  true
);
select is(public.request_id_header(), '{}'::jsonb, 'a non-UUID value is dropped');

select set_config('request.headers', '{"x-request-id": ["0f26f26f-0000-4000-8000-00000000a001"]}', true);
select is(public.request_id_header(), '{}'::jsonb, 'a non-string value is dropped');

-- ---------------------------------------------------------------------------
-- Internal: only the SECURITY DEFINER writers call it.
-- ---------------------------------------------------------------------------

select is(
  (select array_agg(r order by r) from unnest(array['anon', 'authenticated', 'service_role']) r
   where has_function_privilege(r, 'public.request_id_header()', 'execute')),
  null,
  'anon, authenticated and service_role cannot execute request_id_header'
);

select * from finish();
rollback;
