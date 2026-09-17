-- F11 — the per-minute dispatch sweep.
--
-- Failure scenario: the insert trigger fires the dispatcher and, a minute
-- later, the cron fires it again for any row still pending without
-- `accepted`. If Meta takes longer than that, the message is sent twice.
-- A transient error is retried every minute for 12 hours (720 calls), and
-- the sweep reads the whole 12-hour window through messages_timestamp_idx.
begin;
select plan(16);

select has_index(
  'public', 'messages', 'messages_dispatch_pending_idx',
  'a partial index serves the dispatch sweep'
);

-- An outgoing armed row, old enough for the sweep (inserted with the
-- dispatch trigger held so the test controls every attempt).
alter table public.messages disable trigger handle_outgoing_message_to_dispatcher;

insert into public.messages (
  id, organization_id, service, organization_address, conversation_address,
  sender_address, agent_id, content, timestamp
) values (
  'aaaaaaaa-0000-4000-8000-00000000f1a1', tests.id('org_a'), 'whatsapp',
  tests.val('wa_a'), tests.val('contact_a1'), null, tests.id('agent_alice'),
  '{"version": "1", "type": "text", "kind": "text", "text": "send me once"}',
  now() - interval '5 minutes'
);

alter table public.messages enable trigger handle_outgoing_message_to_dispatcher;

create temp view mine as
select * from public.messages where id = 'aaaaaaaa-0000-4000-8000-00000000f1a1';

select ok(
  'aaaaaaaa-0000-4000-8000-00000000f1a1' in (select id from public.pending_dispatch_candidates()),
  'a pending outgoing row is a sweep candidate'
);

-- ---------------------------------------------------------------------------
-- Lease.
-- ---------------------------------------------------------------------------

select is(public.claim_message_dispatch('aaaaaaaa-0000-4000-8000-00000000f1a1'), true, 'the first claim wins');
select is(public.claim_message_dispatch('aaaaaaaa-0000-4000-8000-00000000f1a1'), false, 'a second claim while the lease is fresh loses');

select ok(
  (select status ? 'dispatching' from mine),
  'the claim stamps status.dispatching'
);

select ok(
  'aaaaaaaa-0000-4000-8000-00000000f1a1' not in (select id from public.pending_dispatch_candidates()),
  'a row with a fresh lease is not a sweep candidate'
);

-- A lease older than two minutes is a crashed invocation: the row is
-- claimable again.
update public.messages
set status = jsonb_build_object('dispatching', now() - interval '3 minutes')
where id = 'aaaaaaaa-0000-4000-8000-00000000f1a1';

select ok(
  'aaaaaaaa-0000-4000-8000-00000000f1a1' in (select id from public.pending_dispatch_candidates()),
  'a stale lease makes the row a candidate again'
);

select is(public.claim_message_dispatch('aaaaaaaa-0000-4000-8000-00000000f1a1'), true, 'and claimable again');

-- ---------------------------------------------------------------------------
-- Backoff.
-- ---------------------------------------------------------------------------

select public.release_message_dispatch(
  'aaaaaaaa-0000-4000-8000-00000000f1a1',
  '[{"code": 130429, "title": "Rate limit hit"}]'
);

select is((select (status->>'attempts')::int from mine), 1, 'a transient failure counts one attempt');
select ok(not (select status ? 'dispatching' from mine), 'and releases the lease');
select ok((select status ? 'pending' from mine), 'and keeps the row armed');
select ok(
  (select (status->>'retry_at')::timestamptz - now() between interval '50 seconds' and interval '70 seconds' from mine),
  'the first retry is one minute out'
);
select ok(
  'aaaaaaaa-0000-4000-8000-00000000f1a1' not in (select id from public.pending_dispatch_candidates()),
  'a row waiting for its retry is not a candidate'
);

-- Fourth failure: 8 minutes.
update public.messages
set status = '{"attempts": 3}'
where id = 'aaaaaaaa-0000-4000-8000-00000000f1a1';
select public.claim_message_dispatch('aaaaaaaa-0000-4000-8000-00000000f1a1');
select public.release_message_dispatch('aaaaaaaa-0000-4000-8000-00000000f1a1', '[]');

select ok(
  (select (status->>'retry_at')::timestamptz - now() between interval '7 minutes' and interval '9 minutes' from mine),
  'backoff doubles: the fourth failure waits eight minutes'
);

-- Due again.
update public.messages
set status = jsonb_build_object('retry_at', now() - interval '1 second')
where id = 'aaaaaaaa-0000-4000-8000-00000000f1a1';

select ok(
  'aaaaaaaa-0000-4000-8000-00000000f1a1' in (select id from public.pending_dispatch_candidates()),
  'a row whose retry is due is a candidate'
);

-- The sweep itself enqueues exactly the candidates.
select is(
  public.dispatch_pending_messages(),
  (select count(*)::int from public.pending_dispatch_candidates()),
  'dispatch_pending_messages posts one request per candidate'
);

select * from finish();
rollback;
