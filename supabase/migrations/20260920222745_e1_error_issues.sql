create type "public"."error_source" as enum ('frontend', 'edge', 'db');

create type "public"."error_status" as enum ('new', 'acknowledged', 'resolved', 'ignored', 'preexisting');


  create table "public"."error_issues" (
    "id" uuid not null default gen_random_uuid(),
    "fingerprint" text not null,
    "source" public.error_source not null,
    "kind" text not null,
    "title" text not null,
    "culprit" text,
    "release" text,
    "status" public.error_status not null default 'new'::public.error_status,
    "first_seen" timestamp with time zone not null default now(),
    "last_seen" timestamp with time zone not null default now(),
    "regressed_at" timestamp with time zone,
    "events" bigint not null default 1,
    "first_sample" jsonb not null default '{}'::jsonb,
    "last_sample" jsonb not null default '{}'::jsonb,
    "notes" text,
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."error_issues" enable row level security;


  create table "public"."error_settings" (
    "id" boolean not null default true,
    "baseline_open" boolean not null default true,
    "baseline_closed_at" timestamp with time zone,
    "baseline_closed_by" uuid,
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."error_settings" enable row level security;


  create table "public"."platform_admins" (
    "user_id" uuid not null,
    "note" text,
    "created_at" timestamp with time zone not null default now()
      );


alter table "public"."platform_admins" enable row level security;

CREATE UNIQUE INDEX error_issues_fingerprint_key ON public.error_issues USING btree (fingerprint);

CREATE UNIQUE INDEX error_issues_pkey ON public.error_issues USING btree (id);

CREATE UNIQUE INDEX error_settings_pkey ON public.error_settings USING btree (id);

CREATE INDEX idx_error_issues_first_seen ON public.error_issues USING btree (first_seen DESC);

CREATE INDEX idx_error_issues_status_last_seen ON public.error_issues USING btree (status, last_seen DESC);

CREATE UNIQUE INDEX platform_admins_pkey ON public.platform_admins USING btree (user_id);

alter table "public"."error_issues" add constraint "error_issues_pkey" PRIMARY KEY using index "error_issues_pkey";

alter table "public"."error_settings" add constraint "error_settings_pkey" PRIMARY KEY using index "error_settings_pkey";

alter table "public"."platform_admins" add constraint "platform_admins_pkey" PRIMARY KEY using index "platform_admins_pkey";

alter table "public"."error_issues" add constraint "error_issues_fingerprint_key" UNIQUE using index "error_issues_fingerprint_key";

alter table "public"."error_settings" add constraint "error_settings_baseline_closed_by_fkey" FOREIGN KEY (baseline_closed_by) REFERENCES auth.users(id) ON DELETE SET NULL not valid;

alter table "public"."error_settings" validate constraint "error_settings_baseline_closed_by_fkey";

alter table "public"."error_settings" add constraint "error_settings_singleton" CHECK (id) not valid;

alter table "public"."error_settings" validate constraint "error_settings_singleton";

alter table "public"."platform_admins" add constraint "platform_admins_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE not valid;

alter table "public"."platform_admins" validate constraint "platform_admins_user_id_fkey";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.close_error_baseline()
 RETURNS public.error_settings
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _settings public.error_settings;
begin
  if not rls.is_platform_admin() then
    raise exception using
      errcode = '42501',
      message = 'not a platform admin';
  end if;

  -- Upsert, because the settings table ships empty: the first close is what
  -- creates the row.
  insert into public.error_settings (id, baseline_open, baseline_closed_at, baseline_closed_by)
  values (true, false, now(), auth.uid())
  on conflict (id) do update
  set
    baseline_open = false,
    baseline_closed_at = now(),
    baseline_closed_by = auth.uid(),
    updated_at = now()
  returning * into _settings;

  return _settings;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.error_fingerprint(_source public.error_source, _kind text, _message text, _culprit text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select md5(
    _source::text
    || '|' || coalesce(_kind, '')
    || '|' || public.normalize_error_message(_message)
    || '|' || coalesce(left(_culprit, 300), '')
  );
$function$
;

CREATE OR REPLACE FUNCTION public.normalize_error_message(_message text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select left(
    regexp_replace(
      regexp_replace(
        regexp_replace(
          regexp_replace(
            regexp_replace(coalesce(_message, ''),
              '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
              '<uuid>', 'gi'),
            'https?://[^\s"'')]+', '<url>', 'g'),
          '\m(0x)?[0-9a-f]{12,}\M', '<hex>', 'gi'),
        '\m\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2})?)?', '<ts>', 'g'),
      '\m\d+\M', '<n>', 'g'),
    500);
$function$
;

CREATE OR REPLACE FUNCTION public.open_error_baseline()
 RETURNS public.error_settings
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _settings public.error_settings;
begin
  if not rls.is_platform_admin() then
    raise exception using
      errcode = '42501',
      message = 'not a platform admin';
  end if;

  insert into public.error_settings (id, baseline_open)
  values (true, true)
  on conflict (id) do update
  set
    baseline_open = true,
    baseline_closed_at = null,
    baseline_closed_by = null,
    updated_at = now()
  returning * into _settings;

  return _settings;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_error_issue(_source public.error_source, _kind text, _message text, _culprit text DEFAULT NULL::text, _stack text DEFAULT NULL::text, _release text DEFAULT NULL::text, _context jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  -- A browser can call report_error in a loop with a varying message and mint
  -- a row per call. The cap bounds the damage to a bad hour: past it, new
  -- fingerprints are dropped silently (an error reporter that errors, or that
  -- tells an attacker where the wall is, is worse than one that loses rows).
  -- Occurrences of a fingerprint already on file are never capped — those are
  -- an UPDATE of two counters, and dropping them would corrupt the count that
  -- makes the panel worth reading.
  _max_new_per_hour constant integer := 200;
  _fingerprint text;
  _baseline_open boolean;
  _sample jsonb;
  _id uuid;
begin
  if _message is null or _message = '' then
    return null;
  end if;

  _kind := coalesce(nullif(left(_kind, 200), ''), 'Error');
  _message := left(_message, 1000);
  _culprit := left(_culprit, 300);
  _release := left(_release, 100);

  _fingerprint := public.error_fingerprint(_source, _kind, _message, _culprit);

  -- Bounded, and bounded honestly: a context too big to keep is kept as the
  -- truncated text of itself rather than dropped, so a fat payload still tells
  -- you what it was.
  _context := coalesce(_context, '{}'::jsonb);
  if length(_context::text) > 8000 then
    _context := jsonb_build_object(
      'truncated', true,
      'raw', left(_context::text, 8000)
    );
  end if;

  -- auth.uid() rather than anything the caller sent: the one identity here
  -- that cannot be forged. Null for an anonymous browser, which is fine — a
  -- crash on the login screen is still worth a row.
  _sample := jsonb_strip_nulls(
    jsonb_build_object(
      'at', now(),
      'stack', left(_stack, 8000),
      'release', _release,
      'user_id', auth.uid(),
      'context', _context
    )
  );

  -- No row leaves _baseline_open NULL, and no row means nobody has closed the
  -- baseline yet — which reads as open. The default falls on the safe side: a
  -- fresh install files everything as preexisting until someone deliberately
  -- says otherwise, rather than opening with a panel full of the past.
  select s.baseline_open into _baseline_open
  from public.error_settings s
  where s.id;

  _baseline_open := coalesce(_baseline_open, true);

  select i.id into _id
  from public.error_issues i
  where i.fingerprint = _fingerprint;

  if _id is null and (
    select count(*) from public.error_issues i
    where i.first_seen > now() - interval '1 hour'
  ) >= _max_new_per_hour then
    return null;
  end if;

  insert into public.error_issues as i (
    fingerprint, source, kind, title, culprit, release, status,
    first_sample, last_sample
  )
  values (
    _fingerprint, _source, _kind, _message, _culprit, _release,
    -- The whole point of the baseline: while it is open, a fingerprint seen
    -- for the first time is filed as something that was already broken.
    case
      when _baseline_open then 'preexisting'::public.error_status
      else 'new'::public.error_status
    end,
    _sample, _sample
  )
  on conflict (fingerprint) do update
  set
    last_seen = now(),
    events = i.events + 1,
    last_sample = excluded.last_sample,
    -- A fixed bug that fires again is news; everything else keeps the triage
    -- decision a person made. 'ignored' stays ignored, and 'preexisting' stays
    -- preexisting however often it repeats — an old bug happening again is
    -- still an old bug, and reopening it would refill the panel with exactly
    -- what the baseline was drawn to keep out.
    status = case
      when i.status = 'resolved' and not _baseline_open
        then 'new'::public.error_status
      else i.status
    end,
    regressed_at = case
      when i.status = 'resolved' and not _baseline_open
        then now()
      else i.regressed_at
    end
  returning i.id into _id;

  return _id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.report_edge_error(_kind text, _message text, _culprit text DEFAULT NULL::text, _stack text DEFAULT NULL::text, _release text DEFAULT NULL::text, _context jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select public.record_error_issue(
    'edge'::public.error_source,
    _kind, _message, _culprit, _stack, _release, _context
  );
$function$
;

CREATE OR REPLACE FUNCTION public.report_error(_kind text, _message text, _culprit text DEFAULT NULL::text, _stack text DEFAULT NULL::text, _release text DEFAULT NULL::text, _context jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select public.record_error_issue(
    'frontend'::public.error_source,
    _kind, _message, _culprit, _stack, _release, _context
  );
$function$
;

CREATE OR REPLACE FUNCTION rls.is_platform_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1 from public.platform_admins a where a.user_id = auth.uid()
  );
$function$
;

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

  return jsonb_build_object(
    'hooks', _hooks,
    'logs', _logs,
    'onboarding_tokens', _tokens,
    'organization_exports', _exports,
    'error_issues', _errors
  );
end;
$function$
;

grant delete on table "public"."error_issues" to "anon";

grant insert on table "public"."error_issues" to "anon";

grant references on table "public"."error_issues" to "anon";

grant select on table "public"."error_issues" to "anon";

grant trigger on table "public"."error_issues" to "anon";

grant truncate on table "public"."error_issues" to "anon";

grant delete on table "public"."error_issues" to "authenticated";

grant insert on table "public"."error_issues" to "authenticated";

grant references on table "public"."error_issues" to "authenticated";

grant select on table "public"."error_issues" to "authenticated";

grant trigger on table "public"."error_issues" to "authenticated";

grant truncate on table "public"."error_issues" to "authenticated";

grant delete on table "public"."error_issues" to "service_role";

grant insert on table "public"."error_issues" to "service_role";

grant references on table "public"."error_issues" to "service_role";

grant select on table "public"."error_issues" to "service_role";

grant trigger on table "public"."error_issues" to "service_role";

grant truncate on table "public"."error_issues" to "service_role";

grant update on table "public"."error_issues" to "service_role";

grant delete on table "public"."error_settings" to "anon";

grant insert on table "public"."error_settings" to "anon";

grant references on table "public"."error_settings" to "anon";

grant select on table "public"."error_settings" to "anon";

grant trigger on table "public"."error_settings" to "anon";

grant truncate on table "public"."error_settings" to "anon";

grant update on table "public"."error_settings" to "anon";

grant delete on table "public"."error_settings" to "authenticated";

grant insert on table "public"."error_settings" to "authenticated";

grant references on table "public"."error_settings" to "authenticated";

grant select on table "public"."error_settings" to "authenticated";

grant trigger on table "public"."error_settings" to "authenticated";

grant truncate on table "public"."error_settings" to "authenticated";

grant update on table "public"."error_settings" to "authenticated";

grant delete on table "public"."error_settings" to "service_role";

grant insert on table "public"."error_settings" to "service_role";

grant references on table "public"."error_settings" to "service_role";

grant select on table "public"."error_settings" to "service_role";

grant trigger on table "public"."error_settings" to "service_role";

grant truncate on table "public"."error_settings" to "service_role";

grant update on table "public"."error_settings" to "service_role";

grant delete on table "public"."platform_admins" to "anon";

grant insert on table "public"."platform_admins" to "anon";

grant references on table "public"."platform_admins" to "anon";

grant select on table "public"."platform_admins" to "anon";

grant trigger on table "public"."platform_admins" to "anon";

grant truncate on table "public"."platform_admins" to "anon";

grant update on table "public"."platform_admins" to "anon";

grant delete on table "public"."platform_admins" to "authenticated";

grant insert on table "public"."platform_admins" to "authenticated";

grant references on table "public"."platform_admins" to "authenticated";

grant select on table "public"."platform_admins" to "authenticated";

grant trigger on table "public"."platform_admins" to "authenticated";

grant truncate on table "public"."platform_admins" to "authenticated";

grant update on table "public"."platform_admins" to "authenticated";

grant delete on table "public"."platform_admins" to "service_role";

grant insert on table "public"."platform_admins" to "service_role";

grant references on table "public"."platform_admins" to "service_role";

grant select on table "public"."platform_admins" to "service_role";

grant trigger on table "public"."platform_admins" to "service_role";

grant truncate on table "public"."platform_admins" to "service_role";

grant update on table "public"."platform_admins" to "service_role";


  create policy "platform admins can read the error issues"
  on "public"."error_issues"
  as permissive
  for select
  to authenticated
using (rls.is_platform_admin());



  create policy "platform admins can triage the error issues"
  on "public"."error_issues"
  as permissive
  for update
  to authenticated
using (rls.is_platform_admin())
with check (rls.is_platform_admin());



  create policy "platform admins can read the error settings"
  on "public"."error_settings"
  as permissive
  for select
  to authenticated
using (rls.is_platform_admin());



  create policy "platform admins can read their own row"
  on "public"."platform_admins"
  as permissive
  for select
  to authenticated
using ((user_id = ( SELECT auth.uid() AS uid)));


CREATE TRIGGER handle_updated_at BEFORE UPDATE ON public.error_issues FOR EACH ROW EXECUTE FUNCTION public.moddatetime('updated_at');



-- Hand-written: `db diff` (migra) does not carry function privileges or
-- column-level grants across, so everything below is absent from the diff
-- above even though it is declared in supabase/schemas/. Without it the
-- migration is not merely incomplete, it is wrong in both directions:
-- Postgres grants EXECUTE on a new function to PUBLIC, so record_error_issue
-- — whose whole job is to take `source` as an argument — would be a live
-- PostgREST endpoint for anon, and a browser could file issues that look like
-- backend ones; while error_issues would have no UPDATE grant for
-- `authenticated` at all, leaving the triage policy switched off.

revoke execute on function public.record_error_issue(
  public.error_source, text, text, text, text, text, jsonb
) from public, anon, authenticated, service_role;

revoke execute on function public.report_error(
  text, text, text, text, text, jsonb
) from public;

grant execute on function public.report_error(
  text, text, text, text, text, jsonb
) to anon, authenticated;

revoke execute on function public.report_edge_error(
  text, text, text, text, text, jsonb
) from public, anon, authenticated;

grant execute on function public.report_edge_error(
  text, text, text, text, text, jsonb
) to service_role;

revoke execute on function rls.is_platform_admin() from public;

grant execute on function rls.is_platform_admin() to anon, authenticated, service_role;

revoke execute on function public.close_error_baseline() from public, anon;

grant execute on function public.close_error_baseline() to authenticated;

revoke execute on function public.open_error_baseline() from public, anon;

grant execute on function public.open_error_baseline() to authenticated;

-- Triage moves a status and leaves a note; it does not rewrite the evidence.
revoke update on table public.error_issues from anon, authenticated;

grant update (status, notes) on table public.error_issues to authenticated;
