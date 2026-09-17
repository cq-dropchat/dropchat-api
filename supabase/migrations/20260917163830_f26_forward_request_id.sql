set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.request_id_header()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.dispatch_pending_messages()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _base_url text;
  _token text;
  _count integer := 0;
  _row public.messages;
  _forward jsonb := public.request_id_header();
begin
  select * into _base_url, _token from public.edge_functions_config();

  for _row in select * from public.pending_dispatch_candidates() loop
    perform net.http_post(
      url := _base_url || '/' || _row.service::text || '-dispatcher',
      headers := jsonb_build_object(
        'content-type', 'application/json',
        'authorization', 'Bearer ' || _token
      ) || _forward,
      body := jsonb_build_object(
        'old_record', null,
        'record', to_jsonb(_row),
        'type', 'INSERT',
        'table', 'messages',
        'schema', 'public'
      ),
      timeout_milliseconds := 10000
    );
    _count := _count + 1;
  end loop;

  return _count;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.dispatcher_edge_function()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.edge_function()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.local_message_to_agent()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  segments text[] := string_to_array(new.conversation_address, ':');
  base_url text;
  auth_token text;
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

  select * into base_url, auth_token
  from public.edge_functions_config();

  perform net.http_post(
    base_url || '/agent-client',
    jsonb_build_object(
      'old_record', old,
      'record', new,
      'type', tg_op,
      'table', tg_table_name,
      'schema', tg_table_schema
    ),
    '{}'::jsonb,
    jsonb_build_object(
      'content-type', 'application/json',
      'authorization', 'Bearer ' || auth_token
    ) || public.request_id_header(),
    10000
  );

  return new;
end
$function$
;



-- Hand-written (db diff does not model privileges): internal helper, only
-- the SECURITY DEFINER writers above call it.
revoke execute on function public.request_id_header() from public, anon, authenticated, service_role;
