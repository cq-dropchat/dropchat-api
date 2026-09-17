-- CONCURRENTLY: messages is the largest table (F11, F25).
CREATE INDEX CONCURRENTLY messages_dispatch_pending_idx ON public.messages USING btree ("timestamp") WHERE ((sender_address IS NULL) AND ((status ->> 'pending'::text) IS NOT NULL));

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.claim_message_dispatch(p_message_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _claimed uuid;
begin
  update public.messages m
  set status = jsonb_build_object('dispatching', now())
  where m.id = p_message_id
    and m.status ->> 'pending' is not null
    and m.status ->> 'accepted' is null
    and m.status ->> 'sent' is null
    and m.status ->> 'delivered' is null
    and m.status ->> 'read' is null
    and m.status ->> 'failed' is null
    and (
      m.status ->> 'dispatching' is null
      or (m.status ->> 'dispatching')::timestamptz < now() - public.dispatch_lease_ttl()
    )
  returning m.id into _claimed;

  return _claimed is not null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.dispatch_lease_ttl()
 RETURNS interval
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select interval '2 minutes';
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
begin
  select decrypted_secret into _base_url from vault.decrypted_secrets where name = 'edge_functions_url';
  select decrypted_secret into _token from vault.decrypted_secrets where name = 'edge_functions_token';

  for _row in select * from public.pending_dispatch_candidates() loop
    perform net.http_post(
      url := _base_url || '/' || _row.service::text || '-dispatcher',
      headers := jsonb_build_object(
        'content-type', 'application/json',
        'authorization', 'Bearer ' || _token
      ),
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

CREATE OR REPLACE FUNCTION public.dispatch_retry_delay(attempt integer)
 RETURNS interval
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select least(interval '1 minute' * power(2, greatest(attempt - 1, 0)), interval '60 minutes');
$function$
;

CREATE OR REPLACE FUNCTION public.pending_dispatch_candidates()
 RETURNS SETOF public.messages
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select m.*
  from public.messages m
  where m.sender_address is null
    and (m.status ->> 'pending') is not null
    and m.content ->> 'internal' is null
    and m.timestamp >= now() - interval '12 hours'
    and m.timestamp <= now() - interval '1 minute'
    and m.status ->> 'held_for_quality_assessment' is null
    and m.status ->> 'accepted' is null
    and m.status ->> 'sent' is null
    and m.status ->> 'delivered' is null
    and m.status ->> 'read' is null
    and m.status ->> 'failed' is null
    and (
      m.status ->> 'dispatching' is null
      or (m.status ->> 'dispatching')::timestamptz < now() - public.dispatch_lease_ttl()
    )
    and (
      m.status ->> 'retry_at' is null
      or (m.status ->> 'retry_at')::timestamptz <= now()
    );
$function$
;

CREATE OR REPLACE FUNCTION public.release_message_dispatch(p_message_id uuid, p_errors jsonb DEFAULT '[]'::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _attempts integer;
begin
  select coalesce((m.status ->> 'attempts')::int, 0) + 1
  into _attempts
  from public.messages m
  where m.id = p_message_id;

  if _attempts is null then
    return;
  end if;

  update public.messages m
  set status = jsonb_build_object(
    'dispatching', null,
    'attempts', _attempts,
    'retry_at', now() + public.dispatch_retry_delay(_attempts),
    'errors', coalesce(p_errors, '[]'::jsonb)
  )
  where m.id = p_message_id;
end;
$function$
;



-- Hand-written: execute privileges (db diff does not emit revokes).
revoke execute on function public.claim_message_dispatch(uuid) from public;
revoke execute on function public.release_message_dispatch(uuid, jsonb) from public;
revoke execute on function public.pending_dispatch_candidates() from public;
revoke execute on function public.dispatch_pending_messages() from public;
grant execute on function public.claim_message_dispatch(uuid) to service_role;
grant execute on function public.release_message_dispatch(uuid, jsonb) to service_role;
