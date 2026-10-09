begin;
select plan(7);
-- Dominant tenant's eligible rows are all older than the small tenant's.
update public.organizations set extra='{"queue_retention":{"success_days":30,"failure_days":0}}' where id in (tests.id('org_a'),tests.id('org_b'));
insert into public.edge_calls(organization_id,function,record_id,payload,status,updated_at)
select tests.id('org_a'),'agent-client',gen_random_uuid(),'{}','done',now()-interval '100 days' from generate_series(1,20);
insert into public.edge_calls(organization_id,function,record_id,payload,status,updated_at)
values(tests.id('org_b'),'agent-client',gen_random_uuid(),'{}','done',now()-interval '50 days');
select is((public.purge_expired_rows(2)->>'edge_calls')::int,2,'existing batch limit retained');
select is((select count(*)::int from public.edge_calls where organization_id=tests.id('org_b') and updated_at<now()-interval '40 days'),0,'small tenant progresses in the same batch');
select is((select count(*)::int from public.edge_calls where organization_id=tests.id('org_a') and updated_at<now()-interval '40 days'),19,'dominant tenant only uses the remaining share');
select is((select sum(purged_rows)::int from public.queue_retention_stats),2,'historical count survives deletion');
select ok((select sum(payload_bytes)>0 from public.queue_retention_stats),'payload volume survives deletion without content');
select public.purge_expired_rows(2);
select is((select sum(purged_rows)::int from public.queue_retention_stats),4,'same-day aggregates accumulate rather than replace');
select tests.authenticate_as('alice@test.local');
select is((select count(*)::int from public.queue_retention_stats),0,'RLS hides all platform aggregates from tenant users');
select * from finish();
rollback;
