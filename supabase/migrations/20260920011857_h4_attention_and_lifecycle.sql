set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.attention_business_minutes(p_config jsonb, p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.attention_config(p_extra jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.attention_day_windows(p_config jsonb, p_date date)
 RETURNS TABLE(opens time without time zone, closes time without time zone)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.attention_is_open(p_config jsonb, p_at timestamp with time zone)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.attention_next_opening(p_config jsonb, p_at timestamp with time zone)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.channel_window_open(p_conversation_id uuid, p_at timestamp with time zone DEFAULT now())
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.expire_human_assignments(p_limit integer DEFAULT 500)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.sweep_awaiting_human(p_limit integer DEFAULT 500)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;



-- Privileges: db diff does not model them (see CLAUDE.md). The two sweeps run
-- from pg_cron and nowhere else; the helpers they use are internal too, and
-- the ones agent-client needs it reaches through the organization's row, not
-- by RPC.
revoke execute on function public.expire_human_assignments(integer)
  from public, anon, authenticated;
revoke execute on function public.sweep_awaiting_human(integer)
  from public, anon, authenticated;
revoke execute on function public.attention_config(jsonb)
  from public, anon, authenticated;
revoke execute on function public.attention_day_windows(jsonb, date)
  from public, anon, authenticated;
revoke execute on function public.attention_business_minutes(jsonb, timestamp with time zone, timestamp with time zone)
  from public, anon, authenticated;
revoke execute on function public.attention_is_open(jsonb, timestamp with time zone)
  from public, anon, authenticated;
revoke execute on function public.attention_next_opening(jsonb, timestamp with time zone)
  from public, anon, authenticated;
revoke execute on function public.channel_window_open(uuid, timestamp with time zone)
  from public, anon, authenticated;

-- Hand-written: pg_cron schedules are imperative, db diff cannot model them.
--
-- The wait sweep runs every minute because it is what the CONTACT is waiting
-- on: half an hour late plus a minute is fine, half an hour late plus fifteen
-- is not. The human expiry runs every fifteen, because nobody is waiting on
-- it — it only decides that a conversation goes back to the queue.
--
-- Both are bounded (500 conversations a run) and idempotent, so a run that
-- overlaps the previous one cannot double anything.
select cron.schedule(
  'sweep-awaiting-human',
  '* * * * *',
  $$ select public.sweep_awaiting_human(500) $$
);

select cron.schedule(
  'expire-human-assignments',
  '*/15 * * * *',
  $$ select public.expire_human_assignments(500) $$
);
