-- F18. The sweep behind public.deletion_requests (03-18).
--
-- request_address_deletion  files an account-scoped request (Meta's
--                           data-deletion callback) and disconnects the
--                           account at once. The organization-scoped
--                           request comes from DELETE on organizations
--                           (request_organization_deletion).
-- sweep_deletions           what the `sweep-deletions` pg_cron job runs
--                           every minute: the oldest pending request, at most
--                           `_budget` rows per run, children first (messages,
--                           conversations, contacts, logs, webhook
--                           deliveries), then the account or organization row
--                           itself, whose remaining cascade is small.

create function public.request_address_deletion(
  _organization_id uuid,
  _service public.service,
  _address text,
  _source text
) returns uuid
language plpgsql
security definer
set search_path to ''
as $$
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
$$;

create function public.sweep_deletions(_budget integer default 5000)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
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
$$;

revoke execute on function public.request_organization_deletion() from public, anon, authenticated;
revoke execute on function public.request_address_deletion(uuid, public.service, text, text) from public, anon, authenticated;
revoke execute on function public.sweep_deletions(integer) from public, anon, authenticated;
grant execute on function public.request_address_deletion(uuid, public.service, text, text) to service_role;
