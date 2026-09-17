
  create table "public"."deletion_requests" (
    "id" uuid not null default gen_random_uuid(),
    "organization_id" uuid not null,
    "service" public.service,
    "address" text,
    "source" text not null,
    "requested_at" timestamp with time zone not null default now(),
    "started_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "deleted_rows" bigint not null default 0
      );


alter table "public"."deletion_requests" enable row level security;

-- Hand-written: db diff does not emit revokes.
revoke all on table "public"."deletion_requests" from anon, authenticated;

alter table "public"."organizations" add column "deletion_requested_at" timestamp with time zone;

CREATE UNIQUE INDEX deletion_requests_pending_key ON public.deletion_requests USING btree (organization_id, service, address) NULLS NOT DISTINCT WHERE (completed_at IS NULL);

CREATE UNIQUE INDEX deletion_requests_pkey ON public.deletion_requests USING btree (id);

alter table "public"."deletion_requests" add constraint "deletion_requests_pkey" PRIMARY KEY using index "deletion_requests_pkey";

alter table "public"."deletion_requests" add constraint "deletion_requests_scope_check" CHECK (((service IS NULL) = (address IS NULL)));

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.request_address_deletion(_organization_id uuid, _service public.service, _address text, _source text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _id uuid;
begin
  insert into public.deletion_requests (organization_id, service, address, source)
  values (_organization_id, _service, _address, _source)
  on conflict (organization_id, service, address) where completed_at is null
  do nothing
  returning id into _id;

  if _id is null then
    select r.id into _id
    from public.deletion_requests r
    where r.organization_id = _organization_id
      and r.service = _service
      and r.address = _address
      and r.completed_at is null;
  end if;

  update public.organizations_addresses
  set status = 'deleting'
  where organization_id = _organization_id
    and service = _service
    and address = _address;

  return _id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.request_organization_deletion()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if current_setting('app.deletion_sweep', true) = 'on' then
    return old;
  end if;

  insert into public.deletion_requests (organization_id, source)
  values (old.id, 'owner')
  on conflict (organization_id, service, address) where completed_at is null
  do nothing;

  update public.organizations
  set deletion_requested_at = coalesce(deletion_requested_at, now())
  where id = old.id;

  update public.organizations_addresses
  set status = 'deleting'
  where organization_id = old.id;

  return null;
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

  -- Messages: through the conversations of the scope, so both scopes use
  -- messages_org_conv_timestamp_idx.
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
  );
  get diagnostics _n = row_count;
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

CREATE OR REPLACE FUNCTION public.get_authorized_orgs(role public.role DEFAULT 'member'::public.role)
 RETURNS SETOF uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  req_level int;
  api_key text;
  org_id uuid;
  key_id uuid;
begin
  req_level := case role::text
    when 'owner' then 3
    when 'admin' then 2
    else 1 -- 'member'
  end;

  -- First, try JWT authentication via auth.uid()
  if auth.uid() is not null then
    -- Aliased because the parameter is also called `role`: a bare `role` here
    -- would resolve to it, and every caller would come back an owner.
    --
    -- No invitation clause: an agents row is a member, full stop. It used to
    -- also have to exclude rows whose invitation was still pending, and every
    -- helper that forgot to was a hole. Invitations are their own table now.
    return query select a.organization_id from public.agents a
    where
      a.user_id = auth.uid()
    -- A deleted agent is a former member: this is what makes marking the row
    -- revoke access rather than merely rename it.
    and a.deleted_at is null
    -- F18: an organization whose deletion was requested is gone for every
    -- reader at once; the sweep removes its rows later, in batches.
    and not exists (
      select 1 from public.organizations o
      where o.id = a.organization_id and o.deletion_requested_at is not null
    )
    and (
      case a.role
        when 'owner' then 3
        when 'admin' then 2
        else 1 -- 'member'
      end
    ) >= req_level;

    -- Authenticated but lacking the requested role: return the empty set so RLS
    -- subqueries can fall through to other OR-combined policies (e.g. a member
    -- editing themselves while an owner-only policy is also evaluated).
    -- Raising here would short-circuit the whole RLS evaluation.
    -- raise exception using
    --   errcode = '42501',
    --   message = format('insufficient permissions, %s role required', role::text);
    return;
  end if;

  -- Fallback to API key authentication
  api_key := current_setting('request.headers', true)::json->>'api-key';

  if api_key is not null then
    -- F14: the secret is compared as sha256 (api_keys_key_hash_key serves
    -- the probe). A row that still carries a plain key and no hash is only
    -- honoured until the cutover; an expired key is never honoured.
    select a.organization_id, a.id into org_id, key_id
    from public.api_keys a
    where (
      a.key_hash = extensions.digest(api_key, 'sha256')
      or (
        a.key_hash is null
        and a.key = api_key
        and now() < public.api_key_plaintext_cutover()
      )
    )
    and (a.expires_at is null or a.expires_at > now())
    and not exists (
      select 1 from public.organizations o
      where o.id = a.organization_id and o.deletion_requested_at is not null
    )
    and (
      case (a.role::text)
        when 'owner' then 3
        when 'admin' then 2
        else 1 -- 'member'
      end
    ) >= req_level;

    if org_id is not null then
      -- Usage stamp, at most once a minute, and only where a write is
      -- possible: PostgREST serves GET inside a READ ONLY transaction.
      if current_setting('transaction_read_only', true) = 'off' then
        update public.api_keys a
        set last_used_at = now()
        where a.id = key_id
          and (a.last_used_at is null or a.last_used_at < now() - interval '1 minute');
      end if;

      return next org_id;
    end if;
    -- Same reasoning as the JWT branch: invalid key or insufficient role returns
    -- the empty set, not a raise. Validate api-key existence at the request edge
    -- (e.g. a pre-request hook) if you want loud failure for missing/invalid keys.
    -- raise exception using
    --   errcode = '42501',
    --   message = format('invalid api key or insufficient permissions, %s role required', role::text);
    return;
  end if;

  raise exception using
    errcode = '42501',
    message = 'authentication required',
    hint = 'use api-key header or jwt authentication';
end;
$function$
;

grant delete on table "public"."deletion_requests" to "service_role";

grant insert on table "public"."deletion_requests" to "service_role";

grant select on table "public"."deletion_requests" to "service_role";

grant update on table "public"."deletion_requests" to "service_role";

CREATE TRIGGER request_deletion BEFORE DELETE ON public.organizations FOR EACH ROW EXECUTE FUNCTION public.request_organization_deletion();

-- Hand-written: execute privileges (db diff does not model them).
revoke execute on function public.request_organization_deletion() from public, anon, authenticated;
revoke execute on function public.request_address_deletion(uuid, public.service, text, text) from public, anon, authenticated;
revoke execute on function public.sweep_deletions(integer) from public, anon, authenticated;
grant execute on function public.request_address_deletion(uuid, public.service, text, text) to service_role;

-- Hand-written: pg_cron schedules are imperative, db diff cannot model them.
select cron.schedule(
  'sweep-deletions',
  '* * * * *',
  $$ select public.sweep_deletions(); $$
);
