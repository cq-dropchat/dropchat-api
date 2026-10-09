-- Isolated, reproducible fixtures; queries retain real roles, RLS and helpers.
-- Every transaction rolls back even if psql disconnects after a SQL error.
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
begin;
set local session_replication_role=replica;
delete from public.messages where organization_id in (tests.id('org_a'),tests.id('org_b'));
insert into public.conversations(id,organization_id,service,organization_address,address)
select ('c1000000-0000-4000-8000-'||lpad(c::text,12,'0'))::uuid,tests.id('org_a'),'whatsapp',tests.val('wa_a'),'performance-'||c
from generate_series(1,1) c;
insert into public.messages(id,organization_id,conversation_id,service,organization_address,conversation_address,sender_address,external_id,content,timestamp)
select ('d1000000-0000-4000-8000-'||lpad(((c-1)*200000+m)::text,12,'0'))::uuid, tests.id('org_a'),
 ('c1000000-0000-4000-8000-'||lpad(c::text,12,'0'))::uuid,'whatsapp',tests.val('wa_a'),
 'performance-'||c,'performance-'||c,'performance-'||c||'-'||m,
 '{"version":"1","type":"text","kind":"text","text":"performance"}',
 '2026-10-01T00:00:00Z'::timestamptz
from generate_series(1,1) c,generate_series(1,200000) m;
insert into public.conversations(id,organization_id,service,organization_address,address)
select ('c2000000-0000-4000-8000-'||lpad(c::text,12,'0'))::uuid,tests.id('org_b'),'whatsapp',tests.val('wa_b'),'performance-'||c
from generate_series(1,1) c;
insert into public.messages(id,organization_id,conversation_id,service,organization_address,conversation_address,sender_address,external_id,content,timestamp)
select ('d2000000-0000-4000-8000-'||lpad(((c-1)*200000+m)::text,12,'0'))::uuid, tests.id('org_b'),
 ('c2000000-0000-4000-8000-'||lpad(c::text,12,'0'))::uuid,'whatsapp',tests.val('wa_b'),
 'performance-'||c,'performance-'||c,'performance-'||c||'-'||m,
 '{"version":"1","type":"text","kind":"text","text":"performance"}',
 '2026-10-01T00:00:00Z'::timestamptz
from generate_series(1,1) c,generate_series(1,200000) m;
set local session_replication_role=origin;
analyze public.messages;
analyze public.conversations;
create function pg_temp.profile(distribution text, max_buffers integer) returns jsonb
language plpgsql security invoker as $$
declare plan jsonb; actual jsonb; expected uuid[]; ids uuid[]; buffers bigint;
begin
  execute format('explain (analyze,buffers,format json) select public.init_data(%L,200,10)', tests.id('org_a')) into plan;
  actual := public.init_data(tests.id('org_a'),200,10)::jsonb;
  select coalesce(array_agg((m->>'id')::uuid order by n), '{}') into ids
  from jsonb_array_elements(actual->'messages') with ordinality as t(m,n);
  -- Independent reference: full ranking is intentionally OUTSIDE the measured RPC.
  select coalesce(array_agg(id order by timestamp desc,id desc), '{}') into expected
  from (select id,timestamp from (
    select id,timestamp,row_number() over(partition by conversation_id order by timestamp desc,id desc) as n
    from public.messages where organization_id=tests.id('org_a') and timestamp<=now()
  ) ranked where n<=10 order by timestamp desc,id desc limit 200) reference;
  buffers := coalesce((plan->0->'Plan'->>'Shared Hit Blocks')::bigint,0)+coalesce((plan->0->'Plan'->>'Shared Read Blocks')::bigint,0);
  return jsonb_build_object('distribution',distribution,'effective_role',current_user,
    'actor',coalesce(auth.jwt()->>'email',current_user), 'seed','fixed-2026-10-01-v1',
    'tenant_rows',(select count(*) from public.messages where organization_id=tests.id('org_a')),
    'foreign_rows',200000,'total_fixture_rows',400000,'returned_rows',cardinality(ids),
    'rpc_limits',jsonb_build_object('total',200,'per_conversation',10),
    'ids',ids,'correct',ids=expected and not exists(
      select 1 from jsonb_array_elements(actual->'messages') m
      where m->>'organization_id'<>tests.id('org_a')::text or m->'content'->>'text'<>'performance'),
    'buffers',buffers,'max_buffers',max_buffers,'execution_ms',plan->0->'Execution Time',
    'temporary_read_blocks',plan->0->'Plan'->'Temp Read Blocks',
    'temporary_written_blocks',plan->0->'Plan'->'Temp Written Blocks','plan',plan,
    'passed',ids=expected and buffers<=max_buffers);
end $$;
select pg_temp.profile('concentrated',5000);
set local role service_role;
select pg_temp.profile('concentrated',5000);
reset role;
select tests.authenticate_as('alice@test.local');
select pg_temp.profile('concentrated',5000);
select tests.clear_authentication();
select tests.authenticate_as('amber@test.local');
select pg_temp.profile('concentrated',5000);
select tests.clear_authentication();
rollback;
begin;
set local session_replication_role=replica;
delete from public.messages where organization_id in (tests.id('org_a'),tests.id('org_b'));
insert into public.conversations(id,organization_id,service,organization_address,address)
select ('c1000000-0000-4000-8000-'||lpad(c::text,12,'0'))::uuid,tests.id('org_a'),'whatsapp',tests.val('wa_a'),'performance-'||c
from generate_series(1,2000) c;
insert into public.messages(id,organization_id,conversation_id,service,organization_address,conversation_address,sender_address,external_id,content,timestamp)
select ('d1000000-0000-4000-8000-'||lpad(((c-1)*100+m)::text,12,'0'))::uuid, tests.id('org_a'),
 ('c1000000-0000-4000-8000-'||lpad(c::text,12,'0'))::uuid,'whatsapp',tests.val('wa_a'),
 'performance-'||c,'performance-'||c,'performance-'||c||'-'||m,
 '{"version":"1","type":"text","kind":"text","text":"performance"}',
 '2026-10-01T00:00:00Z'::timestamptz + m * interval '1 second'
from generate_series(1,2000) c,generate_series(1,100) m;
insert into public.conversations(id,organization_id,service,organization_address,address)
select ('c2000000-0000-4000-8000-'||lpad(c::text,12,'0'))::uuid,tests.id('org_b'),'whatsapp',tests.val('wa_b'),'performance-'||c
from generate_series(1,1) c;
insert into public.messages(id,organization_id,conversation_id,service,organization_address,conversation_address,sender_address,external_id,content,timestamp)
select ('d2000000-0000-4000-8000-'||lpad(((c-1)*200000+m)::text,12,'0'))::uuid, tests.id('org_b'),
 ('c2000000-0000-4000-8000-'||lpad(c::text,12,'0'))::uuid,'whatsapp',tests.val('wa_b'),
 'performance-'||c,'performance-'||c,'performance-'||c||'-'||m,
 '{"version":"1","type":"text","kind":"text","text":"performance"}',
 '2026-10-01T00:00:00Z'::timestamptz
from generate_series(1,1) c,generate_series(1,200000) m;
set local session_replication_role=origin;
analyze public.messages;
analyze public.conversations;
create function pg_temp.profile(distribution text, max_buffers integer) returns jsonb
language plpgsql security invoker as $$
declare plan jsonb; actual jsonb; expected uuid[]; ids uuid[]; buffers bigint;
begin
  execute format('explain (analyze,buffers,format json) select public.init_data(%L,200,10)', tests.id('org_a')) into plan;
  actual := public.init_data(tests.id('org_a'),200,10)::jsonb;
  select coalesce(array_agg((m->>'id')::uuid order by n), '{}') into ids
  from jsonb_array_elements(actual->'messages') with ordinality as t(m,n);
  -- Independent reference: full ranking is intentionally OUTSIDE the measured RPC.
  select coalesce(array_agg(id order by timestamp desc,id desc), '{}') into expected
  from (select id,timestamp from (
    select id,timestamp,row_number() over(partition by conversation_id order by timestamp desc,id desc) as n
    from public.messages where organization_id=tests.id('org_a') and timestamp<=now()
  ) ranked where n<=10 order by timestamp desc,id desc limit 200) reference;
  buffers := coalesce((plan->0->'Plan'->>'Shared Hit Blocks')::bigint,0)+coalesce((plan->0->'Plan'->>'Shared Read Blocks')::bigint,0);
  return jsonb_build_object('distribution',distribution,'effective_role',current_user,
    'actor',coalesce(auth.jwt()->>'email',current_user), 'seed','fixed-2026-10-01-v1',
    'tenant_rows',(select count(*) from public.messages where organization_id=tests.id('org_a')),
    'foreign_rows',200000,'total_fixture_rows',400000,'returned_rows',cardinality(ids),
    'rpc_limits',jsonb_build_object('total',200,'per_conversation',10),
    'ids',ids,'correct',ids=expected and not exists(
      select 1 from jsonb_array_elements(actual->'messages') m
      where m->>'organization_id'<>tests.id('org_a')::text or m->'content'->>'text'<>'performance'),
    'buffers',buffers,'max_buffers',max_buffers,'execution_ms',plan->0->'Execution Time',
    'temporary_read_blocks',plan->0->'Plan'->'Temp Read Blocks',
    'temporary_written_blocks',plan->0->'Plan'->'Temp Written Blocks','plan',plan,
    'passed',ids=expected and buffers<=max_buffers);
end $$;
select pg_temp.profile('uniform',20000);
set local role service_role;
select pg_temp.profile('uniform',20000);
reset role;
select tests.authenticate_as('alice@test.local');
select pg_temp.profile('uniform',20000);
select tests.clear_authentication();
select tests.authenticate_as('amber@test.local');
select pg_temp.profile('uniform',20000);
select tests.clear_authentication();
rollback;
