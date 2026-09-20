set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.validate_organization_attention()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  _attention jsonb := new.extra -> 'attention';
  _hours jsonb;
  _day text;
  _windows jsonb;
  _pair jsonb;
  _key text;
  _value jsonb;
  _from integer;
  _to integer;
  _last integer;
begin
  if _attention is null then
    return new;
  end if;

  -- Not a typo but a trap, and the reason this trigger validates the TYPE
  -- before anything else: attention_config is `defaults || extra->'attention'`,
  -- and jsonb's `||` with a non-object does not raise — it builds an ARRAY.
  -- Every key then reads NULL, and the guard of sweep_awaiting_human
  -- (`continue when _waited < wait`) compares against NULL, which is not
  -- true, so the sweep stops skipping: every escalated conversation is
  -- treated as overdue at once.
  if jsonb_typeof(_attention) <> 'object' then
    raise exception
      'extra.attention must be an object, got %', jsonb_typeof(_attention)
      using errcode = 'PT422';
  end if;

  -- Numbers, and no negatives: a negative wait makes every escalation overdue
  -- the moment it is made, and a negative TTL expires an assignment that was
  -- just created.
  foreach _key in array array[
    'ai_assignment_ttl_days', 'human_assignment_ttl_hours', 'human_wait_minutes'
  ] loop
    _value := _attention -> _key;

    if _value is not null then
      if jsonb_typeof(_value) <> 'number' then
        raise exception 'extra.attention.% must be a number, got %',
          _key, jsonb_typeof(_value) using errcode = 'PT422';
      end if;

      if (_value #>> '{}')::numeric < 0 then
        raise exception 'extra.attention.% may not be negative', _key
          using errcode = 'PT422';
      end if;
    end if;
  end loop;

  if _attention -> 'on_human_wait_timeout' is not null
    and (_attention ->> 'on_human_wait_timeout')
      not in ('notify_customer', 'return_to_ai') then
    raise exception
      'extra.attention.on_human_wait_timeout must be notify_customer or return_to_ai'
      using errcode = 'PT422';
  end if;

  if _attention -> 'auto_takeover' is not null
    and jsonb_typeof(_attention -> 'auto_takeover') <> 'boolean' then
    raise exception 'extra.attention.auto_takeover must be a boolean'
      using errcode = 'PT422';
  end if;

  if _attention -> 'human_wait_message' is not null
    and jsonb_typeof(_attention -> 'human_wait_message') <> 'string' then
    raise exception 'extra.attention.human_wait_message must be a string'
      using errcode = 'PT422';
  end if;

  -- A zone the server cannot resolve would make every schedule comparison
  -- raise, inside a cron job, where nobody is watching.
  if _attention -> 'timezone' is not null then
    begin
      perform now() at time zone (_attention ->> 'timezone');
    exception when others then
      raise exception 'extra.attention.timezone % is not a time zone this server knows',
        _attention ->> 'timezone' using errcode = 'PT422';
    end;
  end if;

  _hours := _attention -> 'business_hours';

  -- Absent or null is 24/7, which is what an organization that never
  -- configured one gets. Anything else has to be a week.
  if _hours is null or jsonb_typeof(_hours) = 'null' then
    return new;
  end if;

  if jsonb_typeof(_hours) <> 'object' then
    raise exception
      'extra.attention.business_hours must be an object or null, got %',
      jsonb_typeof(_hours) using errcode = 'PT422';
  end if;

  for _day, _windows in select * from jsonb_each(_hours) loop
    if _day not in ('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun') then
      raise exception 'extra.attention.business_hours has no day %', _day
        using errcode = 'PT422';
    end if;

    if jsonb_typeof(_windows) <> 'array' then
      raise exception
        'extra.attention.business_hours.% must be a list of windows, got %',
        _day, jsonb_typeof(_windows) using errcode = 'PT422';
    end if;

    -- Shape and spelling first, so the arithmetic below parses digits and
    -- not whatever was stored.
    for _pair in select w from jsonb_array_elements(_windows) as w loop
      if jsonb_typeof(_pair) <> 'array' or jsonb_array_length(_pair) <> 2 then
        raise exception
          'extra.attention.business_hours.% must hold [from, to] pairs', _day
          using errcode = 'PT422';
      end if;

      if jsonb_typeof(_pair -> 0) <> 'string'
        or jsonb_typeof(_pair -> 1) <> 'string' then
        raise exception
          'extra.attention.business_hours.% must hold times as strings', _day
          using errcode = 'PT422';
      end if;

      -- '24:00' is how this schema spells "until midnight" (see
      -- attention_day_windows), so it is legal here and nowhere else.
      if (_pair ->> 0) !~ '^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$'
        or (_pair ->> 1) !~ '^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$' then
        raise exception
          'extra.attention.business_hours.% has a time that is not HH:MM: % to %',
          _day, _pair ->> 0, _pair ->> 1 using errcode = 'PT422';
      end if;

      _from := (split_part(_pair ->> 0, ':', 1))::int * 60
        + (split_part(_pair ->> 0, ':', 2))::int;
      _to := (split_part(_pair ->> 1, ':', 1))::int * 60
        + (split_part(_pair ->> 1, ':', 2))::int;

      -- `closes` is exclusive, so an empty window is not "closed all day" —
      -- that is spelled `[]` — it is a mistake worth refusing.
      if _to <= _from then
        raise exception
          'extra.attention.business_hours.% closes at %, which is not after %',
          _day, _pair ->> 1, _pair ->> 0 using errcode = 'PT422';
      end if;
    end loop;

    -- Then overlap, walking the day in order of opening time. Two windows
    -- over the same hour would count that hour twice in a wait.
    _last := -1;

    for _from, _to in
      select
        (split_part(w ->> 0, ':', 1))::int * 60
          + (split_part(w ->> 0, ':', 2))::int,
        (split_part(w ->> 1, ':', 1))::int * 60
          + (split_part(w ->> 1, ':', 2))::int
      from jsonb_array_elements(_windows) as w
      order by 1
    loop
      if _from < _last then
        raise exception
          'extra.attention.business_hours.% has two windows over the same hour',
          _day using errcode = 'PT422';
      end if;

      _last := _to;
    end loop;
  end loop;

  return new;
end;
$function$
;

CREATE TRIGGER validate_extra BEFORE INSERT OR UPDATE ON public.organizations FOR EACH ROW WHEN ((new.extra IS NOT NULL)) EXECUTE FUNCTION public.validate_organization_attention();


