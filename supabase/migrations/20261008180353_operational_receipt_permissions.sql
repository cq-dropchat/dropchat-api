revoke delete on table "public"."webhook_receipts" from "anon";

revoke insert on table "public"."webhook_receipts" from "anon";

revoke references on table "public"."webhook_receipts" from "anon";

revoke select on table "public"."webhook_receipts" from "anon";

revoke trigger on table "public"."webhook_receipts" from "anon";

revoke truncate on table "public"."webhook_receipts" from "anon";

revoke update on table "public"."webhook_receipts" from "anon";

revoke delete on table "public"."webhook_receipts" from "authenticated";

revoke insert on table "public"."webhook_receipts" from "authenticated";

revoke references on table "public"."webhook_receipts" from "authenticated";

revoke select on table "public"."webhook_receipts" from "authenticated";

revoke trigger on table "public"."webhook_receipts" from "authenticated";

revoke truncate on table "public"."webhook_receipts" from "authenticated";

revoke update on table "public"."webhook_receipts" from "authenticated";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.claim_webhook_receipt(_id uuid)
 RETURNS SETOF public.webhook_receipts
 LANGUAGE sql
 SET search_path TO ''
AS $function$
  update public.webhook_receipts set status='processing', attempts=attempts+1,
    lease_token=gen_random_uuid(),lease_until=now()+interval '10 minutes'
  where id=_id and attempts<public.edge_call_max_attempts() and (
    (status='pending' and next_attempt_at<=now()) or (status='processing' and lease_until<now())
  ) returning *;
$function$
;

CREATE OR REPLACE FUNCTION public.complete_webhook_receipt(_id uuid, _lease_token uuid, _success boolean, _error_class text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare changed integer;
begin
  update public.webhook_receipts set
    status=case when _success then 'done' when attempts>=public.edge_call_max_attempts() then 'failed' else 'pending' end,
    payload=case when _success then '{}'::jsonb else payload end,
    last_error_class=case when _success then null else left(_error_class,100) end,
    next_attempt_at=now()+public.edge_call_retry_delay(attempts),lease_token=null,lease_until=null
  where id=_id and status='processing' and lease_token=_lease_token;
  get diagnostics changed=row_count;
  return changed=1;
end $function$
;

CREATE OR REPLACE FUNCTION public.replay_webhook_receipts(_batch integer DEFAULT 20)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare base_url text; token text; row record; sent integer:=0;
begin
  select * into base_url,token from public.edge_functions_config();
  update public.webhook_receipts set status='failed',lease_until=null,lease_token=null,last_error_class='lease_expired'
  where status='processing' and lease_until<now() and attempts>=public.edge_call_max_attempts();
  for row in select id from public.webhook_receipts
    where ((status='pending' and next_attempt_at<=now()) or
      (status='processing' and lease_until<now() and attempts<public.edge_call_max_attempts()))
    and (last_scheduled_at is null or last_scheduled_at<now()-interval '30 seconds')
    order by next_attempt_at,id limit least(greatest(_batch,0),100) for update skip locked
  loop
    perform net.http_post(url:=base_url||'/webhook-replay',body:=jsonb_build_object('receipt_id',row.id),
      headers:=jsonb_build_object('content-type','application/json','authorization','Bearer '||token),timeout_milliseconds:=10000);
    -- A missed request remains durable. Transport success never completes work.
    update public.webhook_receipts set last_scheduled_at=now() where id=row.id;
    sent:=sent+1;
  end loop;
  return sent;
end $function$
;


