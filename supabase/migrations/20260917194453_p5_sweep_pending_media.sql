set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.sweep_pending_media(_limit integer DEFAULT 500)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _queued integer;
begin
  with due as (
    select m.*
    from public.messages m
    where m.timestamp >= now() - interval '12 hours'
      and m.timestamp <= now() - interval '1 minute'
      and m.content ->> 'type' = 'file'
      and m.status ->> 'pending' is not null
      and m.status ->> 'preprocessed' is null
      and (
        m.status ->> 'preprocessing' is null
        or (m.status ->> 'preprocessing')::timestamptz
             < now() - interval '10 minutes'
      )
      and not exists (
        select 1
        from public.edge_calls c
        where c.record_id = m.id
          and c.function = 'media-preprocessor'
          and c.status in ('pending', 'sending')
      )
    order by m.timestamp
    limit _limit
  ), queued as (
    insert into public.edge_calls (
      organization_id, function, record_id, payload, forward_headers
    )
    select
      d.organization_id,
      'media-preprocessor',
      d.id,
      jsonb_build_object(
        'old_record', null,
        'record', to_jsonb(d),
        'type', 'INSERT',
        'table', 'messages',
        'schema', 'public'
      ),
      -- A sweep has no incoming request to inherit an id from; the sender
      -- mints one per request (F26).
      '{}'::jsonb
    from due d
    returning 1
  )
  select count(*) into _queued from queued;

  return _queued;
end;
$function$
;



-- Supabase's default privileges grant execute on a new public function to
-- anon and authenticated BY NAME, so revoking is part of creating one.
revoke execute on function public.sweep_pending_media(integer)
from public, anon, authenticated;

-- P5: the per-minute safety net stops calling media-preprocessor with pg_net
-- and queues the work instead (public.edge_calls), which is the only way left
-- to invoke that function. Same condition, same cadence — what changes is
-- that these calls now retry with backoff, take their turn among
-- organizations, and show up in edge_calls_health like every other one.
--
-- Unschedule by name, tolerating its absence: a database that never ran the
-- 2026-01-29 migration has no such job.
do $$
begin
  perform cron.unschedule('preprocess-pending-messages');
exception
  when others then null;
end;
$$;

select cron.schedule(
  'sweep-pending-media',
  '* * * * *',
  $$ select public.sweep_pending_media() $$
);
