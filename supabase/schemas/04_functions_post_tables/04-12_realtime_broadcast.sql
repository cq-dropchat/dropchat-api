-- F10. Realtime broadcast of conversation and message changes.
--
-- Clients used postgres_changes on both tables filtered by organization:
-- Realtime evaluated the messages policy per subscriber per change and sent
-- every tab the whole row of every status update. These triggers publish to
-- private channels instead, authorized once when a client joins (05-13):
--
--   org:<organization_id>  a notice — table, op, id, organization_id,
--                          conversation_id, updated_at and, for a message
--                          update, the status keys that changed — for a
--                          conversation shared with the whole organization
--                          (ownerless account, not restricted). Never content.
--   agent:<agent_id>       the same notice for a conversation only some
--                          members see — a personal account's, or a restricted
--                          local/Slack one — sent to each member who sees it
--                          (the account's owner, the human participants): the
--                          org channel must not reveal that it exists.
--   conv:<conversation_id> the full row, for clients with the conversation
--                          open.
--
-- Clients fetch the rows a notice names through PostgREST (RLS applies).
-- realtime.send never raises (it warns), so a broadcast problem cannot fail
-- the write.

-- The uuid in a `<prefix>:<uuid>` topic, or null.
create function public.realtime_topic_uuid(_prefix text) returns uuid
language sql
stable
set search_path to ''
as $$
  select case
    when split_part(realtime.topic(), ':', 1) = _prefix
      and split_part(realtime.topic(), ':', 2) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then split_part(realtime.topic(), ':', 2)::uuid
  end;
$$;

create function public.broadcast_realtime_change() returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  _conv public.conversations;
  _notice jsonb;
  _agent uuid;
begin
  if tg_table_name = 'messages' then
    select * into _conv from public.conversations c where c.id = new.conversation_id;
  else
    _conv := new;
  end if;

  if _conv.id is null then
    return null;
  end if;

  _notice := jsonb_build_object(
    'table', tg_table_name,
    'op', tg_op,
    'id', new.id,
    'organization_id', new.organization_id,
    'conversation_id', _conv.id,
    'updated_at', new.updated_at
  );

  if tg_table_name = 'messages' and tg_op = 'UPDATE' then
    _notice := _notice || jsonb_build_object(
      'status_changed',
      (
        select coalesce(jsonb_agg(k order by k), '[]'::jsonb)
        from (
          select n.key as k
          from jsonb_each(coalesce(new.status, '{}'::jsonb)) n
          where n.value is distinct from coalesce(old.status, '{}'::jsonb) -> n.key
          union
          select o.key
          from jsonb_each(coalesce(old.status, '{}'::jsonb)) o
          where not coalesce(new.status, '{}'::jsonb) ? o.key
        ) changed
      )
    );
  end if;

  if not rls.is_restricted_conversation(_conv.service, _conv.type, _conv.extra)
    and exists (
      select 1 from public.organizations_addresses oa
      where oa.organization_id = _conv.organization_id
        and oa.service = _conv.service
        and oa.address = _conv.organization_address
        and oa.agent_id is null
    )
  then
    perform realtime.send(_notice, tg_table_name, 'org:' || _conv.organization_id::text, true);
  else
    for _agent in
      -- The personal account's owner (unless the conversation is restricted)…
      select oa.agent_id
      from public.organizations_addresses oa
      join public.agents a on a.id = oa.agent_id
      where oa.organization_id = _conv.organization_id
        and oa.service = _conv.service
        and oa.address = _conv.organization_address
        and a.user_id is not null
        and a.deleted_at is null
        and not rls.is_restricted_conversation(_conv.service, _conv.type, _conv.extra)
      union
      -- …and the human participants.
      select ca.agent_id
      from public.conversations_agents ca
      join public.agents a on a.id = ca.agent_id
      where ca.conversation_id = _conv.id
        and a.user_id is not null
        and a.deleted_at is null
    loop
      perform realtime.send(_notice, tg_table_name, 'agent:' || _agent::text, true);
    end loop;
  end if;

  perform realtime.send(
    jsonb_build_object('table', tg_table_name, 'op', tg_op, 'record', to_jsonb(new)),
    tg_table_name,
    'conv:' || _conv.id::text,
    true
  );

  return null;
end;
$$;

create trigger z_broadcast_realtime_change
after insert or update
on public.messages
for each row
execute function public.broadcast_realtime_change();

create trigger z_broadcast_realtime_change
after insert or update
on public.conversations
for each row
execute function public.broadcast_realtime_change();

revoke execute on function public.broadcast_realtime_change() from public, anon, authenticated, service_role;
