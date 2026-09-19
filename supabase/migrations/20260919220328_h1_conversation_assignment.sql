alter table "public"."conversations" add column "assigned_agent_id" uuid;

alter table "public"."conversations" add column "assigned_at" timestamp with time zone;

alter table "public"."organizations" add column "entry_agent_id" uuid;

CREATE INDEX conversations_assigned_agent_idx ON public.conversations USING btree (organization_id, assigned_agent_id) WHERE (assigned_agent_id IS NOT NULL);

alter table "public"."conversations" add constraint "conversations_assigned_agent_id_fkey" FOREIGN KEY (organization_id, assigned_agent_id) REFERENCES public.agents(organization_id, id) ON DELETE SET NULL not valid;

alter table "public"."conversations" validate constraint "conversations_assigned_agent_id_fkey";

alter table "public"."organizations" add constraint "organizations_entry_agent_id_fkey" FOREIGN KEY (id, entry_agent_id) REFERENCES public.agents(organization_id, id) ON DELETE SET NULL not valid;

alter table "public"."organizations" validate constraint "organizations_entry_agent_id_fkey";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.guard_conversation_assignment()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if current_setting('app.assignment_writer', true) = 'on' then
    return new;
  end if;

  raise exception
    'conversation assignment is written by set_conversation_assignment only'
    using errcode = '42501';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_conversation_assignment(p_conversation_id uuid, p_agent_id uuid, p_awaiting_human boolean DEFAULT false, p_actor_agent_id uuid DEFAULT NULL::uuid, p_reason jsonb DEFAULT '{}'::jsonb)
 RETURNS public.conversations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _conv public.conversations;
  _from uuid;
  _cause text;
begin
  _cause := coalesce(p_reason ->> 'cause', 'manual');

  -- A closed vocabulary because M1 aggregates on it: an unknown cause would
  -- become a silent hole in the metrics rather than an error.
  if _cause not in (
    'routing', 'entry', 'escalation', 'manual', 'takeover', 'expiry'
  ) then
    raise exception 'unknown assignment cause: %', _cause
      using errcode = '22023';
  end if;

  select * into _conv
  from public.conversations
  where id = p_conversation_id
  for update;

  if not found then
    raise exception 'conversation % does not exist', p_conversation_id
      using errcode = 'P0002';
  end if;

  -- `p_awaiting_human` only reaches the note in H1: the column it will also
  -- write, conversations.awaiting_human_since, arrives with escalation (H3).
  -- The parameter is here from the start so every caller is written against
  -- the final signature.
  --
  -- `p_reason` carries two control keys besides the recorded ones:
  -- `cause` (required in practice, defaults to 'manual') and `if_unassigned`.
  --
  -- The routing path (agent-client) only wants to persist what it decided if
  -- nobody decided first: two inbound messages can race into the same
  -- conversation, and the loser must not overwrite the winner.
  if coalesce((p_reason ->> 'if_unassigned')::boolean, false)
    and _conv.assigned_agent_id is not null then
    return null;
  end if;

  if p_agent_id is not null then
    perform 1
    from public.agents a
    where a.id = p_agent_id
      and a.organization_id = _conv.organization_id;

    if not found then
      raise exception 'agent % is not in organization %',
        p_agent_id, _conv.organization_id
        using errcode = '23503';
    end if;
  end if;

  _from := _conv.assigned_agent_id;

  perform set_config('app.assignment_writer', 'on', true);

  update public.conversations
  set assigned_agent_id = p_agent_id,
      -- Only a real change restarts the clock: re-asserting the same
      -- assignment (a takeover by the human who already holds it) must not
      -- give them a fresh TTL.
      assigned_at = case
        when p_agent_id is distinct from _from then now()
        else assigned_at
      end
  where id = p_conversation_id
  returning * into _conv;

  perform set_config('app.assignment_writer', 'off', true);

  -- THE AUDIT NOTE
  --
  -- A record-only row (content.internal), inserted unarmed (status '{}') so
  -- no dispatcher picks it up and no billing cap counts it. It is what M1
  -- reads to attribute conversations by cause, and what H6 renders in the
  -- chat as "Sofía derivó a Equipo humano: reclamo".
  --
  -- Never part of the LLM history: agent-client filters kind 'assignment'
  -- out, the way it already filters other agents' tool traces.
  insert into public.messages (
    organization_id,
    conversation_id,
    service,
    organization_address,
    conversation_address,
    agent_id,
    status,
    content
  )
  values (
    _conv.organization_id,
    _conv.id,
    _conv.service,
    _conv.organization_address,
    _conv.address,
    p_actor_agent_id,
    '{}'::jsonb,
    jsonb_build_object(
      'version', '1',
      'type', 'data',
      'kind', 'assignment',
      'internal', true,
      -- from/to/by stay even when null — "nobody" is the fact an escalation
      -- records. Only the optional pair is stripped, so a note without a
      -- category has no `category` key rather than a null one.
      'data', jsonb_build_object(
        'from', _from,
        'to', p_agent_id,
        'awaiting_human', p_awaiting_human,
        'by', p_actor_agent_id,
        'cause', _cause
      ) || jsonb_strip_nulls(
        jsonb_build_object(
          'category', p_reason ->> 'category',
          'reason', p_reason ->> 'reason'
        )
      )
    )
  );

  return _conv;
end;
$function$
;

CREATE TRIGGER guard_assignment BEFORE UPDATE ON public.conversations FOR EACH ROW WHEN (((new.assigned_agent_id IS DISTINCT FROM old.assigned_agent_id) OR (new.assigned_at IS DISTINCT FROM old.assigned_at))) EXECUTE FUNCTION public.guard_conversation_assignment();



-- Privileges: db diff does not model them (see CLAUDE.md), so they are
-- hand-written here.
--
-- Supabase's default privileges grant EXECUTE on every new public function to
-- anon and authenticated by name, so `revoke ... from public` alone leaves the
-- API roles holding it. set_conversation_assignment is internal — the member
-- path is assign_conversation (H3), which checks who is asking first — and
-- the guard is a trigger function nobody should call at all.
revoke execute on function
  public.set_conversation_assignment(uuid, uuid, boolean, uuid, jsonb)
  from public, anon, authenticated;

revoke execute on function public.guard_conversation_assignment()
  from public, anon, authenticated, service_role;

-- BACKFILL — nothing changes behaviour on deploy day.
--
-- Before H1 every external conversation was answered by "the oldest agent
-- that is nobody's membership, not retired and not inactive". That agent
-- becomes the organization's entry agent, so the first message of every
-- conversation still reaches exactly who it reached yesterday.
--
-- `draft` is NOT excluded here on purpose: the old rule selected draft agents
-- (that is the bug H1 fixes), so excluding it would move an organization
-- whose oldest agent is a draft onto a different agent silently. It is left
-- out of selection instead, where it is visible: the conversation routes to
-- the next eligible agent and the audit note records it.
--
-- Conversations are NOT backfilled: an assignment is a decision, and the one
-- the old code made was re-made on every message. The next inbound message
-- assigns each conversation through the routing path, with its note.
update public.organizations o
set entry_agent_id = (
  select a.id
  from public.agents a
  where a.organization_id = o.id
    and a.user_id is null
    and a.deleted_at is null
    and coalesce(a.extra ->> 'mode', 'active') <> 'inactive'
  order by a.created_at, a.id
  limit 1
)
where o.entry_agent_id is null;
