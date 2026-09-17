
  create table "public"."webhook_deliveries" (
    "id" uuid not null default gen_random_uuid(),
    "organization_id" uuid not null,
    "webhook_id" uuid not null,
    "event" text not null,
    "payload" jsonb not null,
    "status" text not null default 'pending'::text,
    "attempts" integer not null default 0,
    "next_at" timestamp with time zone not null default now(),
    "request_id" bigint,
    "last_status_code" integer,
    "last_error" text,
    "delivered_at" timestamp with time zone,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."webhook_deliveries" enable row level security;

CREATE INDEX webhook_deliveries_due_idx ON public.webhook_deliveries USING btree (next_at) WHERE (status = ANY (ARRAY['pending'::text, 'delivering'::text]));

CREATE INDEX webhook_deliveries_organization_idx ON public.webhook_deliveries USING btree (organization_id, created_at DESC);

CREATE UNIQUE INDEX webhook_deliveries_pkey ON public.webhook_deliveries USING btree (id);

alter table "public"."webhook_deliveries" add constraint "webhook_deliveries_pkey" PRIMARY KEY using index "webhook_deliveries_pkey";

alter table "public"."webhook_deliveries" add constraint "webhook_deliveries_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE not valid;

alter table "public"."webhook_deliveries" validate constraint "webhook_deliveries_organization_id_fkey";

alter table "public"."webhook_deliveries" add constraint "webhook_deliveries_status_check" CHECK ((status = ANY (ARRAY['pending'::text, 'delivering'::text, 'delivered'::text, 'failed'::text]))) not valid;

alter table "public"."webhook_deliveries" validate constraint "webhook_deliveries_status_check";

alter table "public"."webhook_deliveries" add constraint "webhook_deliveries_webhook_id_fkey" FOREIGN KEY (webhook_id) REFERENCES public.webhooks(id) ON DELETE CASCADE not valid;

alter table "public"."webhook_deliveries" validate constraint "webhook_deliveries_webhook_id_fkey";



set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.deliver_webhooks()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _settled integer;
  _sent integer;
begin
  _settled := public.settle_webhook_deliveries();
  _sent := public.dispatch_webhook_deliveries();

  return jsonb_build_object('settled', _settled, 'sent', _sent);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.dispatch_webhook_deliveries(p_batch integer DEFAULT 200)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _row record;
  _body text;
  _headers jsonb;
  _request_id bigint;
  _sent integer := 0;
begin
  for _row in
    select d.id, d.event, d.payload, w.url, w.token
    from public.webhook_deliveries d
    join public.webhooks w on w.id = d.webhook_id
    where d.status = 'pending'
      and d.next_at <= now()
    order by d.next_at
    limit p_batch
    for update of d skip locked
  loop
    -- A webhook whose URL would not be accepted today is not delivered to:
    -- rows that predate the allowlist keep their subscription, not the hole.
    if not public.is_public_https_url(_row.url) then
      update public.webhook_deliveries
      set status = 'failed',
          attempts = attempts + 1,
          last_error = 'webhook url is not a public https url'
      where id = _row.id;
      continue;
    end if;

    _body := _row.payload::text;

    _headers := jsonb_build_object(
      'content-type', 'application/json',
      'x-openbsp-delivery-id', _row.id::text,
      'x-openbsp-event', _row.event
    );

    if _row.token is not null then
      _headers := _headers
        || jsonb_build_object('authorization', 'Bearer ' || _row.token)
        || jsonb_build_object(
          'x-openbsp-signature',
          'sha256=' || encode(extensions.hmac(_body, _row.token, 'sha256'), 'hex')
        );
    end if;

    select net.http_post(
      url := _row.url,
      body := _row.payload,
      headers := _headers,
      timeout_milliseconds := 5000
    ) into _request_id;

    update public.webhook_deliveries
    set status = 'delivering',
        attempts = attempts + 1,
        request_id = _request_id
    where id = _row.id;

    _sent := _sent + 1;
  end loop;

  return _sent;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.is_public_https_url(url text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select url is not null
    and url ~* '^https://[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(:[0-9]{1,5})?(/[^\s]*)?$'
    and url !~* '^https://[^/]*\.(internal|local|localhost|lan|home|arpa)(:|/|$)'
    and url !~* '^https://[^/]*supabase\.(internal|co\.internal)(:|/|$)'
    and url !~* '^https://[^/]*@'
    -- IPv4 literal (every label numeric): 10.x, 127.x, 169.254.169.254, …
    and url !~ '^https://[0-9.]+(:|/|$)';
$function$
;

alter table "public"."webhooks" add constraint "webhooks_url_check" CHECK (public.is_public_https_url((url)::text)) NOT VALID;

CREATE OR REPLACE FUNCTION public.record_webhook_result(p_delivery_id uuid, p_status_code integer, p_error text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _attempts integer;
begin
  select attempts into _attempts
  from public.webhook_deliveries
  where id = p_delivery_id;

  if _attempts is null then
    return;
  end if;

  if p_status_code between 200 and 299 then
    update public.webhook_deliveries
    set status = 'delivered',
        delivered_at = now(),
        last_status_code = p_status_code,
        last_error = null,
        request_id = null
    where id = p_delivery_id;
  elsif _attempts >= public.webhook_max_attempts() then
    update public.webhook_deliveries
    set status = 'failed',
        last_status_code = p_status_code,
        last_error = coalesce(p_error, 'HTTP ' || p_status_code::text),
        request_id = null
    where id = p_delivery_id;
  else
    update public.webhook_deliveries
    set status = 'pending',
        next_at = now() + public.webhook_retry_delay(_attempts),
        last_status_code = p_status_code,
        last_error = coalesce(p_error, 'HTTP ' || p_status_code::text),
        request_id = null
    where id = p_delivery_id;
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.settle_webhook_deliveries()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _row record;
  _settled integer := 0;
begin
  for _row in
    select d.id, d.updated_at, r.status_code, r.timed_out, r.error_msg
    from public.webhook_deliveries d
    left join net._http_response r on r.id = d.request_id
    where d.status = 'delivering'
      and d.request_id is not null
  loop
    if _row.status_code is not null or _row.timed_out or _row.error_msg is not null then
      perform public.record_webhook_result(
        _row.id,
        coalesce(_row.status_code, 0),
        case
          when _row.timed_out then 'timed out'
          else _row.error_msg
        end
      );
      _settled := _settled + 1;
    elsif _row.updated_at < now() - interval '2 minutes' then
      perform public.record_webhook_result(_row.id, 0, 'no response');
      _settled := _settled + 1;
    end if;
  end loop;

  return _settled;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.webhook_max_attempts()
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select 5;
$function$
;

CREATE OR REPLACE FUNCTION public.webhook_retry_delay(attempt integer)
 RETURNS interval
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case attempt
    when 1 then interval '1 second'
    when 2 then interval '5 seconds'
    when 3 then interval '30 seconds'
    when 4 then interval '5 minutes'
    else interval '1 hour'
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

grant select on table "public"."webhook_deliveries" to "anon";

grant select on table "public"."webhook_deliveries" to "authenticated";

grant delete on table "public"."webhook_deliveries" to "service_role";

grant insert on table "public"."webhook_deliveries" to "service_role";

grant references on table "public"."webhook_deliveries" to "service_role";

grant select on table "public"."webhook_deliveries" to "service_role";

grant trigger on table "public"."webhook_deliveries" to "service_role";

grant truncate on table "public"."webhook_deliveries" to "service_role";

grant update on table "public"."webhook_deliveries" to "service_role";


  create policy "owners can read their orgs webhook deliveries"
  on "public"."webhook_deliveries"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs('owner'::public.role) AS get_authorized_orgs)));


CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.webhook_deliveries FOR EACH ROW EXECUTE FUNCTION public.moddatetime('updated_at');



-- Hand-written. webhooks_url_check stays NOT VALID (db diff emitted a
-- validate): subscriptions that predate the allowlist keep their row, and
-- dispatch_webhook_deliveries refuses to deliver to them instead.
-- API roles read deliveries; they never write or truncate them.
revoke all on table "public"."webhook_deliveries" from anon, authenticated;
grant select on table "public"."webhook_deliveries" to anon, authenticated;

-- The worker is not an API: it runs as postgres from pg_cron.
revoke execute on function public.webhook_retry_delay(integer) from public;
revoke execute on function public.webhook_max_attempts() from public;
revoke execute on function public.record_webhook_result(uuid, integer, text) from public;
revoke execute on function public.settle_webhook_deliveries() from public;
revoke execute on function public.dispatch_webhook_deliveries(integer) from public;
revoke execute on function public.deliver_webhooks() from public;
