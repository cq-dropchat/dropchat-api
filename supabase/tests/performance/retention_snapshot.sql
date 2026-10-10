-- Read-only dry-run. No policy activation and no DELETE.
begin read only;
set local statement_timeout='30s';
with policies as (
 select id,extra->'queue_retention' as policy,
 case when coalesce(extra->'queue_retention'->>'success_days','')~'^[0-9]{1,4}$' then nullif((extra->'queue_retention'->>'success_days')::int,0) end as success_days,
 case when coalesce(extra->'queue_retention'->>'failure_days','')~'^[0-9]{1,4}$' then nullif((extra->'queue_retention'->>'failure_days')::int,0) end as failure_days
 from public.organizations
), candidates as (
 select 'edge_calls' as table_name,e.organization_id,e.status,e.updated_at,pg_column_size(e.payload) as payload_bytes
 from policies o join public.edge_calls e on e.organization_id=o.id
 where (e.status='done' and e.updated_at<now()-make_interval(days=>o.success_days))
 or (e.status='failed' and e.updated_at<now()-make_interval(days=>o.failure_days))
 union all
 select 'webhook_deliveries',e.organization_id,e.status,e.updated_at,pg_column_size(e.payload)
 from policies o join public.webhook_deliveries e on e.organization_id=o.id
 where (e.status='delivered' and e.updated_at<now()-make_interval(days=>o.success_days))
 or (e.status='failed' and e.updated_at<now()-make_interval(days=>o.failure_days))
), summary as (
 select table_name,organization_id,status,count(*) as candidates,min(updated_at) as oldest,sum(payload_bytes) as payload_bytes
 from candidates group by table_name,organization_id,status
), tables as (
 select s.relname,s.n_live_tup,s.n_dead_tup,s.n_tup_ins,s.n_tup_del,s.last_autovacuum,s.autovacuum_count,
 pg_table_size(s.relid) as table_bytes,pg_indexes_size(s.relid) as index_bytes
 from pg_stat_user_tables s where s.schemaname='public' and s.relname in
 ('messages','conversations','edge_calls','webhook_deliveries','webhook_receipts','logs','organization_exports','queue_retention_stats')
)
select jsonb_build_object('observed_at',now(),'stats_reset',(select stats_reset from pg_stat_database where datname=current_database()),'policies',(select coalesce(jsonb_agg(to_jsonb(p)),'[]') from policies p),
 'candidates',(select coalesce(jsonb_agg(to_jsonb(s)),'[]') from summary s),
 'preserved',(select coalesce(jsonb_agg(to_jsonb(a)),'[]') from public.queue_retention_stats a),
 'tables',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from tables t));
rollback;
