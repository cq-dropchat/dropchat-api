-- CONCURRENTLY: messages is the largest table (audit F07, F25).
CREATE INDEX CONCURRENTLY messages_org_timestamp_idx ON public.messages USING btree (organization_id, "timestamp" DESC, id DESC);

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.init_data(p_organization_id uuid, p_limit integer DEFAULT 200, p_per_conversation integer DEFAULT 10, p_since timestamp with time zone DEFAULT NULL::timestamp with time zone, p_until timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS json
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  _row record;
  _kept jsonb := '{}'::jsonb; -- conversation_id → rows kept so far
  _count int;
  _ids uuid[] := '{}';
  _page int := greatest(p_limit, 100);
  _got int;
  _done boolean := false;
  -- Keyset of the last row read; the next page starts strictly after it.
  _last_ts timestamptz := 'infinity';
  _last_id uuid := 'ffffffff-ffff-ffff-ffff-ffffffffffff';
  _messages json;
  _conversations json;
  _conversation_ids uuid[];
begin
  if p_limit <= 0 or p_per_conversation <= 0 then
    return json_build_object('conversations', '[]'::json, 'messages', '[]'::json);
  end if;

  -- Newest first, one page at a time. A page has a LIMIT so the planner
  -- picks the index and stops at the page's end; the keyset (timestamp, id)
  -- resumes the walk exactly where the previous page ended. The first page
  -- is almost always the last: more pages only happen when busy
  -- conversations push many rows past p_per_conversation.
  loop
    _got := 0;

    for _row in
      select m.id, m.conversation_id, m.timestamp
      from public.messages m
      where m.organization_id = p_organization_id
        and (p_since is null or m.timestamp > p_since)
        and (p_until is null or m.timestamp < p_until)
        and (m.timestamp, m.id) < (_last_ts, _last_id)
      order by m.timestamp desc, m.id desc
      limit _page
    loop
      _got := _got + 1;
      _last_ts := _row.timestamp;
      _last_id := _row.id;
      _count := coalesce((_kept ->> _row.conversation_id::text)::int, 0);

      if _count < p_per_conversation then
        _ids := _ids || _row.id;
        _kept := jsonb_set(_kept, array[_row.conversation_id::text], to_jsonb(_count + 1), true);

        if array_length(_ids, 1) >= p_limit then
          _done := true;
          exit;
        end if;
      end if;
    end loop;

    exit when _done or _got < _page;
  end loop;

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


