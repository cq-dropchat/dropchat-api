drop index if exists "public"."edge_calls_pending_idx";

CREATE INDEX edge_calls_active_record_idx ON public.edge_calls USING btree (record_id, function) WHERE (status = ANY (ARRAY['pending'::text, 'sending'::text]));

CREATE INDEX edge_calls_pending_idx ON public.edge_calls USING btree (organization_id, next_attempt_at, id) WHERE (status = 'pending'::text);

set check_function_bodies = off;

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
      where m.organization_id = c.organization_id
        and m.conversation_id = c.id
        and m.sender_address is not null
        and m.timestamp > p_at - interval '24 hours'
    )
  end
  from public.conversations c
  where c.id = p_conversation_id;
$function$
;

CREATE OR REPLACE FUNCTION public.dispatch_edge_calls(_batch integer DEFAULT 1000, _per_org integer DEFAULT 250)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _base_url text;
  _token text;
  _row record;
  _request_id bigint;
  _sent integer := 0;
begin
  select * into _base_url, _token from public.edge_functions_config();

  for _row in
    select c.id, c.function, c.payload, c.forward_headers
    from (
      select p.id,
        row_number() over (partition by o.id order by p.next_attempt_at, p.id) as rank,
        p.next_attempt_at
      from public.organizations o
      cross join lateral (
        select q.id, q.next_attempt_at
        from public.edge_calls q
        where q.organization_id = o.id
          and q.status = 'pending'
          and q.next_attempt_at <= now()
        order by q.next_attempt_at, q.id
        limit least(greatest(_per_org, 0), greatest(_batch, 0))
      ) p
    ) ranked
    join public.edge_calls c on c.id = ranked.id
    where ranked.rank <= _per_org
    order by ranked.rank, ranked.next_attempt_at, c.id
    limit greatest(_batch, 0)
    for update of c skip locked
  loop
    select net.http_post(
      url := _base_url || '/' || _row.function,
      body := _row.payload,
      headers := jsonb_build_object(
        'content-type', 'application/json',
        'authorization', 'Bearer ' || _token
      ) || _row.forward_headers,
      timeout_milliseconds := 10000
    ) into _request_id;

    update public.edge_calls
    set status = 'sending',
        attempts = attempts + 1,
        request_id = _request_id,
        locked_until = now() + public.edge_call_lease()
    where id = _row.id;

    _sent := _sent + 1;
  end loop;

  return _sent;
end;
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
    select c.id
    from public.conversations c
    join public.agents a on a.id = c.assigned_agent_id
    join public.organizations o on o.id = c.organization_id
    cross join lateral (
      select (public.attention_config(o.extra) ->> 'human_assignment_ttl_hours')::numeric as ttl
    ) config
    where c.assigned_agent_id is not null
      and a.user_id is not null
      and o.deletion_requested_at is null
      and config.ttl > 0
      and c.assigned_at <= now() - make_interval(hours => config.ttl::int)
      and not exists (
        select 1 from public.messages m
        where m.organization_id = c.organization_id
          and m.conversation_id = c.id
          and m.agent_id = c.assigned_agent_id
          and m.sender_address is null
          and m.timestamp > now() - make_interval(hours => config.ttl::int)
      )
    order by c.assigned_at, c.id
    limit greatest(p_limit, 0)
    for update of c skip locked
  loop
    perform public.set_conversation_assignment(
      _conv.id, null, false, null, '{"cause": "expiry"}'::jsonb
    );
    _count := _count + 1;
  end loop;

  return _count;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.init_data(p_organization_id uuid, p_limit integer DEFAULT 200, p_per_conversation integer DEFAULT 10, p_since timestamp with time zone DEFAULT NULL::timestamp with time zone, p_until timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS json
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  _ids uuid[] := '{}';
  _messages json;
  _conversations json;
  _conversation_ids uuid[];
begin
  if p_limit <= 0 or p_per_conversation <= 0 then
    return json_build_object('conversations', '[]'::json, 'messages', '[]'::json);
  end if;

  select coalesce(array_agg(w.id order by w.timestamp desc, w.id desc), '{}'::uuid[])
  into _ids
  from (
    select recent.id, recent.timestamp
    from public.conversations c
    cross join lateral (
      select m.id, m.timestamp
      from public.messages m
      where m.organization_id = p_organization_id
        and m.conversation_id = c.id
        and (p_since is null or m.timestamp > p_since)
        and (p_until is null or m.timestamp < p_until)
        and m.timestamp <= now()
      order by m.timestamp desc, m.id desc
      limit least(p_per_conversation, p_limit)
    ) recent
    where c.organization_id = p_organization_id
    order by recent.timestamp desc, recent.id desc
    limit p_limit
  ) w;

  -- The rows, in the order they were kept. `= any(array)` probes the
  -- primary key; a join through unnest() of a parameter array let the
  -- planner guess 100 rows and hash the whole organization instead
  -- (150 ms and 18 MB of temp at 60k rows).
  select coalesce(json_agg(row_to_json(m.*) order by array_position(_ids, m.id)), '[]'::json),
         array_agg(distinct m.conversation_id)
  into _messages, _conversation_ids
  from public.messages m
  where m.id = any(_ids);

  select coalesce(json_agg(row_to_json(c.*)), '[]'::json)
  into _conversations
  from public.conversations c
  where c.id = any(_conversation_ids);

  return json_build_object(
    'conversations', _conversations,
    'messages', _messages
  );
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
      and public.attention_business_minutes(
        public.attention_config(o.extra), c.awaiting_human_since, now()
      ) >= (public.attention_config(o.extra) ->> 'human_wait_minutes')::numeric
      and (
        public.attention_config(o.extra) ->> 'on_human_wait_timeout' = 'return_to_ai'
        or (
          c.extra ->> 'human_wait_notified_at' is null
          and public.channel_window_open(c.id)
        )
      )
    order by c.awaiting_human_since, c.id
    limit greatest(p_limit, 0)
    for update of c skip locked
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

CREATE OR REPLACE FUNCTION public.sweep_pending_media(_limit integer DEFAULT 500)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _queued integer;
begin
  with due as (
    select m.*
    from public.messages m
    where m.timestamp >= now() - interval '12 hours'
      and m.timestamp <= now() - interval '1 minute'
      and m.content ->> 'type' = 'file'
      and m.status ->> 'pending' is not null
      and m.status ->> 'preprocessed' is null
      and (
        m.status ->> 'preprocessing' is null
        or (m.status ->> 'preprocessing')::timestamptz
             < now() - interval '10 minutes'
      )
      and not exists (
        select 1
        from public.edge_calls c
        where c.record_id = m.id
          and c.function = 'media-preprocessor'
          and c.status in ('pending', 'sending')
      )
    order by m.timestamp, m.id
    limit _limit
  ), queued as (
    insert into public.edge_calls (
      organization_id, function, record_id, payload, forward_headers
    )
    select
      d.organization_id,
      'media-preprocessor',
      d.id,
      jsonb_build_object(
        'old_record', null,
        'record', to_jsonb(d),
        'type', 'INSERT',
        'table', 'messages',
        'schema', 'public'
      ),
      -- A sweep has no incoming request to inherit an id from; the sender
      -- mints one per request (F26).
      '{}'::jsonb
    from due d
    returning 1
  )
  select count(*) into _queued from queued;

  return _queued;
end;
$function$
;
