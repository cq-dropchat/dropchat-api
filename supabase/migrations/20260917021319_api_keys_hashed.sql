drop policy "owners can read their orgs api keys" on "public"."api_keys";

alter table "public"."api_keys" drop constraint "api_keys_key_key";

drop index if exists "public"."api_keys_key_key";

alter table "public"."api_keys" add column "expires_at" timestamp with time zone;

alter table "public"."api_keys" add column "key_hash" bytea;

alter table "public"."api_keys" add column "key_prefix" text;

alter table "public"."api_keys" add column "last_used_at" timestamp with time zone;

alter table "public"."api_keys" alter column "key" drop not null;

CREATE UNIQUE INDEX api_keys_key_hash_key ON public.api_keys USING btree (key_hash);

alter table "public"."api_keys" add constraint "api_keys_key_hash_key" UNIQUE using index "api_keys_key_hash_key";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.api_key_plaintext_cutover()
 RETURNS timestamp with time zone
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select '2026-11-01T00:00:00Z'::timestamptz;
$function$
;

CREATE OR REPLACE FUNCTION public.create_api_key(p_organization_id uuid, p_name text, p_role public.role DEFAULT 'member'::public.role, p_expires_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS TABLE(id uuid, key text, key_prefix text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _key text;
  _id uuid;
begin
  if p_organization_id not in (select public.get_authorized_orgs('owner')) then
    raise exception using
      errcode = '42501',
      message = 'only owners can create api keys';
  end if;

  if p_name is null or length(trim(p_name)) = 0 then
    raise exception using
      errcode = '22023',
      message = 'api key name is required';
  end if;

  -- 24 random bytes → 48 hex chars; `sk_` marks it as an OpenBSP secret.
  _key := 'sk_' || encode(extensions.gen_random_bytes(24), 'hex');

  insert into public.api_keys (organization_id, name, role, key, expires_at)
  values (p_organization_id, p_name, p_role, _key, p_expires_at)
  returning public.api_keys.id into _id;

  return query select _id, _key, left(_key, 8);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.hash_api_key()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  new.key_hash := extensions.digest(new.key, 'sha256');
  new.key_prefix := left(new.key, 8);
  new.key := null;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_authorized_orgs(role public.role DEFAULT 'member'::public.role)
 RETURNS SETOF uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  req_level int;
  api_key text;
  org_id uuid;
  key_id uuid;
begin
  req_level := case role::text
    when 'owner' then 3
    when 'admin' then 2
    else 1 -- 'member'
  end;

  -- First, try JWT authentication via auth.uid()
  if auth.uid() is not null then
    -- Aliased because the parameter is also called `role`: a bare `role` here
    -- would resolve to it, and every caller would come back an owner.
    --
    -- No invitation clause: an agents row is a member, full stop. It used to
    -- also have to exclude rows whose invitation was still pending, and every
    -- helper that forgot to was a hole. Invitations are their own table now.
    return query select a.organization_id from public.agents a
    where
      a.user_id = auth.uid()
    -- A deleted agent is a former member: this is what makes marking the row
    -- revoke access rather than merely rename it.
    and a.deleted_at is null
    and (
      case a.role
        when 'owner' then 3
        when 'admin' then 2
        else 1 -- 'member'
      end
    ) >= req_level;

    -- Authenticated but lacking the requested role: return the empty set so RLS
    -- subqueries can fall through to other OR-combined policies (e.g. a member
    -- editing themselves while an owner-only policy is also evaluated).
    -- Raising here would short-circuit the whole RLS evaluation.
    -- raise exception using
    --   errcode = '42501',
    --   message = format('insufficient permissions, %s role required', role::text);
    return;
  end if;

  -- Fallback to API key authentication
  api_key := current_setting('request.headers', true)::json->>'api-key';

  if api_key is not null then
    -- F14: the secret is compared as sha256 (api_keys_key_hash_key serves
    -- the probe). A row that still carries a plain key and no hash is only
    -- honoured until the cutover; an expired key is never honoured.
    select a.organization_id, a.id into org_id, key_id
    from public.api_keys a
    where (
      a.key_hash = extensions.digest(api_key, 'sha256')
      or (
        a.key_hash is null
        and a.key = api_key
        and now() < public.api_key_plaintext_cutover()
      )
    )
    and (a.expires_at is null or a.expires_at > now())
    and (
      case (a.role::text)
        when 'owner' then 3
        when 'admin' then 2
        else 1 -- 'member'
      end
    ) >= req_level;

    if org_id is not null then
      -- Usage stamp, at most once a minute, and only where a write is
      -- possible: PostgREST serves GET inside a READ ONLY transaction.
      if current_setting('transaction_read_only', true) = 'off' then
        update public.api_keys a
        set last_used_at = now()
        where a.id = key_id
          and (a.last_used_at is null or a.last_used_at < now() - interval '1 minute');
      end if;

      return next org_id;
    end if;
    -- Same reasoning as the JWT branch: invalid key or insufficient role returns
    -- the empty set, not a raise. Validate api-key existence at the request edge
    -- (e.g. a pre-request hook) if you want loud failure for missing/invalid keys.
    -- raise exception using
    --   errcode = '42501',
    --   message = format('invalid api key or insufficient permissions, %s role required', role::text);
    return;
  end if;

  raise exception using
    errcode = '42501',
    message = 'authentication required',
    hint = 'use api-key header or jwt authentication';
end;
$function$
;


  create policy "owners can read their orgs api keys"
  on "public"."api_keys"
  as permissive
  for select
  to authenticated, anon
using (((key_hash = ( SELECT extensions.digest(((current_setting('request.headers'::text, true))::json ->> 'api-key'::text), 'sha256'::text) AS digest)) OR (organization_id IN ( SELECT public.get_authorized_orgs('owner'::public.role) AS get_authorized_orgs))));


CREATE TRIGGER a_hash_api_key BEFORE INSERT OR UPDATE OF key ON public.api_keys FOR EACH ROW WHEN ((new.key IS NOT NULL)) EXECUTE FUNCTION public.hash_api_key();



-- Hand-written backfill (DML): re-state every plain key so a_hash_api_key
-- stores sha256 + prefix and clears the plaintext. After this no row holds
-- a secret; the plaintext double-read in get_authorized_orgs only matters
-- for a row this statement never saw, and ends at api_key_plaintext_cutover().
update public.api_keys set key = key where key is not null;
