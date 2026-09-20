-- H4 — the organization's attention settings, and the arithmetic of
-- "within business hours".
--
-- The settings live in organizations.extra.attention (a jsonb bag, like every
-- other organization setting) and every reader goes through
-- attention_config, which fills in the defaults of A6. Nothing else may
-- assume a key is there.
--
-- The schedule is what makes a wait measurable: a handover at 18:59 on a
-- Friday is not late at 19:29 on a Friday, it is late on Monday morning. So
-- the sweeps of this phase count BUSINESS minutes, not wall-clock ones.
--
-- The arithmetic is here, in SQL, because the sweeps are pg_cron jobs and a
-- cron job that has to call an edge function to know whether it may act is a
-- cron job that stops working when the function does. agent-client computes
-- "open now / next opening" again in TypeScript for the system prompt — the
-- same cases, checked against these functions by a shared fixture
-- (_traces/attention_parity.test.ts).
create function public.attention_config(p_extra jsonb) returns jsonb
language sql
immutable
set search_path to ''
as $$
  select jsonb_build_object(
    'timezone', 'America/Santiago',
    -- Null, not a Monday-to-Friday guess: an organization that has not said
    -- when it works is reachable at any hour (the wait of an escalation then
    -- runs through the night, which is the safe side — it hurries the team
    -- rather than the customer).
    'business_hours', null,
    'ai_assignment_ttl_days', 14,
    -- Hours, or 0 for "never expires". Not null for that: `extra` is written
    -- as a JSON merge patch (merge_update), where a null REMOVES the key —
    -- so an organization could not store one, and a null would silently read
    -- back as this default.
    'human_assignment_ttl_hours', 72,
    'human_wait_minutes', 30,
    'on_human_wait_timeout', 'notify_customer',
    'human_wait_message',
      'Nuestro equipo te responderá apenas esté disponible. Gracias por la espera.',
    'auto_takeover', true
  ) || coalesce(p_extra -> 'attention', '{}'::jsonb);
$$;

-- The day's windows, as [start, end) local times, for a date in the
-- organization's timezone. `[]` (or a missing key) means closed all day.
create function public.attention_day_windows(p_config jsonb, p_date date)
returns table (opens time, closes time)
language sql
immutable
set search_path to ''
as $$
  select
    (w ->> 0)::time,
    -- '24:00' is a legal way to say "until midnight" in a schedule and not a
    -- legal `time`, so it is spelled as the last minute-boundary instead.
    case when (w ->> 1) = '24:00' then '23:59:59.999999'::time
         else (w ->> 1)::time end
  from jsonb_array_elements(
    coalesce(
      p_config -> 'business_hours' -> (
        -- isodow, not to_char: day names are locale-dependent.
        (array['mon','tue','wed','thu','fri','sat','sun'])[
          extract(isodow from p_date)::int
        ]
      ),
      '[]'::jsonb
    )
  ) as w;
$$;

-- Business minutes between two instants. With no schedule configured, every
-- minute counts.
--
-- Walks days in the organization's timezone, so a day that has 23 or 25 hours
-- (Chile moves its clocks twice a year) contributes what it really lasts: the
-- window's bounds are local times, turned into instants in that zone.
create function public.attention_business_minutes(
  p_config jsonb,
  p_from timestamp with time zone,
  p_to timestamp with time zone
) returns numeric
language plpgsql
stable
set search_path to ''
as $$
declare
  _tz text := coalesce(p_config ->> 'timezone', 'America/Santiago');
  _minutes numeric := 0;
  _day date;
  _window record;
  _opens timestamp with time zone;
  _closes timestamp with time zone;
begin
  if p_to <= p_from then
    return 0;
  end if;

  if p_config -> 'business_hours' is null
    or p_config -> 'business_hours' = 'null'::jsonb then
    return extract(epoch from (p_to - p_from)) / 60;
  end if;

  for _day in
    select d::date
    from generate_series(
      (p_from at time zone _tz)::date,
      (p_to at time zone _tz)::date,
      interval '1 day'
    ) as d
  loop
    for _window in
      select * from public.attention_day_windows(p_config, _day)
    loop
      _opens := (_day + _window.opens) at time zone _tz;
      _closes := (_day + _window.closes) at time zone _tz;

      _minutes := _minutes + greatest(
        0,
        extract(epoch from (
          least(_closes, p_to) - greatest(_opens, p_from)
        )) / 60
      );
    end loop;
  end loop;

  -- The '24:00' spelling loses a microsecond a day; a wait is measured in
  -- minutes, so round to the minute rather than carry that into comparisons.
  return round(_minutes);
end;
$$;

create function public.attention_is_open(
  p_config jsonb,
  p_at timestamp with time zone
) returns boolean
language sql
stable
set search_path to ''
as $$
  select case
    when p_config -> 'business_hours' is null
      or p_config -> 'business_hours' = 'null'::jsonb
    then true
    else exists (
      select 1
      from public.attention_day_windows(
        p_config,
        (p_at at time zone coalesce(p_config ->> 'timezone', 'America/Santiago'))::date
      ) w
      where (p_at at time zone coalesce(p_config ->> 'timezone', 'America/Santiago'))::time
        between w.opens and w.closes
    )
  end;
$$;

-- When the organization opens next, or null when it never closed. Used by the
-- system prompt, so the agent can say "te responden mañana desde las 9" when
-- it hands a conversation over after hours.
create function public.attention_next_opening(
  p_config jsonb,
  p_at timestamp with time zone
) returns timestamp with time zone
language plpgsql
stable
set search_path to ''
as $$
declare
  _tz text := coalesce(p_config ->> 'timezone', 'America/Santiago');
  _day date;
  _window record;
  _opens timestamp with time zone;
begin
  if p_config -> 'business_hours' is null
    or p_config -> 'business_hours' = 'null'::jsonb then
    return null;
  end if;

  -- Two weeks is enough to answer for any weekly schedule, and bounds the
  -- walk for one that is empty (an organization that closed every day).
  for _day in
    select d::date
    from generate_series(
      (p_at at time zone _tz)::date,
      (p_at at time zone _tz)::date + 14,
      interval '1 day'
    ) as d
  loop
    for _window in
      select * from public.attention_day_windows(p_config, _day) order by opens
    loop
      _opens := (_day + _window.opens) at time zone _tz;

      if _opens > p_at then
        return _opens;
      end if;
    end loop;
  end loop;

  return null;
end;
$$;

-- H4 — is the channel still open to us?
--
-- WhatsApp and Instagram only let a business write inside a window that the
-- CONTACT's last message opened (24 hours). Past it, an insert is a message
-- that fails at the dispatcher, which is worse than silence: the customer
-- sees nothing and the organization sees an error. So the wait sweep asks
-- this before writing anything to a contact.
--
-- Instagram's window can be extended to 7 days with the HUMAN_AGENT tag, but
-- only for a person's reply; the sweep's message is the system's, so 24 hours
-- is the honest bound here.
create function public.channel_window_open(
  p_conversation_id uuid,
  p_at timestamp with time zone default now()
) returns boolean
language sql
stable
set search_path to ''
as $$
  select case
    when c.service not in (
      'whatsapp'::public.service,
      'instagram'::public.service,
      'whatsapp-web'::public.service
    ) then true
    else exists (
      select 1
      from public.messages m
      where m.conversation_id = c.id
        and m.sender_address is not null
        and m.timestamp > p_at - interval '24 hours'
    )
  end
  from public.conversations c
  where c.id = p_conversation_id;
$$;

-- H4 — a human assignment that nobody is working on goes back to routing.
--
-- "Working on it" is measured in messages, not in the assignment's age: a
-- person who answers every day keeps the conversation for as long as they
-- keep answering. With human_assignment_ttl_hours set to null it never
-- expires, which is what an organization that wants a person to hold a
-- conversation indefinitely sets.
create function public.expire_human_assignments(p_limit integer default 500)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  _conv record;
  _count integer := 0;
begin
  for _conv in
    select c.id, c.assigned_agent_id, c.assigned_at, o.extra as org_extra
    from public.conversations c
    join public.agents a on a.id = c.assigned_agent_id
    join public.organizations o on o.id = c.organization_id
    where c.assigned_agent_id is not null
      and a.user_id is not null
      and o.deletion_requested_at is null
    order by c.assigned_at
    limit p_limit
  loop
    declare
      _ttl numeric := (
        public.attention_config(_conv.org_extra) ->> 'human_assignment_ttl_hours'
      )::numeric;
      _last timestamp with time zone;
    begin
      -- 0 (or an unstorable null) means a person keeps the conversation
      -- until they let go of it.
      continue when _ttl is null or _ttl <= 0;

      -- The last thing that person sent here, or the moment they took it.
      select max(m.timestamp) into _last
      from public.messages m
      where m.conversation_id = _conv.id
        and m.agent_id = _conv.assigned_agent_id
        and m.sender_address is null;

      _last := greatest(coalesce(_last, _conv.assigned_at), _conv.assigned_at);

      if _last > now() - make_interval(hours => _ttl::int) then
        continue;
      end if;

      perform public.set_conversation_assignment(
        _conv.id, null, false, null, '{"cause": "expiry"}'::jsonb
      );

      _count := _count + 1;
    end;
  end loop;

  return _count;
end;
$$;

-- H4 — an escalation nobody answered.
--
-- The contact was told a person would come. When the wait passes
-- human_wait_minutes of BUSINESS time, the organization's choice applies:
-- say so (once), or hand the conversation back to the AI.
--
-- Idempotent on both paths: `extra.human_wait_notified_at` marks the message
-- as sent, and handing back clears both the wait and the mark.
create function public.sweep_awaiting_human(p_limit integer default 500)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  _conv record;
  _count integer := 0;
begin
  for _conv in
    select c.id, c.organization_id, c.service, c.organization_address,
           c.address, c.awaiting_human_since, c.extra, o.extra as org_extra
    from public.conversations c
    join public.organizations o on o.id = c.organization_id
    where c.awaiting_human_since is not null
      and o.deletion_requested_at is null
    order by c.awaiting_human_since
    limit p_limit
  loop
    declare
      _config jsonb := public.attention_config(_conv.org_extra);
      _waited numeric;
    begin
      _waited := public.attention_business_minutes(
        _config, _conv.awaiting_human_since, now()
      );

      continue when _waited < (_config ->> 'human_wait_minutes')::numeric;

      if _config ->> 'on_human_wait_timeout' = 'return_to_ai' then
        perform public.set_conversation_assignment(
          _conv.id, null, false, null, '{"cause": "expiry"}'::jsonb
        );

        -- The wait is over, so the mark that says "we already told them"
        -- goes with it: a later escalation starts a fresh wait.
        --
        -- A null in the patch, not a smaller object: `extra` is written
        -- through merge_update, a JSON merge patch, so the only way to
        -- remove a key is to set it to null (subtracting it would be merged
        -- straight back).
        update public.conversations
        set extra = '{"human_wait_notified_at": null}'::jsonb
        where id = _conv.id;

        _count := _count + 1;

        continue;
      end if;

      -- notify_customer, once.
      continue when (_conv.extra ->> 'human_wait_notified_at') is not null;

      -- Outside the channel's window the message would fail at the
      -- dispatcher. Nothing is marked, so it goes out if the contact writes
      -- again; telling the TEAM again is H5's job.
      continue when not public.channel_window_open(_conv.id);

      insert into public.messages (
        organization_id, conversation_id, service, organization_address,
        conversation_address, content
      )
      values (
        _conv.organization_id, _conv.id, _conv.service,
        _conv.organization_address, _conv.address,
        jsonb_build_object(
          'version', '1',
          'type', 'text',
          'kind', 'text',
          'text', _config ->> 'human_wait_message'
        )
      );

      update public.conversations
      set extra = coalesce(extra, '{}'::jsonb)
        || jsonb_build_object('human_wait_notified_at', now())
      where id = _conv.id;

      _count := _count + 1;
    end;
  end loop;

  return _count;
end;
$$;
