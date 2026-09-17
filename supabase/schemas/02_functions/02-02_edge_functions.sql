-- F15: these triggers only enqueue their pg_net request. They used to also
-- insert a row per call in supabase_functions.hooks, which nothing read (~3 M
-- rows/day at 2 M messages/day); net._http_response keeps the outcome of each
-- request for pg_net's TTL. purge_expired_rows (04-08) empties the old rows.

-- F24: the edge functions' base URL and service token, from Vault, in one
-- query. The triggers below and dispatch_pending_messages (04-05) each read
-- both with their own pair of queries. Only the owner (the SECURITY DEFINER
-- triggers) may call it: it returns the service token. Not cached in a GUC
-- per transaction: that would leave the token readable by current_setting().
-- plpgsql, not sql: a SECURITY DEFINER sql function is not inlined and runs
-- as a set-returning function, ~43 µs a call against ~16 µs here.
create function public.edge_functions_config(out url text, out token text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  select
    max(s.decrypted_secret) filter (where s.name = 'edge_functions_url'),
    max(s.decrypted_secret) filter (where s.name = 'edge_functions_token')
  into url, token
  from vault.decrypted_secrets s
  where s.name in ('edge_functions_url', 'edge_functions_token');
end;
$$;

revoke execute on function public.edge_functions_config() from public, anon, authenticated, service_role;

-- F26: the `x-request-id` of the request that fired the trigger, as a
-- header to merge into the call to the next function, so a chain (webhook →
-- insert → agent-client → insert → dispatcher) logs one request id.
-- PostgREST puts the caller's headers in `request.headers`; the Edge
-- Functions' Supabase clients send the id of the request they are serving.
-- The text is client-controlled: only a UUID is forwarded (normalized to
-- lower case). Without one — cron, psql, a direct client with no id or any
-- other value — it returns '{}' and the receiver mints its own. Never sent to
-- third parties: only these calls to our own functions use it.
create function public.request_id_header() returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  _headers text := current_setting('request.headers', true);
  _id text;
begin
  if _headers is null or _headers = '' or not pg_input_is_valid(_headers, 'jsonb') then
    return '{}'::jsonb;
  end if;

  _id := _headers::jsonb ->> 'x-request-id';

  if _id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return jsonb_build_object('x-request-id', lower(_id));
  end if;

  return '{}'::jsonb;
end;
$$;

revoke execute on function public.request_id_header() from public, anon, authenticated, service_role;

create function public.dispatcher_edge_function() returns trigger
language plpgsql
security definer
as $$
declare
  service text := new.service::text;
  path text := concat('/', service, '-dispatcher');
  payload jsonb;
  base_url text;
  auth_token text;
  headers jsonb;
  timeout_ms integer := 10000;
begin
  if service = 'local' then
    update public.messages set status = jsonb_build_object('delivered', now()) where id = new.id;

    return new;
  end if;

  select * into base_url, auth_token from public.edge_functions_config();

  headers = jsonb_build_object(
    'content-type', 'application/json',
    'authorization', 'Bearer ' || auth_token
  ) || public.request_id_header();
  
  payload = jsonb_build_object(
    'old_record', old,
    'record', new,
    'type', tg_op,
    'table', tg_table_name,
    'schema', tg_table_schema
  );

  perform net.http_post(
    base_url || path,
    payload,
    '{}'::jsonb,
    headers,
    timeout_ms
  );

  return new;
end;
$$;

create function public.edge_function() returns trigger
language plpgsql
security definer
as $$
declare
  payload jsonb;
  base_url text;
  auth_token text;
  path text := tg_argv[0]::text;
  method text := tg_argv[1]::text;
  headers jsonb default '{}'::jsonb;
  params jsonb default '{}'::jsonb;
  timeout_ms integer := 10000;
begin
  if path is null or path = 'null' then
    raise exception 'path argument is missing';
  end if;

  if method is null or method = 'null' then
    raise exception 'method argument is missing';
  end if;

  select * into base_url, auth_token from public.edge_functions_config();

  if tg_argv[2] is null or tg_argv[2] = 'null' then
    headers = jsonb_build_object(
      'content-type', 'application/json',
      'authorization', 'Bearer ' || auth_token
    );
  else
    headers = tg_argv[2]::jsonb;
  end if;

  headers = headers || public.request_id_header();

  if tg_argv[3] is null or tg_argv[3] = 'null' then
    params = '{}'::jsonb;
  else
    params = tg_argv[3]::jsonb;
  end if;

  case
    when method = 'get' then
      perform net.http_get(
        base_url || path,
        params,
        headers,
        timeout_ms
      );
    when method = 'post' then
      payload = jsonb_build_object(
        'old_record', old,
        'record', new,
        'type', tg_op,
        'table', tg_table_name,
        'schema', tg_table_schema
      );

      perform net.http_post(
        base_url || path,
        payload,
        params,
        headers,
        timeout_ms
      );
    else
      raise exception 'method argument % is invalid', method;
  end case;

  return new;
end
$$;

-- The internal mirror of enqueue_edge_call('agent-client') (F12), for the
-- AI-DM flow (see handle_local_message_to_agent on messages). The trigger's
-- WHEN prefilters — local, a member author, armed — and the one fact a WHEN
-- cannot express lives here: is the other roster slot an AI agent?
--
-- A local direct's address IS its roster (agent ids, sorted, ':'-joined),
-- and RLS only allows roster edits on `group` — so "the AI answers where its
-- own id is in the address" is safe by construction: a member cannot pull
-- the AI into a real team conversation, and DMing the AI is not a mode, it
-- is just a conversation. Excluding the author (`a.id <> new.agent_id`) also
-- makes the AI's own replies a no-op here, with no special case. Everything
-- that enters and is not an AI DM — a group message, a human-human DM —
-- costs one indexed exists and exits.
create function public.local_message_to_agent() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  segments text[] := string_to_array(new.conversation_address, ':');
begin
  -- Two-member rosters only, for now: deleting this guard is the entire
  -- multi-party extension. Group/channel addresses are a single uuid and fail
  -- it too, and `is distinct from` keeps a peerless row (null address) out.
  if array_length(segments, 1) is distinct from 2 then
    return new;
  end if;

  if not exists (
    select 1 from public.agents a
    where a.organization_id = new.organization_id
      and a.id::text = any (segments)
      and a.id <> new.agent_id
      and a.user_id is null
      and a.deleted_at is null
  ) then
    return new;
  end if;

  -- F12: queued like the contact-space trigger (edge_calls), not posted.
  insert into public.edge_calls (organization_id, function, record_id, payload, forward_headers)
  values (
    new.organization_id,
    'agent-client',
    new.id,
    jsonb_build_object(
      'old_record', old,
      'record', new,
      'type', tg_op,
      'table', tg_table_name,
      'schema', tg_table_schema
    ),
    public.request_id_header()
  );

  return new;
end
$$; 

-- F12. Trigger: queue a call to the Edge Function named in tg_argv[0] with the
-- payload the old net.http_post trigger sent.
create function public.enqueue_edge_call() returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  insert into public.edge_calls (organization_id, function, record_id, payload, forward_headers)
  values (
    new.organization_id,
    tg_argv[0],
    new.id,
    jsonb_build_object(
      'old_record', old,
      'record', new,
      'type', tg_op,
      'table', tg_table_name,
      'schema', tg_table_schema
    ),
    public.request_id_header()
  );

  return new;
end;
$$;

revoke execute on function public.enqueue_edge_call() from public, anon, authenticated, service_role;
