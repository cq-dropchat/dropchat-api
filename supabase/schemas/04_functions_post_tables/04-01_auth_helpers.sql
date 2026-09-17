create function public.get_authorized_orgs(role public.role default 'member') returns setof uuid
language plpgsql
security definer
set search_path to ''
as $$
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
$$;

-- WITH CHECK sees the proposed row and nothing else, so "this column may not
-- change" cannot be written as a policy expression — it needs the stored row
-- to compare against. That is all these two do: re-read the row by id under
-- SECURITY DEFINER (also avoiding RLS recursion on agents) and confirm the
-- columns the caller is not allowed to move still hold their old values.
--
-- Identity: which organization the row belongs to, and which person it names.
-- Neither is editable by anyone through the API — an agent that could change
-- organization_id would be a tenant escape, and one that could change user_id
-- would be an impersonation. (`user_id` doubles as the AI test, so pinning
-- it also pins that.)
create function public.agent_identity_unchanged(
  p_id uuid,
  p_user_id uuid,
  p_organization_id uuid
) returns boolean
language plpgsql
security definer -- avoid RLS infinite recursion
set search_path to ''
as $$
begin
  return exists (
    select 1 from public.agents
    where id = p_id
      and user_id is not distinct from p_user_id
      and organization_id = p_organization_id
  );
end;
$$;

-- Identity plus role, for the two callers who may edit an agent but not
-- promote anyone: a member editing themselves, and an admin editing a
-- colleague. Granting a role is an owner's privilege, so owners get the
-- function above instead.
create function public.agent_identity_and_role_unchanged(
  p_id uuid,
  p_user_id uuid,
  p_organization_id uuid,
  p_role public.role
) returns boolean
language plpgsql
security definer -- avoid RLS infinite recursion
set search_path to ''
as $$
begin
  return exists (
    select 1 from public.agents
    where id = p_id
      and user_id is not distinct from p_user_id
      and organization_id = p_organization_id
      and role = p_role
  );
end;
$$;

-- The caller's own agent rows, across every org they belong to. A user has at
-- most one agent per organization (agents_organization_id_user_id_key), so
-- this is "which agent am I here". Set-returning for the same reason as the
-- visibility helpers: `agent_id in (select …)` is an InitPlan evaluated once.
--
-- Empty for API keys — they authenticate without auth.uid() and are nobody in
-- particular, so no policy branch that means "my own row" can ever match one.
create function public.get_own_agents() returns setof uuid
language sql
stable
security definer
set search_path to ''
as $$
  select a.id from public.agents a
  where a.user_id = auth.uid() and a.deleted_at is null;
$$;

-- F14. Mints an API key and returns the plain secret ONCE. The row keeps
-- only sha256 + prefix (hash_api_key), so nothing can show it again.
-- Owners only — the same line api_keys' insert policy draws — checked here
-- because the insert below runs as the definer.
create function public.create_api_key(
  p_organization_id uuid,
  p_name text,
  p_role public.role default 'member',
  p_expires_at timestamp with time zone default null
) returns table (id uuid, key text, key_prefix text)
language plpgsql
security definer
set search_path to ''
as $$
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
$$;
