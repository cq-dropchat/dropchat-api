-- F16. The agent-turn protocol over public.agent_turns (03-17), called by
-- agent-client in this order:
--
--   begin_agent_turn    on arrival, before the response delay: register the
--                       message; the newest one becomes the latest.
--   claim_agent_turn    after the delay, before reading the history:
--                       'claimed'    answer it (the lease is yours)
--                       'superseded' a newer message will be answered; exit
--                       'handled'    already answered; exit
--                       'busy'       another invocation holds the lease;
--                                    poll again (it yields when superseded)
--   renew_agent_turn    before every LLM call and with the typing keep-alive:
--                       'renewed' carry on; 'superseded' or 'lost' stop
--                       before paying for another call
--   release_agent_turn  on every exit after a claim; handled = answered.
--
-- Every state change runs under the row lock (for update), so two
-- concurrent claims cannot both win.

create function public.agent_turn_lease() returns interval
language sql
immutable
as $$
  select interval '90 seconds';
$$;

create function public.begin_agent_turn(
  _conversation_id uuid,
  _message_id uuid,
  _created_at timestamp with time zone
) returns void
language sql
set search_path to ''
as $$
  insert into public.agent_turns as t (
    conversation_id, organization_id, latest_message_id, latest_created_at
  )
  select c.id, c.organization_id, _message_id, _created_at
  from public.conversations c
  where c.id = _conversation_id
  on conflict (conversation_id) do update
  set latest_message_id = excluded.latest_message_id,
      latest_created_at = excluded.latest_created_at,
      updated_at = now()
  where (excluded.latest_created_at, excluded.latest_message_id)
    > (t.latest_created_at, t.latest_message_id);
$$;

create function public.claim_agent_turn(
  _conversation_id uuid,
  _message_id uuid
) returns text
language plpgsql
set search_path to ''
as $$
declare
  _turn public.agent_turns;
begin
  select * into _turn
  from public.agent_turns
  where conversation_id = _conversation_id
  for update;

  if not found or _turn.latest_message_id <> _message_id then
    return 'superseded';
  end if;

  if _turn.handled_message_id = _message_id then
    return 'handled';
  end if;

  if _turn.holder_message_id is not null and _turn.lease_until > now() then
    return 'busy';
  end if;

  update public.agent_turns
  set holder_message_id = _message_id,
      lease_until = now() + public.agent_turn_lease(),
      updated_at = now()
  where conversation_id = _conversation_id;

  return 'claimed';
end;
$$;

create function public.renew_agent_turn(
  _conversation_id uuid,
  _message_id uuid
) returns text
language plpgsql
set search_path to ''
as $$
declare
  _turn public.agent_turns;
begin
  select * into _turn
  from public.agent_turns
  where conversation_id = _conversation_id
  for update;

  if not found or _turn.holder_message_id is distinct from _message_id then
    return 'lost';
  end if;

  if _turn.latest_message_id <> _message_id then
    return 'superseded';
  end if;

  update public.agent_turns
  set lease_until = now() + public.agent_turn_lease(),
      updated_at = now()
  where conversation_id = _conversation_id;

  return 'renewed';
end;
$$;

create function public.release_agent_turn(
  _conversation_id uuid,
  _message_id uuid,
  _handled boolean
) returns void
language sql
set search_path to ''
as $$
  update public.agent_turns
  set holder_message_id = null,
      lease_until = null,
      handled_message_id = case when _handled then _message_id else handled_message_id end,
      updated_at = now()
  where conversation_id = _conversation_id
    and holder_message_id = _message_id;
$$;

revoke execute on function public.begin_agent_turn(uuid, uuid, timestamp with time zone) from public, anon, authenticated;
revoke execute on function public.claim_agent_turn(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.renew_agent_turn(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.release_agent_turn(uuid, uuid, boolean) from public, anon, authenticated;
grant execute on function public.begin_agent_turn(uuid, uuid, timestamp with time zone) to service_role;
grant execute on function public.claim_agent_turn(uuid, uuid) to service_role;
grant execute on function public.renew_agent_turn(uuid, uuid) to service_role;
grant execute on function public.release_agent_turn(uuid, uuid, boolean) to service_role;
