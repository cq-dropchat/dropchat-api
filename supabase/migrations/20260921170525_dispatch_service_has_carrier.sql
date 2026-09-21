set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.service_has_carrier(_service public.service)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select _service not in ('local'::public.service, 'sandbox'::public.service);
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
    -- A service with no carrier has no dispatcher to post to. The insert
    -- trigger settles these, but a row dated in the future slips past its
    -- WHEN and arrives here still pending; settle it the same way rather
    -- than posting to a function that does not exist. Not counted: the
    -- return value is requests sent.
    if not public.service_has_carrier(_row.service) then
      update public.messages
      set status = jsonb_build_object('delivered', now())
      where id = _row.id;

      continue;
    end if;

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
  -- Two services have no carrier, and settle here instead of being posted
  -- to a dispatcher that does not exist:
  --
  --   local     team chat: the row IS the delivery.
  --   sandbox   S1's simulator: the tester is the only reader, and the UI
  --             they read it in is this same table. Without this the trigger
  --             would build '/sandbox-dispatcher' and POST into the void —
  --             the message would sit pending for ever and the dispatch
  --             sweep would keep picking it up.
  if not public.service_has_carrier(new.service) then
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



revoke execute on function public.service_has_carrier(public.service)
from public, anon, authenticated;
