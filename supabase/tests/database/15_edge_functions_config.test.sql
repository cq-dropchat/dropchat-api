-- F24 — Vault reads per insert.
--
-- Failure scenario: dispatcher_edge_function, edge_function,
-- local_message_to_agent and dispatch_pending_messages each read
-- vault.decrypted_secrets twice (URL, then token) with its own copy of the
-- query: an outgoing message with a file ran four Vault queries in its
-- triggers.
--
-- Now: one SECURITY DEFINER helper, public.edge_functions_config(), reads
-- both in one query; no other function in `public` touches Vault, and no
-- role other than the owner can call it (it returns the service token).
--
-- Not done: caching the pair per transaction in a GUC (`set_config(…,
-- true)`) would save the decryptions too, but would leave the token readable
-- by `current_setting()` for the rest of the transaction.
begin;
select plan(13);

select has_function('public', 'edge_functions_config', 'edge_functions_config exists');

select is(
  (select row(c.url, c.token)::text from public.edge_functions_config() c),
  (select row(
     (select decrypted_secret from vault.decrypted_secrets where name = 'edge_functions_url'),
     (select decrypted_secret from vault.decrypted_secrets where name = 'edge_functions_token')
   )::text),
  'it returns the URL and token stored in Vault'
);

select is(
  (select array_agg(p.proname::text order by p.proname)
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prosrc ilike '%vault.decrypted_secrets%'),
  array['edge_functions_config'],
  'no other function in public reads Vault'
);

-- ---------------------------------------------------------------------------
-- The triggers still send the token (first hop of every trace).
-- ---------------------------------------------------------------------------

create temp table marks as
select (select coalesce(max(id), 0) from net.http_request_queue) as queue_id;

insert into public.messages (
  id, organization_id, service, organization_address, conversation_address,
  sender_address, agent_id, content, status
) values (
  'aaaaaaaa-0000-4000-8000-00000000f24b', tests.id('org_a'), 'whatsapp',
  tests.val('wa_a'), tests.val('contact_a2'), null, tests.id('agent_alice'),
  '{"version": "1", "type": "text", "kind": "text", "text": "hola"}',
  jsonb_build_object('pending', now())
);

select is(
  (select q.headers ->> 'authorization' from net.http_request_queue q
   where q.id > (select queue_id from marks) and q.url like '%/whatsapp-dispatcher'
   order by q.id desc limit 1),
  'Bearer ' || (select token from public.edge_functions_config()),
  'the dispatcher request carries the token'
);

select is(
  (select q.url from net.http_request_queue q
   where q.id > (select queue_id from marks) and q.url like '%/whatsapp-dispatcher'
   order by q.id desc limit 1),
  (select url from public.edge_functions_config()) || '/whatsapp-dispatcher',
  'the dispatcher request goes to the configured URL'
);

insert into public.messages (
  id, organization_id, service, organization_address, conversation_address,
  sender_address, content, status
) values (
  'aaaaaaaa-0000-4000-8000-00000000f24a', tests.id('org_a'), 'whatsapp',
  tests.val('wa_a'), tests.val('contact_a2'), tests.val('contact_a2'),
  '{"version": "1", "type": "text", "kind": "text", "text": "hola"}',
  jsonb_build_object('pending', now())
);

-- F12: agent-client calls are queued (edge_calls) and sent by the worker,
-- which reads the token through edge_functions_config.
select public.dispatch_edge_calls(1000, 1000);
select is(
  (select q.headers ->> 'authorization' from net.http_request_queue q
   where q.id > (select queue_id from marks) and q.url like '%/agent-client'
   order by q.id desc limit 1),
  'Bearer ' || (select token from public.edge_functions_config()),
  'the agent-client request (sent by the edge call worker) carries the token'
);

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

select public.dispatch_edge_calls(1000, 1000);
select is(
  (select count(*)::int from net.http_request_queue q
   where q.id > (select queue_id from marks) and q.url like '%/agent-client'
     and q.headers ->> 'authorization' = 'Bearer ' || (select token from public.edge_functions_config())),
  2,
  'the local AI DM request (queued by local_message_to_agent) carries the token'
);

-- ---------------------------------------------------------------------------
-- Nobody but the owner calls it.
-- ---------------------------------------------------------------------------

select ok(
  not has_function_privilege('service_role', 'public.edge_functions_config()', 'execute'),
  'service_role cannot execute it'
);

select tests.authenticate_as('alice@test.local');
select throws_ok(
  $$ select public.edge_functions_config() $$,
  '42501', null, 'user A cannot read the edge functions token'
);
select tests.clear_authentication();

select tests.authenticate_as('bob@test.local');
select throws_ok(
  $$ select public.edge_functions_config() $$,
  '42501', null, 'user B cannot read the edge functions token'
);
select tests.clear_authentication();

select tests.authenticate_with_api_key('test-key-a-owner-0000000000000000000');
select throws_ok(
  $$ select public.edge_functions_config() $$,
  '42501', null, 'API key A cannot read the edge functions token'
);
select tests.clear_authentication();

select tests.authenticate_with_api_key('test-key-b-member-000000000000000000');
select throws_ok(
  $$ select public.edge_functions_config() $$,
  '42501', null, 'API key B cannot read the edge functions token'
);
select tests.clear_authentication();

select tests.authenticate_as_anon();
select throws_ok(
  $$ select public.edge_functions_config() $$,
  '42501', null, 'anon cannot read the edge functions token'
);
select tests.clear_authentication();

select * from finish();
rollback;
