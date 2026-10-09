
  create table "public"."queue_retention_stats" (
    "organization_id" uuid not null,
    "table_name" text not null,
    "status" text not null,
    "day" date not null,
    "purged_rows" bigint not null,
    "payload_bytes" bigint not null,
    "attempts" bigint not null,
    "oldest_created_at" timestamp with time zone not null,
    "newest_created_at" timestamp with time zone not null
      );


alter table "public"."queue_retention_stats" enable row level security;

CREATE UNIQUE INDEX queue_retention_stats_pkey ON public.queue_retention_stats USING btree (organization_id, table_name, status, day);

alter table "public"."queue_retention_stats" add constraint "queue_retention_stats_pkey" PRIMARY KEY using index "queue_retention_stats_pkey";

alter table "public"."queue_retention_stats" add constraint "queue_retention_stats_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE not valid;

alter table "public"."queue_retention_stats" validate constraint "queue_retention_stats_organization_id_fkey";

alter table "public"."queue_retention_stats" add constraint "queue_retention_stats_status_check" CHECK ((status = ANY (ARRAY['done'::text, 'delivered'::text, 'failed'::text]))) not valid;

alter table "public"."queue_retention_stats" validate constraint "queue_retention_stats_status_check";

alter table "public"."queue_retention_stats" add constraint "queue_retention_stats_table_name_check" CHECK ((table_name = ANY (ARRAY['edge_calls'::text, 'webhook_deliveries'::text]))) not valid;

alter table "public"."queue_retention_stats" validate constraint "queue_retention_stats_table_name_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.purge_expired_rows(_batch integer DEFAULT 10000)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _hooks integer;
  _logs integer;
  _tokens integer;
  _exports integer;
  _errors integer;
  _edge_calls integer;
  _deliveries integer;
begin
  delete from supabase_functions.hooks
  where id in (
    select h.id from supabase_functions.hooks h order by h.id limit _batch
  );
  get diagnostics _hooks = row_count;

  delete from public.logs
  where id in (
    select l.id from public.logs l
    where l.created_at < now() - interval '90 days'
    order by l.created_at
    limit _batch
  );
  get diagnostics _logs = row_count;

  delete from public.onboarding_tokens
  where id in (
    select t.id from public.onboarding_tokens t
    where t.expires_at < now() - interval '30 days'
    limit _batch
  );
  get diagnostics _tokens = row_count;

  -- F18: exports whose file is gone (expired) or that failed, a week after
  -- they finished.
  delete from public.organization_exports
  where id in (
    select e.id from public.organization_exports e
    where e.status in ('expired', 'failed')
      and coalesce(e.completed_at, e.requested_at) < now() - interval '7 days'
    limit _batch
  );
  get diagnostics _exports = row_count;

  -- E1. Deleting a settled issue also forgets its fingerprint, so if the bug
  -- ever comes back it is reported as new rather than reviving a row from last
  -- year — which is the right answer: after 90 days without a sighting, a
  -- recurrence is news.
  delete from public.error_issues
  where id in (
    select i.id from public.error_issues i
    where (i.status = 'resolved' and i.last_seen < now() - interval '90 days')
       or (i.status = 'preexisting' and i.last_seen < now() - interval '180 days')
    limit _batch
  );
  get diagnostics _errors = row_count;

  -- Opt-in: extra.queue_retention.success_days / failure_days. Absent/zero
  -- preserves history. Pending/in-flight work is NEVER a purge candidate.
  with removed as (delete from public.edge_calls
  where id in (
    select q.id from public.organizations o
    cross join lateral (
      select
        case when coalesce(o.extra -> 'queue_retention' ->> 'success_days', '') ~ '^[0-9]{1,4}$'
          then nullif((o.extra -> 'queue_retention' ->> 'success_days')::int, 0) end as success_days,
        case when coalesce(o.extra -> 'queue_retention' ->> 'failure_days', '') ~ '^[0-9]{1,4}$'
          then nullif((o.extra -> 'queue_retention' ->> 'failure_days')::int, 0) end as failure_days
    ) config
    cross join lateral (
      select e.id, e.updated_at
      from public.edge_calls e
      where e.organization_id = o.id
        and e.status in ('done', 'failed')
        -- A plain range lets the terminal index skip the retained prefix.
        and e.updated_at < now() - make_interval(days => least(config.success_days, config.failure_days))
        and (
          (e.status = 'done' and e.updated_at < now() - make_interval(days => config.success_days))
          or (e.status = 'failed' and e.updated_at < now() - make_interval(days => config.failure_days))
        )
      order by e.updated_at, e.id
      limit greatest(_batch, 0)
      for update skip locked
    ) q
    where least(config.success_days, config.failure_days) is not null
    order by row_number() over (partition by o.id order by q.updated_at, q.id), q.updated_at, q.id
    limit greatest(_batch, 0)
  ) returning organization_id,status,created_at,attempts,pg_column_size(payload) as bytes),
  preserved as (
    insert into public.queue_retention_stats(organization_id,table_name,status,day,purged_rows,payload_bytes,attempts,oldest_created_at,newest_created_at)
    select organization_id,'edge_calls',status,current_date,count(*),sum(bytes),sum(attempts),min(created_at),max(created_at) from removed group by organization_id,status
    on conflict (organization_id,table_name,status,day) do update set
      purged_rows=queue_retention_stats.purged_rows+excluded.purged_rows,
      payload_bytes=queue_retention_stats.payload_bytes+excluded.payload_bytes,
      attempts=queue_retention_stats.attempts+excluded.attempts,
      oldest_created_at=least(queue_retention_stats.oldest_created_at,excluded.oldest_created_at),
      newest_created_at=greatest(queue_retention_stats.newest_created_at,excluded.newest_created_at)
    returning 1
  ) select count(*) into _edge_calls from removed;

  with removed as (delete from public.webhook_deliveries
  where id in (
    select q.id from public.organizations o
    cross join lateral (
      select
        case when coalesce(o.extra -> 'queue_retention' ->> 'success_days', '') ~ '^[0-9]{1,4}$'
          then nullif((o.extra -> 'queue_retention' ->> 'success_days')::int, 0) end as success_days,
        case when coalesce(o.extra -> 'queue_retention' ->> 'failure_days', '') ~ '^[0-9]{1,4}$'
          then nullif((o.extra -> 'queue_retention' ->> 'failure_days')::int, 0) end as failure_days
    ) config
    cross join lateral (
      select d.id, d.updated_at
      from public.webhook_deliveries d
      where d.organization_id = o.id
        and d.status in ('delivered', 'failed')
        -- A plain range lets the terminal index skip the retained prefix.
        and d.updated_at < now() - make_interval(days => least(config.success_days, config.failure_days))
        and (
          (d.status = 'delivered' and d.updated_at < now() - make_interval(days => config.success_days))
          or (d.status = 'failed' and d.updated_at < now() - make_interval(days => config.failure_days))
        )
      order by d.updated_at, d.id
      limit greatest(_batch, 0)
      for update skip locked
    ) q
    where least(config.success_days, config.failure_days) is not null
    order by row_number() over (partition by o.id order by q.updated_at, q.id), q.updated_at, q.id
    limit greatest(_batch, 0)
  ) returning organization_id,status,created_at,attempts,pg_column_size(payload) as bytes),
  preserved as (
    insert into public.queue_retention_stats(organization_id,table_name,status,day,purged_rows,payload_bytes,attempts,oldest_created_at,newest_created_at)
    select organization_id,'webhook_deliveries',status,current_date,count(*),sum(bytes),sum(attempts),min(created_at),max(created_at) from removed group by organization_id,status
    on conflict (organization_id,table_name,status,day) do update set
      purged_rows=queue_retention_stats.purged_rows+excluded.purged_rows,
      payload_bytes=queue_retention_stats.payload_bytes+excluded.payload_bytes,
      attempts=queue_retention_stats.attempts+excluded.attempts,
      oldest_created_at=least(queue_retention_stats.oldest_created_at,excluded.oldest_created_at),
      newest_created_at=greatest(queue_retention_stats.newest_created_at,excluded.newest_created_at)
    returning 1
  ) select count(*) into _deliveries from removed;

  return jsonb_build_object(
    'hooks', _hooks,
    'logs', _logs,
    'onboarding_tokens', _tokens,
    'organization_exports', _exports,
    'error_issues', _errors,
    'edge_calls', _edge_calls,
    'webhook_deliveries', _deliveries
  );
end;
$function$
;

grant delete on table "public"."queue_retention_stats" to "service_role";

grant insert on table "public"."queue_retention_stats" to "service_role";

grant references on table "public"."queue_retention_stats" to "service_role";

grant select on table "public"."queue_retention_stats" to "service_role";

grant trigger on table "public"."queue_retention_stats" to "service_role";

grant truncate on table "public"."queue_retention_stats" to "service_role";

grant update on table "public"."queue_retention_stats" to "service_role";


