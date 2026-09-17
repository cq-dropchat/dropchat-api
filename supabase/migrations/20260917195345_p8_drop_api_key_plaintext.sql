-- F14 (P8) — the plaintext key slot and the cutover that honoured it.
--
-- F14 hashed the keys but kept a write-only `key` column so a client could
-- still hand the database a plain one, and get_authorized_orgs accepted a row
-- that carried a plain key and no hash until 2026-11-01. Both go here: keys
-- are minted by create_api_key alone, which hashes in place and returns the
-- secret once.
--
-- Hand-ordered: `db diff` put the column drop first, which leaves the old
-- function bodies referring to a column that is gone (plpgsql resolves names
-- at run time, so nothing would complain until something called them). The
-- readers are replaced first, then what they stopped using is removed.

set check_function_bodies = off;

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

  -- Hashed here rather than by a trigger on a write-only column (P8): this
  -- function is the only way a key is created, so the plaintext never leaves
  -- this block except in the reply.
  insert into public.api_keys (
    organization_id, name, role, key_hash, key_prefix, expires_at
  )
  values (
    p_organization_id, p_name, p_role,
    extensions.digest(_key, 'sha256'), left(_key, 8), p_expires_at
  )
  returning public.api_keys.id into _id;

  return query select _id, _key, left(_key, 8);
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
    -- F18: an organization whose deletion was requested is gone for every
    -- reader at once; the sweep removes its rows later, in batches.
    and not exists (
      select 1 from public.organizations o
      where o.id = a.organization_id and o.deletion_requested_at is not null
    )
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
    -- the probe) and nothing else — P8 removed the plaintext fallback the
    -- cutover allowed. A row without a hash matches nothing, and an expired
    -- key is never honoured.
    select a.organization_id, a.id into org_id, key_id
    from public.api_keys a
    where a.key_hash = extensions.digest(api_key, 'sha256')
    and (a.expires_at is null or a.expires_at > now())
    and not exists (
      select 1 from public.organizations o
      where o.id = a.organization_id and o.deletion_requested_at is not null
    )
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

drop trigger if exists "a_hash_api_key" on "public"."api_keys";

drop function if exists "public"."api_key_plaintext_cutover"();

drop function if exists "public"."hash_api_key"();

alter table "public"."api_keys" drop column "key";
