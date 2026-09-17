-- F10 — Realtime delivered changes as postgres_changes on conversations and
-- messages filtered by organization only.
--
-- Failure scenario: for every change Realtime evaluated the messages policy
-- (three set-returning helpers) once per subscriber, and every tab got the
-- whole row — content included — of every status update in the
-- organization. At the target scale (50 tabs, 50 events/s) that is up to
-- 2,500 policy evaluations a second.
--
-- Now triggers broadcast to private channels, authorized once per join by
-- policies on realtime.messages:
--   org:<org_id>     a minimal notice (ids, updated_at, the status keys that
--                    changed) for conversations shared with the whole org
--   agent:<agent_id> the same notice, for a conversation only some members
--                    see (a personal account, a restricted local/Slack one):
--                    one per member who sees it — never on org:
--   conv:<conv_id>   the full row, for the open conversation
begin;
select plan(26);

select has_function('public', 'broadcast_realtime_change', array[]::text[], 'broadcast_realtime_change exists');

create temp table marks as select now() - interval '1 second' as t0;

create function pg_temp.notices(_topic text) returns setof jsonb language sql as $$
  select m.payload from realtime.messages m
  where m.topic = _topic and m.inserted_at >= (select t0 from marks)::timestamp
  order by m.inserted_at;
$$;

-- ---------------------------------------------------------------------------
-- A shared conversation (the org's WhatsApp inbox).
-- ---------------------------------------------------------------------------

insert into public.messages (
  id, organization_id, service, organization_address, conversation_address,
  sender_address, content, status
) values (
  'aaaaaaaa-0000-4000-8000-00000000f10a', tests.id('org_a'), 'whatsapp',
  tests.val('wa_a'), tests.val('contact_a1'), tests.val('contact_a1'),
  '{"version": "1", "type": "text", "kind": "text", "text": "secreto del cliente"}',
  '{"delivered": "2026-09-10T10:00:00Z"}'
);

select is(
  (select count(*)::int from pg_temp.notices('org:' || tests.id('org_a')) n
   where n ->> 'table' = 'messages' and n ->> 'id' = 'aaaaaaaa-0000-4000-8000-00000000f10a'),
  1,
  'a message insert notifies org:A'
);
select ok(
  (select n ? 'conversation_id' and n ? 'updated_at' and n ->> 'op' = 'INSERT'
   from pg_temp.notices('org:' || tests.id('org_a')) n
   where n ->> 'id' = 'aaaaaaaa-0000-4000-8000-00000000f10a'),
  'with the ids, updated_at and the operation'
);
select ok(
  (select bool_and(not (n ? 'content') and n::text not like '%secreto del cliente%')
   from pg_temp.notices('org:' || tests.id('org_a')) n),
  'and never the content'
);
select is(
  (select n #>> '{record,content,text}' from pg_temp.notices('conv:' || tests.id('conv_a1')) n
   where n #>> '{record,id}' = 'aaaaaaaa-0000-4000-8000-00000000f10a'),
  'secreto del cliente',
  'conv:<id> carries the full row'
);

update public.messages set status = '{"read": "2026-09-10T10:01:00Z"}'
where id = 'aaaaaaaa-0000-4000-8000-00000000f10a';

select is(
  (select n -> 'status_changed' from pg_temp.notices('org:' || tests.id('org_a')) n
   where n ->> 'id' = 'aaaaaaaa-0000-4000-8000-00000000f10a' and n ->> 'op' = 'UPDATE'),
  '["read"]'::jsonb,
  'a status update notifies which status keys changed, without the row'
);

update public.conversations set name = 'Carla B.' where id = tests.id('conv_a1');

select ok(
  (select count(*) = 1 and bool_and(not (n ? 'name'))
   from pg_temp.notices('org:' || tests.id('org_a')) n
   where n ->> 'table' = 'conversations' and n ->> 'id' = tests.id('conv_a1')::text),
  'a conversation update notifies org:A too, without its columns'
);

select is(
  (select count(*)::int from pg_temp.notices('org:' || tests.id('org_b'))),
  0,
  'nothing reaches org:B'
);

-- ---------------------------------------------------------------------------
-- A restricted conversation: Alice's local DM with the AI agent.
-- ---------------------------------------------------------------------------

insert into public.messages (organization_id, service, organization_address, conversation_address, agent_id, content, status)
select tests.id('org_a'), 'local', oa.address,
  (select string_agg(x, ':' order by x) from unnest(array[tests.id('agent_alice')::text, tests.id('agent_robot_a')::text]) x),
  tests.id('agent_alice'),
  '{"version": "1", "type": "text", "kind": "text", "text": "solo para Alice"}',
  '{"delivered": "2026-09-10T10:00:00Z"}'
from public.organizations_addresses oa
where oa.organization_id = tests.id('org_a') and oa.service = 'local';

create temp table dm as
select id from public.conversations
where organization_id = tests.id('org_a') and service = 'local' and type = 'direct'
order by created_at desc limit 1;
grant select on dm to anon, authenticated;

select is(
  (select count(*)::int from pg_temp.notices('org:' || tests.id('org_a')) n
   where n ->> 'conversation_id' = (select id from dm)::text or n ->> 'id' = (select id from dm)::text),
  0,
  'a restricted conversation never appears on org:A'
);
select ok(
  (select count(*) >= 1 from pg_temp.notices('agent:' || tests.id('agent_alice')) n
   where n ->> 'conversation_id' = (select id from dm)::text),
  'its participant Alice is notified on agent:<alice>'
);
select is(
  (select count(*)::int from pg_temp.notices('agent:' || tests.id('agent_amber'))),
  0,
  'Amber (same org, not a participant) is not'
);
select is(
  (select count(*)::int from pg_temp.notices('agent:' || tests.id('agent_robot_a'))),
  0,
  'nor the AI participant (no user behind it)'
);

-- ---------------------------------------------------------------------------
-- Who may join which channel (the check Realtime runs on join).
-- ---------------------------------------------------------------------------

-- Whether the current session may read a broadcast on _topic.
create function pg_temp.can_read(_topic text) returns boolean language plpgsql as $$
declare
  _n integer;
begin
  perform set_config('realtime.topic', _topic, true);
  select count(*) into _n from realtime.messages
  where topic = _topic and extension = 'broadcast';
  return _n > 0;
exception when insufficient_privilege then
  return false;
end;
$$;
grant execute on function pg_temp.can_read(text) to anon, authenticated;

create temp table topics (name text primary key, value text);
insert into topics values
  ('org_a', 'org:' || tests.id('org_a')),
  ('conv_a1', 'conv:' || tests.id('conv_a1')),
  ('dm', 'conv:' || (select id from dm)),
  ('alice', 'agent:' || tests.id('agent_alice'));
grant select on topics to anon, authenticated;

-- One committed-looking row per topic so a permitted read finds something.
insert into realtime.messages (topic, extension, event, payload, private)
select value, 'broadcast', 'probe', '{}'::jsonb, true from topics;

create function pg_temp.t(_name text) returns text language sql stable as $$
  select value from topics where name = _name
$$;
grant execute on function pg_temp.t(text) to anon, authenticated;

select tests.authenticate_as('alice@test.local');
select ok(pg_temp.can_read(pg_temp.t('org_a')), 'user A (owner) joins org:A');
select ok(pg_temp.can_read(pg_temp.t('conv_a1')), 'and a shared conversation''s channel');
select ok(pg_temp.can_read(pg_temp.t('dm')), 'and her restricted DM''s channel');
select ok(pg_temp.can_read(pg_temp.t('alice')), 'and her own agent channel');
select tests.clear_authentication();

select tests.authenticate_as('amber@test.local');
select ok(pg_temp.can_read(pg_temp.t('org_a')), 'a member of A joins org:A');
select ok(not pg_temp.can_read(pg_temp.t('dm')), 'but not a DM she is not in');
select ok(not pg_temp.can_read(pg_temp.t('alice')), 'nor another member''s agent channel');
select tests.clear_authentication();

select tests.authenticate_as('bob@test.local');
select ok(not pg_temp.can_read(pg_temp.t('org_a')), 'user B does not join org:A');
select ok(not pg_temp.can_read(pg_temp.t('conv_a1')), 'nor A''s conversations');
select tests.clear_authentication();

select tests.authenticate_with_api_key('test-key-a-member-000000000000000000');
select ok(pg_temp.can_read(pg_temp.t('org_a')), 'API key A joins org:A');
select ok(not pg_temp.can_read(pg_temp.t('dm')), 'but no restricted conversation');
select tests.clear_authentication();

select tests.authenticate_with_api_key('test-key-b-member-000000000000000000');
select ok(not pg_temp.can_read(pg_temp.t('org_a')), 'API key B does not join org:A');
select tests.clear_authentication();

select tests.authenticate_as_anon();
select ok(not pg_temp.can_read(pg_temp.t('org_a')), 'anon does not join org:A');
select tests.clear_authentication();

select tests.authenticate_as('alice@test.local');
select throws_ok(
  $$ insert into realtime.messages (topic, extension, event, payload, private)
     values ('org:aaaaaaaa-0000-4000-8000-000000000001', 'broadcast', 'messages', '{}', true) $$,
  '42501', null,
  'no member can broadcast into a channel'
);
select tests.clear_authentication();

select * from finish();
rollback;
