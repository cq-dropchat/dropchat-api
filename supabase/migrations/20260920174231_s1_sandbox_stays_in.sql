drop trigger if exists "handle_mark_as_read_to_dispatcher" on "public"."messages";

set check_function_bodies = off;

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
  if service in ('local', 'sandbox') then
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

CREATE OR REPLACE FUNCTION public.notify_webhook()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  -- S1 (B2): the simulator is out of webhooks. An integrator subscribed to
  -- `messages` wants their customers' traffic, not a colleague rehearsing
  -- against an agent — a drill arriving as a real event would be a false
  -- order, a false lead, a false anything their system acts on.
  --
  -- Asked of the row rather than of a column, because this one trigger is on
  -- five tables and only three of them have `service`. The three that do are
  -- exactly the ones a sandbox row can be written to.
  if to_jsonb(new) ->> 'service' = 'sandbox' then
    return new;
  end if;

  insert into public.webhook_deliveries (organization_id, webhook_id, event, payload)
  select
    new.organization_id,
    w.id,
    tg_table_name || '.' || lower(tg_op),
    jsonb_build_object(
      'data', to_jsonb(new),
      'entity', tg_table_name,
      'action', lower(tg_op)
    )
  from public.webhooks w
  where w.organization_id = new.organization_id
    and w.table_name = tg_table_name::public.webhook_table
    and lower(tg_op)::public.webhook_operation = any(w.operations)
  order by w.created_at;

  return new;
end;
$function$
;

CREATE TRIGGER handle_mark_as_read_to_dispatcher AFTER UPDATE ON public.messages FOR EACH ROW WHEN (((new.sender_address IS NOT NULL) AND (new.service <> ALL (ARRAY['local'::public.service, 'slack'::public.service, 'sandbox'::public.service])) AND (((old.status ->> 'read'::text) <> (new.status ->> 'read'::text)) OR ((old.status ->> 'typing'::text) <> (new.status ->> 'typing'::text))) AND ((new.status ->> 'pending'::text) IS NOT NULL))) EXECUTE FUNCTION public.dispatcher_edge_function();


