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

  -- `p_reason` carries two control keys besides the recorded ones:
  -- `cause` (required in practice, defaults to 'manual') and `expect_from`.
  --
  -- `expect_from` is compare-and-set, for the routing path: agent-client
  -- decides who answers by reading the conversation, and by the time it
  -- writes, another invocation — or a person — may have decided something
  -- else. It states what it believed the assignment was (null for "nobody",
  -- or the id of the agent that turned out not to answer any more); if the
  -- row says otherwise, nothing is written and the caller learns it lost by
  -- getting null back.
  --
  -- A plain "only if unassigned" was not enough: a conversation pinned to a
  -- retired or deactivated agent has to be re-routed, and that is precisely
  -- a write over an existing assignment.
  if p_reason ? 'expect_from'
    and _conv.assigned_agent_id is distinct from
      (p_reason ->> 'expect_from')::uuid
  then
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
      end,
      -- H3: the wait starts with the escalation and ends the moment anybody
      -- takes the conversation. `coalesce` so a second escalation of the same
      -- conversation does not restart a clock the team is already late on.
      awaiting_human_since = case
        when p_awaiting_human then coalesce(awaiting_human_since, now())
        else null
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

-- H3 — the member-facing door.
--
-- No API role can write the assignment columns (the guard trigger refuses
-- it), so this is how a person takes a conversation the AI is holding, hands
-- it back, or returns it to routing. Being the only door, it is also where
-- "may you?" is answered.
--
-- Who: anybody who can SEE the conversation — the same rule as the select
-- policy of 05-03, asked through rls.is_conversation_visible — plus an API
-- key of the organization, which satisfies the shared-inbox half of that
-- rule. Not a role check: a member who cannot see a personal account's
-- conversation has no business assigning it either.
create function public.assign_conversation(
  p_conversation_id uuid,
  p_agent_id uuid default null
) returns public.conversations
language plpgsql
security definer
set search_path to ''
as $$
declare
  _conv public.conversations;
  _agent public.agents;
  _actor uuid;
begin
  select * into _conv
  from public.conversations
  where id = p_conversation_id;

  -- "Does not exist" and "not yours" answer the same, so this cannot be used
  -- to probe for conversation ids.
  if not found
    or _conv.organization_id not in (select rls.get_authorized_orgs('member'))
    or not rls.is_conversation_visible(
      _conv.id, _conv.organization_id, _conv.organization_address, _conv.service
    )
  then
    raise exception 'conversation % is not yours to assign', p_conversation_id
      using errcode = '42501';
  end if;

  if p_agent_id is not null then
    select * into _agent
    from public.agents
    where id = p_agent_id and organization_id = _conv.organization_id;

    if not found then
      raise exception 'agent % is not in organization %',
        p_agent_id, _conv.organization_id
        using errcode = '23503';
    end if;

    if _agent.deleted_at is not null then
      raise exception 'agent % is retired', p_agent_id;
    end if;

    -- An AI that would not answer cannot be handed a conversation: that is
    -- indistinguishable from nobody, except that nothing routes it away.
    if _agent.user_id is null
      and coalesce(_agent.extra ->> 'mode', 'active') in ('draft', 'inactive')
    then
      raise exception 'agent % does not answer (mode %)',
        p_agent_id, coalesce(_agent.extra ->> 'mode', 'active');
    end if;
  end if;

  -- The caller's own agent row, when they have one: an API key has none, and
  -- the note then records that nobody in particular did it.
  select a.id into _actor
  from public.agents a
  where a.organization_id = _conv.organization_id
    and a.id in (select rls.get_own_agents());

  return public.set_conversation_assignment(
    p_conversation_id,
    p_agent_id,
    -- Taking a conversation, or sending it back to the AI, ends the wait.
    false,
    _actor,
    '{"cause": "manual"}'::jsonb
  );
end;
$$;
