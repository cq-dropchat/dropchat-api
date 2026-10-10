begin read only;
set local statement_timeout='15s';
select jsonb_build_object('observed_at',now(),
 'transport',(select coalesce(jsonb_agg(to_jsonb(s)),'[]') from (
  select organization_id,function,count(*) filter(where status='pending' and next_attempt_at<=now()) as overdue,
  extract(epoch from now()-min(next_attempt_at) filter(where status='pending' and next_attempt_at<=now())) as oldest_due_age_s,
  count(*) filter(where status='sending' and locked_until<now()) as expired_leases,
  count(*) filter(where status='failed') as dead_letters
  from public.edge_calls where status<>'done' group by organization_id,function
 ) s),
 'receipts',(select jsonb_build_object('overdue',count(*) filter(where status='pending' and next_attempt_at<=now()),'oldest_due_age_s',extract(epoch from now()-min(next_attempt_at) filter(where status='pending' and next_attempt_at<=now())),'expired_leases',count(*) filter(where status='processing' and lease_until<now()),'dead_letters',count(*) filter(where status='failed')) from public.webhook_receipts where status<>'done'),
 'cron_failures',(select coalesce(jsonb_agg(to_jsonb(s)),'[]') from (select jobid,start_time,end_time,status from cron.job_run_details where status='failed' and start_time>now()-interval '10 minutes' order by start_time desc limit 100) s));
rollback;
