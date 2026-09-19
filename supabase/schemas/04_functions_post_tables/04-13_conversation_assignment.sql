-- H1 — the single write gate for a conversation's assignment.
--
-- Every path that changes who answers goes through here: agent-client when it
-- routes the first message (cause 'entry'), assign_conversation and the
-- implicit takeover (H3), and the lifecycle sweeps (H4). The point is not
-- convenience — it is that the change and its audit note are ONE transaction,
-- so a conversation can never end up assigned with no record of who did it or
-- why.
--
-- Internal: revoked from public, anon and authenticated (see the migration's
-- privileges and tests/database/11_service_only_functions). The callers that
-- are not triggers reach it with the service role; the ones that are members
-- go through assign_conversation (H3), which checks visibility first.
create function public.set_conversation_assignment(
  p_conversation_id uuid,
  p_agent_id uuid,
  p_awaiting_human boolean default false,
  p_actor_agent_id uuid default null,
  p_reason jsonb default '{}'::jsonb
) returns public.conversations
language plpgsql
security definer
set search_path to ''
as $$
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
$$;
