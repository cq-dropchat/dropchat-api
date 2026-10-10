-- LOCAL ONLY. Real scheduler runs in a transaction that never commits pg_net
-- requests, so no worker/provider receives synthetic data. This is scheduler
-- cost and fairness, NOT sustained end-to-end throughput.
\set ON_ERROR_STOP on
begin;
create function pg_temp.queue_capacity(volume integer) returns jsonb language plpgsql as $$
declare plan jsonb; counts jsonb; started timestamptz;
begin
 delete from public.edge_calls;
 insert into public.organizations(id,name) select ('e1000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'capacity-'||n from generate_series(1,11) n;
 insert into public.edge_calls(organization_id,function,record_id,payload,next_attempt_at)
 select ('e1000000-0000-4000-8000-'||lpad((case when n<=100 then 2+(n-1)/10 else 1 end)::text,12,'0'))::uuid,
 'agent-client',gen_random_uuid(),'{}',now()-interval '1 minute' from generate_series(1,volume) n;
 analyze public.edge_calls;
 started:=clock_timestamp();
 execute 'explain (analyze,buffers,format json) select public.dispatch_edge_calls(110,10)' into plan;
 select jsonb_object_agg(organization_id,sent) into counts from (select organization_id,count(*) as sent from public.edge_calls where status='sending' group by organization_id) c;
 if (select count(*) from public.edge_calls where status='sending')<>110 or exists(select 1 from public.edge_calls where status='sending' group by organization_id having count(*)<>10) then raise exception 'small tenant starvation or per-tenant cap violated'; end if;
 return jsonb_build_object('rows',volume,'plan',plan,'claims',counts,'tick_ms',extract(epoch from clock_timestamp()-started)*1000,'offered_rate',null,'sustained_capacity',null,'qualification','synthetic scheduler only; rollback');
end $$;
select pg_temp.queue_capacity(:volume);
rollback;
