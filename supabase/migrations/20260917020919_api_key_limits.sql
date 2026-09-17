drop trigger if exists "check_billing_message_limit" on "public"."messages";


  create table "public"."rate_limits" (
    "organization_id" uuid not null,
    "scope" text not null,
    "window_start" timestamp with time zone not null,
    "count" integer not null default 0,
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."rate_limits" enable row level security;

-- Hand-written: the diff only sees the service_role grants, not the revoke
-- that undoes the default privileges (same as 20260917015330_secrets.sql).
revoke all on table "public"."rate_limits" from anon, authenticated;

CREATE UNIQUE INDEX rate_limits_pkey ON public.rate_limits USING btree (organization_id, scope, window_start);

alter table "public"."rate_limits" add constraint "rate_limits_pkey" PRIMARY KEY using index "rate_limits_pkey";

alter table "public"."rate_limits" add constraint "rate_limits_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE not valid;

alter table "public"."rate_limits" validate constraint "rate_limits_organization_id_fkey";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION billing.check_message_limit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  -- auth.role(): the JWT claim, not current_role — this function is
  -- SECURITY DEFINER, so current_role would be its owner.
  if (
    new.sender_address is null
    and new.content ->> 'internal' is null
  ) or coalesce(auth.role(), '') in ('anon', 'authenticated') then
    perform billing.check_limit(new.organization_id, 'messages');
  end if;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.check_message_rate_limit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _window timestamp with time zone := date_trunc('minute', now());
  _count integer;
begin
  -- auth.role() is the JWT claim PostgREST sets — 'anon' for an API key,
  -- 'authenticated' for a member, 'service_role' for the service key. Not
  -- current_role: inside a SECURITY DEFINER function that is the owner.
  if coalesce(auth.role(), '') not in ('anon', 'authenticated') then
    return new;
  end if;

  insert into public.rate_limits (organization_id, scope, window_start, count)
  values (new.organization_id, 'messages', _window, 1)
  on conflict (organization_id, scope, window_start)
  do update set count = public.rate_limits.count + 1, updated_at = now()
  returning count into _count;

  if _count > public.message_rate_limit_per_minute() then
    raise exception 'Rate limit exceeded: % messages per minute per organization',
      public.message_rate_limit_per_minute()
      using errcode = 'PT429',
        hint = 'retry after the current minute ends';
  end if;

  -- First hit of a new minute: sweep this organization's stale windows.
  if _count = 1 then
    delete from public.rate_limits r
    where r.organization_id = new.organization_id
      and r.scope = 'messages'
      and r.window_start < now() - interval '1 hour';
  end if;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.message_rate_limit_per_minute()
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select 120;
$function$
;

grant delete on table "public"."rate_limits" to "service_role";

grant insert on table "public"."rate_limits" to "service_role";

grant references on table "public"."rate_limits" to "service_role";

grant select on table "public"."rate_limits" to "service_role";

grant trigger on table "public"."rate_limits" to "service_role";

grant truncate on table "public"."rate_limits" to "service_role";

grant update on table "public"."rate_limits" to "service_role";

CREATE TRIGGER a_check_message_rate_limit BEFORE INSERT ON public.messages FOR EACH ROW WHEN (((new.status ->> 'pending'::text) IS NOT NULL)) EXECUTE FUNCTION public.check_message_rate_limit();

CREATE TRIGGER check_billing_message_limit BEFORE INSERT ON public.messages FOR EACH ROW WHEN (((new.status ->> 'pending'::text) IS NOT NULL)) EXECUTE FUNCTION billing.check_message_limit();


