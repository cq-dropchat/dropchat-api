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
  delete from public.edge_calls
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
    order by q.updated_at, q.id
    limit greatest(_batch, 0)
  );
  get diagnostics _edge_calls = row_count;

  delete from public.webhook_deliveries
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
    order by q.updated_at, q.id
    limit greatest(_batch, 0)
  );
  get diagnostics _deliveries = row_count;

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
