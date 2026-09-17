set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.broadcast_realtime_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  if not public.is_restricted_conversation(_conv.service, _conv.type, _conv.extra)
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
        and not public.is_restricted_conversation(_conv.service, _conv.type, _conv.extra)
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
$function$
;

CREATE OR REPLACE FUNCTION public.is_restricted_conversation(conv_service public.service, conv_type text, conv_extra jsonb)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select
    -- Slack: shared iff the bot is in it.
    (
      conv_service = 'slack'::public.service
      and not coalesce((conv_extra->>'is_bot_member')::boolean, false)
    )
    -- local: shared iff it is a public channel.
    or (
      conv_service = 'local'::public.service
      and conv_type is distinct from 'channel'
    );
$function$
;

CREATE OR REPLACE FUNCTION public.realtime_topic_uuid(_prefix text)
 RETURNS uuid
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select case
    when split_part(realtime.topic(), ':', 1) = _prefix
      and split_part(realtime.topic(), ':', 2) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then split_part(realtime.topic(), ':', 2)::uuid
  end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_restricted_conversations()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select c.id
  from public.conversations c
  where c.organization_id in (select public.get_authorized_orgs('member'))
    and public.is_restricted_conversation(c.service, c.type, c.extra);
$function$
;

CREATE TRIGGER z_broadcast_realtime_change AFTER INSERT OR UPDATE ON public.conversations FOR EACH ROW EXECUTE FUNCTION public.broadcast_realtime_change();

CREATE TRIGGER z_broadcast_realtime_change AFTER INSERT OR UPDATE ON public.messages FOR EACH ROW EXECUTE FUNCTION public.broadcast_realtime_change();


  create policy "members join their realtime channels"
  on "realtime"."messages"
  as permissive
  for select
  to authenticated, anon
using (((extension = 'broadcast'::text) AND ((public.realtime_topic_uuid('org'::text) IN ( SELECT public.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) OR (public.realtime_topic_uuid('agent'::text) IN ( SELECT a.id
   FROM public.agents a
  WHERE ((a.user_id = auth.uid()) AND (a.deleted_at IS NULL)))) OR (EXISTS ( SELECT 1
   FROM public.conversations c
  WHERE (c.id = public.realtime_topic_uuid('conv'::text)))))));




-- Hand-written (db diff does not model privileges): only the triggers run it.
revoke execute on function public.broadcast_realtime_change() from public, anon, authenticated, service_role;
