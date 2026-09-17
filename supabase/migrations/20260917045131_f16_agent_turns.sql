
  create table "public"."agent_turns" (
    "conversation_id" uuid not null,
    "organization_id" uuid not null,
    "latest_message_id" uuid not null,
    "latest_created_at" timestamp with time zone not null,
    "holder_message_id" uuid,
    "lease_until" timestamp with time zone,
    "handled_message_id" uuid,
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."agent_turns" enable row level security;

-- Hand-written: db diff does not emit revokes.
revoke all on table "public"."agent_turns" from anon, authenticated;

CREATE UNIQUE INDEX agent_turns_pkey ON public.agent_turns USING btree (conversation_id);

alter table "public"."agent_turns" add constraint "agent_turns_pkey" PRIMARY KEY using index "agent_turns_pkey";

alter table "public"."agent_turns" add constraint "agent_turns_conversation_id_fkey" FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON DELETE CASCADE;

alter table "public"."agent_turns" add constraint "agent_turns_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.agent_turn_lease()
 RETURNS interval
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select interval '90 seconds';
$function$
;

CREATE OR REPLACE FUNCTION public.begin_agent_turn(_conversation_id uuid, _message_id uuid, _created_at timestamp with time zone)
 RETURNS void
 LANGUAGE sql
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.claim_agent_turn(_conversation_id uuid, _message_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.release_agent_turn(_conversation_id uuid, _message_id uuid, _handled boolean)
 RETURNS void
 LANGUAGE sql
 SET search_path TO ''
AS $function$
  update public.agent_turns
  set holder_message_id = null,
      lease_until = null,
      handled_message_id = case when _handled then _message_id else handled_message_id end,
      updated_at = now()
  where conversation_id = _conversation_id
    and holder_message_id = _message_id;
$function$
;

CREATE OR REPLACE FUNCTION public.renew_agent_turn(_conversation_id uuid, _message_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
$function$
;

grant delete on table "public"."agent_turns" to "service_role";

grant insert on table "public"."agent_turns" to "service_role";

grant select on table "public"."agent_turns" to "service_role";

grant update on table "public"."agent_turns" to "service_role";

-- Hand-written: execute privileges (db diff does not emit revokes). Default
-- privileges grant execute to anon and authenticated by name, so revoking
-- from public alone would leave them callable.
revoke execute on function public.begin_agent_turn(uuid, uuid, timestamp with time zone) from public, anon, authenticated;
revoke execute on function public.claim_agent_turn(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.renew_agent_turn(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.release_agent_turn(uuid, uuid, boolean) from public, anon, authenticated;
grant execute on function public.begin_agent_turn(uuid, uuid, timestamp with time zone) to service_role;
grant execute on function public.claim_agent_turn(uuid, uuid) to service_role;
grant execute on function public.renew_agent_turn(uuid, uuid) to service_role;
grant execute on function public.release_agent_turn(uuid, uuid, boolean) to service_role;
