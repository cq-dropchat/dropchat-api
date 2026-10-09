set check_function_bodies = off;

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

  if p_limit > 1000 or p_per_conversation > 50 then
    raise exception 'Preview limits exceed the bounded inbox window' using errcode = '22023';
  end if;

  -- Mixed traffic normally fills the window from a short global prefix.
  -- Only a concentrated prefix needs the per-conversation fallback below.
  select coalesce(array_agg(w.id order by w.timestamp desc, w.id desc), '{}'::uuid[])
  into _ids
  from (
    select ranked.id, ranked.timestamp
    from (
      select recent.*, row_number() over (
        partition by recent.conversation_id order by recent.timestamp desc, recent.id desc
      ) as rank
      from (
        select m.id, m.conversation_id, m.timestamp
        from public.messages m
        where m.organization_id = p_organization_id
          and (p_since is null or m.timestamp > p_since)
          and (p_until is null or m.timestamp < p_until)
          and m.timestamp <= now()
        order by m.timestamp desc, m.id desc
        limit p_limit * 4
      ) recent
    ) ranked
    where ranked.rank <= p_per_conversation
    order by ranked.timestamp desc, ranked.id desc
    limit p_limit
  ) w;

  if coalesce(array_length(_ids, 1), 0) < p_limit then
  select coalesce(array_agg(w.id order by w.timestamp desc, w.id desc), '{}'::uuid[])
  into _ids
  from (
    select recent.id, recent.timestamp
    from public.conversations c
    -- Correlate BOTH index keys. With a skewed ANALYZE sample, fixing the
    -- tenant to a constant can make PostgreSQL choose the global time index
    -- and filter the entire hot history once for each cold conversation.
    cross join lateral (
      select m.id, m.timestamp
      from public.messages m
      where m.organization_id = c.organization_id
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

  end if;

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


