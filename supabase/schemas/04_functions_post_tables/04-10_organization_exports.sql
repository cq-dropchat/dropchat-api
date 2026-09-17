-- F18. Organization exports (03-19): the owner's request and the worker's
-- lifecycle functions.

create function public.organization_export_ttl() returns interval
language sql
immutable
as $$
  select interval '7 days';
$$;

-- Files an export of the organization, or returns the one already pending or
-- processing. Owners only — users and owner API keys, the rule that lets
-- them delete the organization — whatever the table's policies say, since
-- this is SECURITY DEFINER.
create function public.request_organization_export(_organization_id uuid)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  _id uuid;
begin
  if _organization_id is null
    or _organization_id not in (select rls.get_authorized_orgs('owner'))
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
$$;

-- The worker takes the oldest pending export, or one whose worker died
-- (processing for over 15 minutes). SKIP LOCKED: two workers never take the
-- same one.
create function public.claim_organization_export()
returns setof public.organization_exports
language sql
security definer
set search_path to ''
as $$
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
$$;

-- Ready (with its file) or failed (with the reason). An organization with a
-- deletion pending gets an export that is already expired: the worker
-- removes the file on its next run.
create function public.finish_organization_export(
  _id uuid,
  _object_name text,
  _error text
) returns void
language plpgsql
security definer
set search_path to ''
as $$
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
$$;

-- Ready exports past their expiry: the worker removes each file, then marks
-- it expired.
create function public.expired_organization_exports(_limit integer default 100)
returns setof public.organization_exports
language sql
stable
security definer
set search_path to ''
as $$
  select e.*
  from public.organization_exports e
  where e.status = 'ready'
    and e.expires_at <= now()
  order by e.expires_at
  limit _limit;
$$;

create function public.mark_organization_export_expired(_id uuid) returns void
language sql
security definer
set search_path to ''
as $$
  update public.organization_exports
  set status = 'expired', object_name = null
  where id = _id;
$$;

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
