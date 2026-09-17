
  create table "public"."organization_exports" (
    "id" uuid not null default gen_random_uuid(),
    "organization_id" uuid not null,
    "requested_by" uuid,
    "status" text not null default 'pending'::text,
    "object_name" text,
    "error" text,
    "requested_at" timestamp with time zone not null default now(),
    "started_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "expires_at" timestamp with time zone
      );


alter table "public"."organization_exports" enable row level security;

CREATE UNIQUE INDEX organization_exports_active_key ON public.organization_exports USING btree (organization_id) WHERE (status = ANY (ARRAY['pending'::text, 'processing'::text]));

CREATE UNIQUE INDEX organization_exports_pkey ON public.organization_exports USING btree (id);

CREATE INDEX organization_exports_status_idx ON public.organization_exports USING btree (status, expires_at);

alter table "public"."organization_exports" add constraint "organization_exports_pkey" PRIMARY KEY using index "organization_exports_pkey";

alter table "public"."organization_exports" add constraint "organization_exports_status_check" CHECK ((status = ANY (ARRAY['pending'::text, 'processing'::text, 'ready'::text, 'failed'::text, 'expired'::text]))) not valid;

alter table "public"."organization_exports" validate constraint "organization_exports_status_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.claim_organization_export()
 RETURNS SETOF public.organization_exports
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  update public.organization_exports e
  set status = 'processing', started_at = now(), error = null
  where e.id = (
    select c.id
    from public.organization_exports c
    where c.status = 'pending'
      or (c.status = 'processing' and c.started_at < now() - interval '15 minutes')
    order by c.requested_at
    limit 1
    for update skip locked
  )
  returning e.*;
$function$
;

CREATE OR REPLACE FUNCTION public.expired_organization_exports(_limit integer DEFAULT 100)
 RETURNS SETOF public.organization_exports
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select e.*
  from public.organization_exports e
  where e.status = 'ready'
    and e.expires_at <= now()
  order by e.expires_at
  limit _limit;
$function$
;

CREATE OR REPLACE FUNCTION public.finish_organization_export(_id uuid, _object_name text, _error text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  update public.organization_exports e
  set status = case when _error is null then 'ready' else 'failed' end,
      object_name = case when _error is null then _object_name end,
      error = _error,
      completed_at = now(),
      expires_at = case
        when _error is not null then null
        when exists (
          select 1 from public.deletion_requests r
          where r.organization_id = e.organization_id and r.completed_at is null
        ) then now()
        else now() + public.organization_export_ttl()
      end
  where e.id = _id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.mark_organization_export_expired(_id uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  update public.organization_exports
  set status = 'expired', object_name = null
  where id = _id;
$function$
;

CREATE OR REPLACE FUNCTION public.organization_export_ttl()
 RETURNS interval
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select interval '7 days';
$function$
;

CREATE OR REPLACE FUNCTION public.request_organization_export(_organization_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _id uuid;
begin
  if _organization_id is null
    or _organization_id not in (select public.get_authorized_orgs('owner'))
  then
    raise exception using
      errcode = '42501',
      message = 'only an owner of the organization can export it';
  end if;

  insert into public.organization_exports (organization_id, requested_by)
  values (_organization_id, auth.uid())
  on conflict (organization_id) where status in ('pending', 'processing')
  do nothing
  returning id into _id;

  if _id is null then
    select e.id into _id
    from public.organization_exports e
    where e.organization_id = _organization_id
      and e.status in ('pending', 'processing');
  end if;

  return _id;
end;
$function$
;

CREATE OR REPLACE FUNCTION billing.check_storage_limit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _org_id uuid;
  _size_gb numeric;
begin
  -- F18: only attachments count; export files are the platform's.
  if new.bucket_id is distinct from 'media' then
    return new;
  end if;

  _org_id := (string_to_array(new.name, '/'))[2]::uuid;
  _size_gb := coalesce((new.metadata->>'size')::numeric, 0) / 1000000000.0;

  perform billing.check_limit(_org_id, 'storage', _size_gb);
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION billing.update_storage_usage()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _org_id uuid;
  _size_gb numeric;
begin
  -- F18: only attachments count; export files are the platform's.
  if coalesce(new.bucket_id, old.bucket_id) is distinct from 'media' then
    return coalesce(new, old);
  end if;

  if tg_op = 'INSERT' then
    _org_id := (string_to_array(new.name, '/'))[2]::uuid;
    _size_gb := coalesce((new.metadata->>'size')::numeric, 0) / 1000000000.0;
    perform billing.update_usage(_org_id, 'storage', _size_gb);
    return new;
  elsif tg_op = 'DELETE' then
    _org_id := (string_to_array(old.name, '/'))[2]::uuid;
    -- Orphaned object: the org (and its billing rows) was already deleted and the
    -- storage-gc sweep is removing the leftover files. There is no usage to
    -- credit back, so skip accounting to avoid acting on a non-existent org.
    if not exists (select 1 from public.organizations where id = _org_id) then
      return old;
    end if;
    _size_gb := coalesce((old.metadata->>'size')::numeric, 0) / 1000000000.0;
    perform billing.update_usage(_org_id, 'storage', -_size_gb);
    return old;
  end if;

  return coalesce(new, old);
end;
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

  return jsonb_build_object(
    'hooks', _hooks,
    'logs', _logs,
    'onboarding_tokens', _tokens,
    'organization_exports', _exports
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.sweep_deletions(_budget integer DEFAULT 5000)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _req public.deletion_requests;
  _left integer := _budget;
  _n integer;
  _deleted bigint := 0;
  _org boolean;
begin
  select * into _req
  from public.deletion_requests
  where completed_at is null
  order by requested_at, id
  limit 1
  for update skip locked;

  if not found then
    return jsonb_build_object('request', null);
  end if;

  _org := _req.address is null;

  -- F18: an export holds the data being deleted. Expire the organization's
  -- ready exports now (the org-export worker removes the files); one still
  -- being built is expired when it finishes (finish_organization_export).
  update public.organization_exports
  set expires_at = now()
  where organization_id = _req.organization_id
    and status = 'ready'
    and expires_at > now();

  -- Messages: through the conversations of the scope, so both scopes use
  -- messages_org_conv_timestamp_idx. For an account, the internal objects
  -- the deleted rows referenced under the organization's own path are
  -- recorded for storage-gc (a whole organization's folder is drained by
  -- storage-gc once the organization is gone). v1 file parts only: v0 rows
  -- carry a bare media id, see 03-05 messages_file_uri_idx.
  with deleted as (
    delete from public.messages
    where id in (
      select m.id
      from public.messages m
      where m.organization_id = _req.organization_id
        and (
          _org
          or m.conversation_id in (
            select c.id from public.conversations c
            where c.organization_id = _req.organization_id
              and c.service = _req.service
              and c.organization_address = _req.address
          )
        )
      limit _left
    )
    returning content -> 'file' ->> 'uri' as uri
  ), recorded as (
    insert into public.deletion_media (request_id, organization_id, object_name)
    select distinct _req.id, _req.organization_id, substr(d.uri, length('internal://media/') + 1)
    from deleted d
    where not _org
      and d.uri like 'internal://media/organizations/' || _req.organization_id::text || '/%'
    on conflict (request_id, object_name) do nothing
  )
  select count(*) into _n from deleted;
  _deleted := _deleted + _n;
  _left := _left - _n;

  if _left > 0 then
    delete from public.conversations
    where id in (
      select c.id from public.conversations c
      where c.organization_id = _req.organization_id
        and (_org or (c.service = _req.service and c.organization_address = _req.address))
      limit _left
    );
    get diagnostics _n = row_count;
    _deleted := _deleted + _n;
    _left := _left - _n;
  end if;

  if _left > 0 then
    delete from public.contacts_addresses
    where ctid in (
      select ca.ctid from public.contacts_addresses ca
      where ca.organization_id = _req.organization_id
        and (_org or (ca.service = _req.service and ca.organization_address = _req.address))
      limit _left
    );
    get diagnostics _n = row_count;
    _deleted := _deleted + _n;
    _left := _left - _n;
  end if;

  if _left > 0 then
    delete from public.logs
    where id in (
      select l.id from public.logs l
      where l.organization_id = _req.organization_id
        and (_org or (l.service = _req.service and l.organization_address = _req.address))
      limit _left
    );
    get diagnostics _n = row_count;
    _deleted := _deleted + _n;
    _left := _left - _n;
  end if;

  if _left > 0 and _org then
    delete from public.webhook_deliveries
    where id in (
      select d.id from public.webhook_deliveries d
      where d.organization_id = _req.organization_id
      limit _left
    );
    get diagnostics _n = row_count;
    _deleted := _deleted + _n;
    _left := _left - _n;
  end if;

  -- Budget spent: the next run continues where this one stopped.
  if _left <= 0 then
    update public.deletion_requests
    set started_at = coalesce(started_at, now()),
        deleted_rows = deleted_rows + _deleted
    where id = _req.id;

    return jsonb_build_object('request', _req.id, 'deleted', _deleted, 'completed', false);
  end if;

  perform set_config('app.deletion_sweep', 'on', true);

  if _org then
    delete from public.organizations where id = _req.organization_id;
  else
    delete from public.organizations_addresses
    where organization_id = _req.organization_id
      and service = _req.service
      and address = _req.address;
  end if;
  get diagnostics _n = row_count;
  _deleted := _deleted + _n;

  perform set_config('app.deletion_sweep', 'off', true);

  update public.deletion_requests
  set started_at = coalesce(started_at, now()),
      completed_at = now(),
      deleted_rows = deleted_rows + _deleted
  where id = _req.id;

  return jsonb_build_object('request', _req.id, 'deleted', _deleted, 'completed', true);
end;
$function$
;

grant references on table "public"."organization_exports" to "anon";

grant select on table "public"."organization_exports" to "anon";

grant trigger on table "public"."organization_exports" to "anon";

grant references on table "public"."organization_exports" to "authenticated";

grant select on table "public"."organization_exports" to "authenticated";

grant trigger on table "public"."organization_exports" to "authenticated";

grant delete on table "public"."organization_exports" to "service_role";

grant insert on table "public"."organization_exports" to "service_role";

grant references on table "public"."organization_exports" to "service_role";

grant select on table "public"."organization_exports" to "service_role";

grant trigger on table "public"."organization_exports" to "service_role";

grant truncate on table "public"."organization_exports" to "service_role";

grant update on table "public"."organization_exports" to "service_role";


  create policy "owners can read their org exports"
  on "public"."organization_exports"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs('owner'::public.role) AS get_authorized_orgs)));



  create policy "owners can download their org exports"
  on "storage"."objects"
  as permissive
  for select
  to authenticated, anon
using (((bucket_id = 'exports'::text) AND ((storage.foldername(name))[2] IN ( SELECT (public.get_authorized_orgs('owner'::public.role))::text AS get_authorized_orgs))));




-- ---------------------------------------------------------------------------
-- Hand-written: bucket (data) and privileges db diff does not model.
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public) values ('exports', 'exports', false)
on conflict (id) do nothing;

revoke insert, update, delete, truncate on table public.organization_exports from anon, authenticated;

revoke execute on function public.request_organization_export(uuid) from public;
grant execute on function public.request_organization_export(uuid) to anon, authenticated, service_role;

revoke execute on function public.claim_organization_export() from public, anon, authenticated;
revoke execute on function public.finish_organization_export(uuid, text, text) from public, anon, authenticated;
revoke execute on function public.expired_organization_exports(integer) from public, anon, authenticated;
revoke execute on function public.mark_organization_export_expired(uuid) from public, anon, authenticated;
grant execute on function public.claim_organization_export() to service_role;
grant execute on function public.finish_organization_export(uuid, text, text) to service_role;
grant execute on function public.expired_organization_exports(integer) to service_role;
grant execute on function public.mark_organization_export_expired(uuid) to service_role;
