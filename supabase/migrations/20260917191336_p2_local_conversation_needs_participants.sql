set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.after_insert_on_local_conversation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  insert into public.conversations_agents (
    organization_id,
    service,
    organization_address,
    conversation_id,
    agent_id
  )
  select
    new.organization_id,
    new.service,
    new.organization_address,
    new.id,
    a.id
  from public.agents a
  where a.organization_id = new.organization_id
    and case
      when new.type = 'direct'
      then a.id::text = any (string_to_array(new.address, ':'))
      else a.user_id = auth.uid()
    end
  on conflict do nothing;

  -- PT422: PostgREST maps PT<status> to that HTTP status. The row is
  -- well-formed; it is the result that cannot stand.
  if new.type is distinct from 'channel' and not exists (
    select 1
    from public.conversations_agents ca
    where ca.conversation_id = new.id
  ) then
    raise exception using
      errcode = 'PT422',
      message = format(
        'A local %s with no participants would be invisible to everyone',
        coalesce(new.type::text, 'conversation')
      ),
      detail =
        'The writer has no agent of its own to record as a participant: API'
        ' keys and the service role are not members.',
      hint =
        'Use type ''channel'' for an organization-wide conversation, or'
        ' address a ''direct'' with a roster of agent ids (''<id>:<id>'').';
  end if;

  return new;
end;
$function$
;


