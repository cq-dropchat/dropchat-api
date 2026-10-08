-- Local/CI only. Measures the real RPC and rolls all synthetic rows back.
-- The regression gate counts buffer visits, not machine-dependent latency.
begin;
set local session_replication_role = replica;
insert into public.conversations (id, organization_id, service, organization_address, address)
values ('cfffffff-0000-4000-8000-000000000001', tests.id('org_a'), 'whatsapp', tests.val('wa_a'), 'performance-concentrated');
insert into public.messages (organization_id, conversation_id, service, organization_address, conversation_address, sender_address, external_id, content, timestamp)
select tests.id('org_a'), 'cfffffff-0000-4000-8000-000000000001', 'whatsapp', tests.val('wa_a'), 'performance-concentrated', 'performance-concentrated', 'performance-' || i,
 '{"version":"1","type":"text","kind":"text","text":"performance"}', now() - interval '1 hour'
from generate_series(1, 200000) i;
set local session_replication_role = origin;
analyze public.messages;
analyze public.conversations;
create function pg_temp.profile(role_name text, max_buffers int default 5000) returns jsonb language plpgsql as $$
declare result jsonb;
begin
  execute 'explain (analyze, buffers, format json) select public.init_data(' || quote_literal(tests.id('org_a')) || ', 200, 10)' into result;
  raise notice 'init_data %, history=200000, execution_ms=%, shared_buffers=%', role_name, result->0->>'Execution Time', coalesce((result->0->'Plan'->>'Shared Hit Blocks')::int,0)+coalesce((result->0->'Plan'->>'Shared Read Blocks')::int,0);
  if coalesce((result->0->'Plan'->>'Shared Hit Blocks')::int,0)+coalesce((result->0->'Plan'->>'Shared Read Blocks')::int,0) > max_buffers then
    raise exception 'init_data traversed too many buffers for one concentrated history';
  end if;
  return result;
end $$;
select pg_temp.profile('service');
select tests.authenticate_as('alice@test.local');
select pg_temp.profile('authenticated');
select tests.clear_authentication();

-- Uniform traffic: the fast prefix must avoid probing every conversation.
set local session_replication_role = replica;
insert into public.conversations (id, organization_id, service, organization_address, address)
select ('cffffffe-0000-4000-8000-' || lpad(c::text,12,'0'))::uuid, tests.id('org_a'), 'whatsapp', tests.val('wa_a'), 'performance-uniform-' || c
from generate_series(1, 2000) c;
insert into public.messages (organization_id, conversation_id, service, organization_address, conversation_address, sender_address, external_id, content, timestamp)
select tests.id('org_a'), ('cffffffe-0000-4000-8000-' || lpad(c::text,12,'0'))::uuid, 'whatsapp', tests.val('wa_a'), 'performance-uniform-' || c, 'performance-uniform-' || c, 'performance-uniform-' || c || '-' || m,
 '{"version":"1","type":"text","kind":"text","text":"performance"}', now() - interval '10 minutes'
from generate_series(1, 2000) c, generate_series(1, 100) m;
set local session_replication_role = origin;
analyze public.messages;
analyze public.conversations;
select pg_temp.profile('service, 2000 conversations', 20000);
select tests.authenticate_as('alice@test.local');
select pg_temp.profile('authenticated, 2000 conversations', 20000);
select tests.clear_authentication();
rollback;
