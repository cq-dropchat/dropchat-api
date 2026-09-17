-- The service-only functions behind the dispatch sweep (F11) and webhook
-- delivery (F05/F06).
--
-- Failure scenario: their migrations revoked execute from `public` only.
-- Supabase's default privileges grant execute on new functions to anon and
-- authenticated BY NAME, so every one stayed callable over PostgREST RPC —
-- and they are SECURITY DEFINER. Anyone with the anon key could list every
-- tenant's pending outgoing messages (pending_dispatch_candidates returns
-- whole rows), stall or reschedule any message's dispatch, and fire the
-- dispatch and webhook sweeps at will.
begin;
select plan(24);

-- A pending outgoing row in org A (dispatch trigger held).
alter table public.messages disable trigger handle_outgoing_message_to_dispatcher;
insert into public.messages (
  id, organization_id, service, organization_address, conversation_address,
  sender_address, agent_id, content, timestamp
) values (
  'aaaaaaaa-0000-4000-8000-00000000f1c1', tests.id('org_a'), 'whatsapp',
  tests.val('wa_a'), tests.val('contact_a1'), null, tests.id('agent_alice'),
  '{"version": "1", "type": "text", "kind": "text", "text": "private to org A"}',
  now() - interval '5 minutes'
);
alter table public.messages enable trigger handle_outgoing_message_to_dispatcher;

-- ---------------------------------------------------------------------------
-- Privileges: neither API role may execute them.
-- ---------------------------------------------------------------------------

create temp table service_only (fn text);
insert into service_only values
  ('public.pending_dispatch_candidates()'),
  ('public.claim_message_dispatch(uuid)'),
  ('public.release_message_dispatch(uuid, jsonb)'),
  ('public.dispatch_pending_messages()'),
  ('public.record_webhook_result(uuid, integer, text)'),
  ('public.settle_webhook_deliveries()'),
  ('public.dispatch_webhook_deliveries(integer)'),
  ('public.deliver_webhooks()'),
  ('public.begin_agent_turn(uuid, uuid, timestamp with time zone)'),
  ('public.claim_agent_turn(uuid, uuid)'),
  ('public.request_address_deletion(uuid, public.service, text, text)'),
  ('public.sweep_deletions(integer)'),
  ('public.purge_expired_rows(integer)'),
  ('public.request_id_header()'),
  ('public.pending_deletion_media(integer)'),
  ('public.forget_deletion_media(uuid, text[])'),
  ('public.claim_organization_export()'),
  ('public.record_edge_call_result(uuid, integer, boolean, text)'),
  ('public.settle_edge_calls()'),
  ('public.dispatch_edge_calls(integer, integer)'),
  ('public.deliver_edge_calls()'),
  ('public.sweep_pending_media(integer)'),
  ('public.finish_organization_export(uuid, text, text)'),
  ('public.expired_organization_exports(integer)'),
  ('public.mark_organization_export_expired(uuid)'),
  ('billing.renew_subscriptions(integer)'),
  ('billing.grant_included_products(uuid, text, timestamp with time zone)');

select is(
  (select array_agg(fn order by fn) from service_only
   where has_function_privilege('anon', fn::regprocedure, 'execute')),
  null,
  'anon executes none of the service-only functions'
);
select is(
  (select array_agg(fn order by fn) from service_only
   where has_function_privilege('authenticated', fn::regprocedure, 'execute')),
  null,
  'authenticated executes none of the service-only functions'
);
select ok(
  (select bool_and(has_function_privilege('service_role', fn::regprocedure, 'execute')) from service_only
   where fn not like '%agent_turn%' and fn not like '%sweep_deletions%' and fn not like '%purge_expired_rows%'
     and fn not like '%request_id_header%'
     and fn not like 'billing.%'),
  'service_role still executes them'
);

-- ---------------------------------------------------------------------------
-- Behaviour, per caller: the leak and the lease tampering are refused.
-- ---------------------------------------------------------------------------

create function pg_temp.refused(_who text) returns setof text language plpgsql as $$
begin
  return next throws_ok(
    $q$ select * from public.pending_dispatch_candidates() $q$,
    '42501', null, _who || ' cannot list pending messages'
  );
  return next throws_ok(
    $q$ select public.claim_message_dispatch('aaaaaaaa-0000-4000-8000-00000000f1c1') $q$,
    '42501', null, _who || ' cannot claim a dispatch lease'
  );
  return next throws_ok(
    $q$ select public.release_message_dispatch('aaaaaaaa-0000-4000-8000-00000000f1c1', '[]') $q$,
    '42501', null, _who || ' cannot reschedule a dispatch'
  );
  return next throws_ok(
    $q$ select public.dispatch_pending_messages() $q$,
    '42501', null, _who || ' cannot fire the dispatch sweep'
  );
end;
$$;

select tests.authenticate_as('alice@test.local');
select pg_temp.refused('user A');
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
select pg_temp.refused('anon');
select tests.clear_authentication();

-- The lease was never touched by any of them.
select ok(
  not (select status ? 'dispatching' or status ? 'attempts' from public.messages
       where id = 'aaaaaaaa-0000-4000-8000-00000000f1c1'),
  'the row''s dispatch state is untouched'
);

select * from finish();
rollback;
