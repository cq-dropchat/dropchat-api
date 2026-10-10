begin read only;
set local statement_timeout='15s';
select jsonb_build_object('observed_at',now(),
 'migrations',(select jsonb_agg(version order by version) from supabase_migrations.schema_migrations),
 'invalid_indexes',(select coalesce(jsonb_agg(c.relname),'[]') from pg_index i join pg_class c on c.oid=i.indexrelid where not i.indisvalid),
 'history_indexes',(select jsonb_agg(jsonb_build_object('name',c.relname,'valid',i.indisvalid,'definition',pg_get_indexdef(i.indexrelid))) from pg_index i join pg_class c on c.oid=i.indexrelid where c.relname in ('messages_org_timestamp_idx','messages_org_conv_history_cursor_idx','messages_org_updated_cursor_idx','conversations_org_updated_cursor_idx')),
 'cron',(select jsonb_agg(jsonb_build_object('job',jobname,'schedule',schedule,'active',active)) from cron.job),
 'cron_failures',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (select jobid,status,start_time,end_time from cron.job_run_details where start_time>now()-interval '10 minutes' and status='failed' order by start_time desc limit 100) x),
 'new_error_issues',(select count(*) from public.error_issues where status='new' and last_seen>now()-interval '10 minutes'));
rollback;
