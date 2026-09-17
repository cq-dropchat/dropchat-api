-- F07 — init_data is O(N messages of the organization), sorting the whole
-- org on disk, and nothing indexes (organization_id, timestamp).
--
-- Failure scenario: an organization with 200k messages waits 1.2 s per tab
-- open while the query partitions every row it has; a small tenant sweeps
-- other tenants' rows through messages_timestamp_idx. The rewrite must
-- return the same set — the p_limit most recent messages, at most
-- p_per_conversation per conversation — which this test pins against the
-- original formulation, computed inline as the oracle.
begin;
select plan(7);

select has_index(
  'public', 'messages', 'messages_org_timestamp_idx',
  array['organization_id', '"timestamp"', 'id'],
  'messages has an index on (organization_id, timestamp desc, id desc)'
);

-- A denser org A: 8 conversations × 30 messages, spread over 8 hours.
insert into public.messages (
  organization_id, service, organization_address, conversation_address,
  sender_address, external_id, content, status, timestamp
)
select
  tests.id('org_a'), 'whatsapp', tests.val('wa_a'), '54911999000' || c,
  '54911999000' || c, 'wamid.INIT.' || c || '.' || m,
  jsonb_build_object('version', '1', 'type', 'text', 'kind', 'text', 'text', 'c' || c || ' m' || m),
  '{"delivered": "2026-09-05T10:00:00Z"}',
  '2026-09-05T00:00:00Z'::timestamptz + (c * 7 + m * 13) * interval '1 minute'
from generate_series(1, 8) c, generate_series(1, 30) m;

-- The original algorithm, as the oracle: window over the whole org, keep
-- rn <= per_conversation, order by timestamp desc, limit.
create or replace function pg_temp.oracle(p_org uuid, p_limit int, p_per int, p_until timestamptz)
returns setof uuid
language sql
as $$
  with windowed as (
    select m.id, m.timestamp,
      row_number() over (partition by m.conversation_id order by m.timestamp desc, m.id desc) as rn
    from public.messages m
    where m.organization_id = p_org
      and (p_until is null or m.timestamp < p_until)
  )
  select id from windowed where rn <= p_per order by timestamp desc, id desc limit p_limit
$$;

select tests.authenticate_as('alice@test.local');

-- Same ids, same order.
select results_eq(
  $$ select (m->>'id')::uuid
     from json_array_elements((public.init_data(tests.id('org_a'), 50, 5))->'messages') m $$,
  $$ select * from pg_temp.oracle(tests.id('org_a'), 50, 5, null) $$,
  'init_data(50, 5) returns the oracle''s ids in the oracle''s order'
);

select results_eq(
  $$ select (m->>'id')::uuid
     from json_array_elements((public.init_data(tests.id('org_a'), 200, 10))->'messages') m $$,
  $$ select * from pg_temp.oracle(tests.id('org_a'), 200, 10, null) $$,
  'init_data(200, 10) returns the oracle''s ids in the oracle''s order'
);

select results_eq(
  $$ select (m->>'id')::uuid
     from json_array_elements((public.init_data(tests.id('org_a'), 100, 5, null, '2026-09-05T03:00:00Z'))->'messages') m $$,
  $$ select * from pg_temp.oracle(tests.id('org_a'), 100, 5, '2026-09-05T03:00:00Z') $$,
  'init_data with p_until (phase 2) matches the oracle'
);

-- Conversations: exactly those of the returned messages.
select results_eq(
  $$ select (c->>'id')::uuid
     from json_array_elements((public.init_data(tests.id('org_a'), 50, 5))->'conversations') c
     order by 1 $$,
  $$ select distinct m.conversation_id from public.messages m
     where m.id in (select * from pg_temp.oracle(tests.id('org_a'), 50, 5, null))
     order by 1 $$,
  'init_data returns the conversations of the messages it returns'
);

-- RLS still applies: a member of B calling with A''s id gets nothing.
select tests.clear_authentication();
select tests.authenticate_as('bob@test.local');

select is(
  json_array_length((public.init_data(tests.id('org_a'), 50, 5))->'messages'),
  0,
  'init_data is security invoker: B sees none of A''s messages'
);

select is(
  json_array_length((public.init_data(tests.id('org_b'), 50, 5))->'messages'),
  2,
  'init_data for B as B returns B''s messages'
);

select * from finish();
rollback;
