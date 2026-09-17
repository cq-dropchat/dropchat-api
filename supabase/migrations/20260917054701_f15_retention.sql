set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.purge_expired_rows(_batch integer DEFAULT 10000)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _hooks integer;
  _logs integer;
  _tokens integer;
begin
  delete from supabase_functions.hooks
  where id in (
    select h.id from supabase_functions.hooks h order by h.id limit _batch
  );
  get diagnostics _hooks = row_count;

  delete from public.logs
  where id in (
    select l.id from public.logs l
    where l.created_at < now() - interval '90 days'
    order by l.created_at
    limit _batch
  );
  get diagnostics _logs = row_count;

  delete from public.onboarding_tokens
  where id in (
    select t.id from public.onboarding_tokens t
    where t.expires_at < now() - interval '30 days'
    limit _batch
  );
  get diagnostics _tokens = row_count;

  return jsonb_build_object(
    'hooks', _hooks,
    'logs', _logs,
    'onboarding_tokens', _tokens
  );
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

  select decrypted_secret into base_url from vault.decrypted_secrets where name = 'edge_functions_url';
  select decrypted_secret into auth_token from vault.decrypted_secrets where name = 'edge_functions_token';
  
  headers = jsonb_build_object(
    'content-type', 'application/json',
    'authorization', 'Bearer ' || auth_token
  );
  
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

  if tg_argv[2] is null or tg_argv[2] = 'null' then
    select decrypted_secret into auth_token from vault.decrypted_secrets where name = 'edge_functions_token';

    headers = jsonb_build_object(
      'content-type', 'application/json',
      'authorization', 'Bearer ' || auth_token
    );
  else
    headers = tg_argv[2]::jsonb;
  end if;

  if tg_argv[3] is null or tg_argv[3] = 'null' then
    params = '{}'::jsonb;
  else
    params = tg_argv[3]::jsonb;
  end if;

  select decrypted_secret into base_url from vault.decrypted_secrets where name = 'edge_functions_url';

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

  select decrypted_secret into base_url
  from vault.decrypted_secrets where name = 'edge_functions_url';
  select decrypted_secret into auth_token
  from vault.decrypted_secrets where name = 'edge_functions_token';

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
    ),
    10000
  );

  return new;
end
$function$
;



-- Hand-written: execute privileges (db diff does not model them).
revoke execute on function public.purge_expired_rows(integer) from public, anon, authenticated;

-- Hand-written: pg_cron schedules are imperative, db diff cannot model them.
select cron.schedule(
  'purge-expired-rows',
  '17 * * * *',
  $$ select public.purge_expired_rows(); $$
);
