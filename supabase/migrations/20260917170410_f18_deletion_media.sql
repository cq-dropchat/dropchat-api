
  create table "public"."deletion_media" (
    "request_id" uuid not null,
    "organization_id" uuid not null,
    "object_name" text not null,
    "created_at" timestamp with time zone not null default now()
      );


alter table "public"."deletion_media" enable row level security;

CREATE INDEX deletion_media_organization_object_idx ON public.deletion_media USING btree (organization_id, object_name);

CREATE UNIQUE INDEX deletion_media_pkey ON public.deletion_media USING btree (request_id, object_name);

alter table "public"."deletion_media" add constraint "deletion_media_pkey" PRIMARY KEY using index "deletion_media_pkey";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.forget_deletion_media(_organization_id uuid, _object_names text[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _n integer;
begin
  delete from public.deletion_media dm
  where dm.organization_id = _organization_id
    and dm.object_name = any (_object_names);
  get diagnostics _n = row_count;
  return _n;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pending_deletion_media(_limit integer DEFAULT 1000)
 RETURNS TABLE(organization_id uuid, object_name text, referenced boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select p.organization_id, p.object_name,
    exists (
      select 1 from public.messages m
      where m.content -> 'file' ->> 'uri' = 'internal://media/' || p.object_name
        and m.organization_id = p.organization_id
    )
  from (
    select dm.organization_id, dm.object_name, min(dm.created_at) as created_at
    from public.deletion_media dm
    group by dm.organization_id, dm.object_name
    order by min(dm.created_at), dm.object_name
    limit _limit
  ) p
  order by p.created_at, p.object_name;
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

grant delete on table "public"."deletion_media" to "service_role";

grant insert on table "public"."deletion_media" to "service_role";

grant references on table "public"."deletion_media" to "service_role";

grant select on table "public"."deletion_media" to "service_role";

grant trigger on table "public"."deletion_media" to "service_role";

grant truncate on table "public"."deletion_media" to "service_role";

grant update on table "public"."deletion_media" to "service_role";



-- Hand-written (db diff does not model these revokes): service role only.
revoke all on table public.deletion_media from anon, authenticated;
revoke execute on function public.pending_deletion_media(integer) from public, anon, authenticated;
revoke execute on function public.forget_deletion_media(uuid, text[]) from public, anon, authenticated;
grant execute on function public.pending_deletion_media(integer) to service_role;
grant execute on function public.forget_deletion_media(uuid, text[]) to service_role;
