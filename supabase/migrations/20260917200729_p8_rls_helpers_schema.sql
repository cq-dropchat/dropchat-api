-- P8 — the RLS helpers move out of `public`.
--
-- They are SECURITY DEFINER functions that answer about the caller, and living
-- in `public` made every one of them a PostgREST RPC endpoint for anon and
-- authenticated (Postgres grants EXECUTE on a new function to PUBLIC). Nothing
-- outside SQL has ever called one. `rls` is not in config.toml's exposed
-- schemas, so PostgREST does not serve it.
--
-- Shape of this migration, as `db diff` wrote it and in one transaction: drop
-- the 47 policies that referenced the old functions, drop the functions,
-- create them in `rls`, then create the policies again with the new
-- qualification. Their text is otherwise unchanged.
--
-- Hand-added: the schema grant. A policy runs as the invoking role, so anon
-- and authenticated need USAGE here or every one of them fails closed; `db
-- diff` does not emit schema privileges.
create schema if not exists "rls";

grant usage on schema rls to anon, authenticated, service_role;

drop policy "owners can read their accounts" on "billing"."accounts";

drop policy "owners can read their org invoices" on "billing"."invoices";

drop policy "owners can read their org invoice items" on "billing"."invoices_items";

drop policy "members can read their org ledger" on "billing"."ledger";

drop policy "owners can read their org payments" on "billing"."payments";

drop policy "members can read their org subscription" on "billing"."subscriptions";

drop policy "members can read their org usage" on "billing"."usage";

drop policy "admins can create their orgs ai agents" on "public"."agents";

drop policy "admins can delete their orgs ai agents" on "public"."agents";

drop policy "admins can update their orgs agents" on "public"."agents";

drop policy "members can read their orgs agents" on "public"."agents";

drop policy "members can update themselves" on "public"."agents";

drop policy "owners can delete their orgs agents" on "public"."agents";

drop policy "owners can update their orgs agents" on "public"."agents";

drop policy "owners can create their orgs api keys" on "public"."api_keys";

drop policy "owners can delete their orgs api keys" on "public"."api_keys";

drop policy "owners can read their orgs api keys" on "public"."api_keys";

drop policy "members can delete non-synced contacts addresses" on "public"."contacts_addresses";

drop policy "members can insert contacts addresses" on "public"."contacts_addresses";

drop policy "members can read visible contacts addresses" on "public"."contacts_addresses";

drop policy "members can update non-synced contacts addresses" on "public"."contacts_addresses";

drop policy "members can create their orgs local conversations" on "public"."conversations";

drop policy "members can delete their orgs local conversations" on "public"."conversations";

drop policy "members can read their orgs conversations" on "public"."conversations";

drop policy "members can update their orgs local conversations" on "public"."conversations";

drop policy "members can create local membership rows" on "public"."conversations_agents";

drop policy "members can delete local membership rows" on "public"."conversations_agents";

drop policy "members can update their own local membership rows" on "public"."conversations_agents";

drop policy "members can read their orgs invitations" on "public"."invitations";

drop policy "owners can manage their orgs invitations" on "public"."invitations";

drop policy "members can read their orgs logs" on "public"."logs";

drop policy "members can create their orgs messages" on "public"."messages";

drop policy "members can read their orgs messages" on "public"."messages";

drop policy "admins can create onboarding tokens" on "public"."onboarding_tokens";

drop policy "admins can delete onboarding tokens" on "public"."onboarding_tokens";

drop policy "admins can read their org onboarding tokens" on "public"."onboarding_tokens";

drop policy "owners can read their org exports" on "public"."organization_exports";

drop policy "admins can update their orgs" on "public"."organizations";

drop policy "members can read their orgs" on "public"."organizations";

drop policy "owners can delete their orgs" on "public"."organizations";

drop policy "members can read their orgs addresses" on "public"."organizations_addresses";

drop policy "owners can read their orgs webhook deliveries" on "public"."webhook_deliveries";

drop policy "owners can manage their orgs webhooks" on "public"."webhooks";

-- Hand-moved up from the end of the file: `db diff` emitted these four
-- drops after the function drops, and a policy that references a function
-- depends on it — the drop failed with 2BP01. They are re-created below
-- with the rest.
drop policy "members join their realtime channels" on "realtime"."messages";
drop policy "members can download their orgs media" on "storage"."objects";
drop policy "members can upload their orgs media" on "storage"."objects";
drop policy "owners can download their org exports" on "storage"."objects";

drop function if exists "public"."agent_identity_and_role_unchanged"(p_id uuid, p_user_id uuid, p_organization_id uuid, p_role public.role);

drop function if exists "public"."agent_identity_unchanged"(p_id uuid, p_user_id uuid, p_organization_id uuid);

drop function if exists "public"."get_authorized_orgs"(role public.role);

drop function if exists "public"."get_own_agents"();

drop function if exists "public"."get_participant_conversations"();

drop function if exists "public"."get_restricted_conversations"();

drop function if exists "public"."get_visible_addresses"();

drop function if exists "public"."is_conversation_visible"(conv_id uuid, conv_org uuid, conv_addr text, conv_service public.service);

drop function if exists "public"."is_media_visible"(object_name text);

drop function if exists "public"."is_restricted_conversation"(conv_service public.service, conv_type text, conv_extra jsonb);

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION rls.agent_identity_and_role_unchanged(p_id uuid, p_user_id uuid, p_organization_id uuid, p_role public.role)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  return exists (
    select 1 from public.agents
    where id = p_id
      and user_id is not distinct from p_user_id
      and organization_id = p_organization_id
      and role = p_role
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION rls.agent_identity_unchanged(p_id uuid, p_user_id uuid, p_organization_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  return exists (
    select 1 from public.agents
    where id = p_id
      and user_id is not distinct from p_user_id
      and organization_id = p_organization_id
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION rls.get_authorized_orgs(role public.role DEFAULT 'member'::public.role)
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

CREATE OR REPLACE FUNCTION rls.get_own_agents()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select a.id from public.agents a
  where a.user_id = auth.uid() and a.deleted_at is null;
$function$
;

CREATE OR REPLACE FUNCTION rls.get_participant_conversations()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select ca.conversation_id
  from public.conversations_agents ca
  join public.agents a on a.id = ca.agent_id
  where a.user_id = auth.uid() and a.deleted_at is null;
$function$
;

CREATE OR REPLACE FUNCTION rls.get_restricted_conversations()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select c.id
  from public.conversations c
  where c.organization_id in (select rls.get_authorized_orgs('member'))
    and rls.is_restricted_conversation(c.service, c.type, c.extra);
$function$
;

CREATE OR REPLACE FUNCTION rls.get_visible_addresses()
 RETURNS TABLE(organization_id uuid, service public.service, address text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  -- Shared inboxes: any ownerless account in an org the caller belongs to. No
  -- auth.uid() in the ownerless test itself, so this is the only rule an API
  -- key can satisfy.
  --
  -- The org filter is redundant with every policy that calls this — each one
  -- already ANDs `organization_id in get_authorized_orgs(…)`. It stays because
  -- it is what makes the function safe on its own: SECURITY DEFINER, so RLS
  -- does not apply inside it, and without the filter it answers with every
  -- shared inbox in the DATABASE — other tenants' org ids and account
  -- addresses, WhatsApp business numbers among them. Until P8 moved it to the
  -- `rls` schema that was not hypothetical: PostgREST published it at
  -- /rpc/get_visible_addresses for anyone with the anon key.
  select oa.organization_id, oa.service, oa.address
  from public.organizations_addresses oa
  where oa.agent_id is null
    and oa.organization_id in (select rls.get_authorized_orgs('member'))
  union
  -- Personal accounts owned by the caller (their Slack identity, a personal
  -- WhatsApp/mailbox).
  select oa.organization_id, oa.service, oa.address
  from public.organizations_addresses oa
  join public.agents a on a.id = oa.agent_id
  where a.user_id = auth.uid() and a.deleted_at is null;
$function$
;

CREATE OR REPLACE FUNCTION rls.is_conversation_visible(conv_id uuid, conv_org uuid, conv_addr text, conv_service public.service)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select
    (
      (conv_org, conv_service, conv_addr) in (
        select v.organization_id, v.service, v.address
        from rls.get_visible_addresses() v
      )
      and conv_id not in (select rls.get_restricted_conversations())
    )
    or conv_id in (select rls.get_participant_conversations());
$function$
;

CREATE OR REPLACE FUNCTION rls.is_media_visible(object_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with refs as (
    select m.conversation_id, m.organization_id, m.service, m.organization_address
    from public.messages m
    where m.content->'file'->>'uri' = 'internal://media/' || object_name
  )
  select
    not exists (select 1 from refs)
    or exists (
      select 1 from refs r
      where rls.is_conversation_visible(
        r.conversation_id, r.organization_id, r.organization_address, r.service
      )
    );
$function$
;

CREATE OR REPLACE FUNCTION rls.is_restricted_conversation(conv_service public.service, conv_type text, conv_extra jsonb)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select
    -- Slack: shared iff the bot is in it.
    (
      conv_service = 'slack'::public.service
      and not coalesce((conv_extra->>'is_bot_member')::boolean, false)
    )
    -- local: shared iff it is a public channel.
    or (
      conv_service = 'local'::public.service
      and conv_type is distinct from 'channel'
    );
$function$
;

CREATE OR REPLACE FUNCTION public.broadcast_realtime_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _conv public.conversations;
  _notice jsonb;
  _agent uuid;
begin
  if tg_table_name = 'messages' then
    select * into _conv from public.conversations c where c.id = new.conversation_id;
  else
    _conv := new;
  end if;

  if _conv.id is null then
    return null;
  end if;

  _notice := jsonb_build_object(
    'table', tg_table_name,
    'op', tg_op,
    'id', new.id,
    'organization_id', new.organization_id,
    'conversation_id', _conv.id,
    'updated_at', new.updated_at
  );

  if tg_table_name = 'messages' and tg_op = 'UPDATE' then
    _notice := _notice || jsonb_build_object(
      'status_changed',
      (
        select coalesce(jsonb_agg(k order by k), '[]'::jsonb)
        from (
          select n.key as k
          from jsonb_each(coalesce(new.status, '{}'::jsonb)) n
          where n.value is distinct from coalesce(old.status, '{}'::jsonb) -> n.key
          union
          select o.key
          from jsonb_each(coalesce(old.status, '{}'::jsonb)) o
          where not coalesce(new.status, '{}'::jsonb) ? o.key
        ) changed
      )
    );
  end if;

  if not rls.is_restricted_conversation(_conv.service, _conv.type, _conv.extra)
    and exists (
      select 1 from public.organizations_addresses oa
      where oa.organization_id = _conv.organization_id
        and oa.service = _conv.service
        and oa.address = _conv.organization_address
        and oa.agent_id is null
    )
  then
    perform realtime.send(_notice, tg_table_name, 'org:' || _conv.organization_id::text, true);
  else
    for _agent in
      -- The personal account's owner (unless the conversation is restricted)…
      select oa.agent_id
      from public.organizations_addresses oa
      join public.agents a on a.id = oa.agent_id
      where oa.organization_id = _conv.organization_id
        and oa.service = _conv.service
        and oa.address = _conv.organization_address
        and a.user_id is not null
        and a.deleted_at is null
        and not rls.is_restricted_conversation(_conv.service, _conv.type, _conv.extra)
      union
      -- …and the human participants.
      select ca.agent_id
      from public.conversations_agents ca
      join public.agents a on a.id = ca.agent_id
      where ca.conversation_id = _conv.id
        and a.user_id is not null
        and a.deleted_at is null
    loop
      perform realtime.send(_notice, tg_table_name, 'agent:' || _agent::text, true);
    end loop;
  end if;

  perform realtime.send(
    jsonb_build_object('table', tg_table_name, 'op', tg_op, 'record', to_jsonb(new)),
    tg_table_name,
    'conv:' || _conv.id::text,
    true
  );

  return null;
end;
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
  if p_organization_id not in (select rls.get_authorized_orgs('owner')) then
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

CREATE OR REPLACE FUNCTION public.request_organization_export(_organization_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _id uuid;
begin
  if _organization_id is null
    or _organization_id not in (select rls.get_authorized_orgs('owner'))
  then
    raise exception using
      errcode = '42501',
      message = 'only an owner of the organization can export it';
  end if;

  insert into public.organization_exports (organization_id, requested_by)
  values (_organization_id, auth.uid())
  on conflict (organization_id) where status in ('pending', 'processing')
  do nothing
  returning id into _id;

  if _id is null then
    select e.id into _id
    from public.organization_exports e
    where e.organization_id = _organization_id
      and e.status in ('pending', 'processing');
  end if;

  return _id;
end;
$function$
;


  create policy "owners can read their accounts"
  on "billing"."accounts"
  as permissive
  for select
  to authenticated, anon
using ((id IN ( SELECT s.account_id
   FROM billing.subscriptions s
  WHERE ((s.organization_id IN ( SELECT rls.get_authorized_orgs('owner'::public.role) AS get_authorized_orgs)) AND (s.account_id IS NOT NULL)))));



  create policy "owners can read their org invoices"
  on "billing"."invoices"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT rls.get_authorized_orgs('owner'::public.role) AS get_authorized_orgs)));



  create policy "owners can read their org invoice items"
  on "billing"."invoices_items"
  as permissive
  for select
  to authenticated, anon
using ((invoice_id IN ( SELECT i.id
   FROM billing.invoices i
  WHERE (i.organization_id IN ( SELECT rls.get_authorized_orgs('owner'::public.role) AS get_authorized_orgs)))));



  create policy "members can read their org ledger"
  on "billing"."ledger"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT rls.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)));



  create policy "owners can read their org payments"
  on "billing"."payments"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT rls.get_authorized_orgs('owner'::public.role) AS get_authorized_orgs)));



  create policy "members can read their org subscription"
  on "billing"."subscriptions"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT rls.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)));



  create policy "members can read their org usage"
  on "billing"."usage"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT rls.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)));



  create policy "admins can create their orgs ai agents"
  on "public"."agents"
  as permissive
  for insert
  to authenticated, anon
with check (((organization_id IN ( SELECT rls.get_authorized_orgs('admin'::public.role) AS get_authorized_orgs)) AND (user_id IS NULL)));



  create policy "admins can delete their orgs ai agents"
  on "public"."agents"
  as permissive
  for delete
  to authenticated, anon
using (((organization_id IN ( SELECT rls.get_authorized_orgs('admin'::public.role) AS get_authorized_orgs)) AND (user_id IS NULL)));



  create policy "admins can update their orgs agents"
  on "public"."agents"
  as permissive
  for update
  to authenticated, anon
using ((organization_id IN ( SELECT rls.get_authorized_orgs('admin'::public.role) AS get_authorized_orgs)))
with check (((organization_id IN ( SELECT rls.get_authorized_orgs('admin'::public.role) AS get_authorized_orgs)) AND rls.agent_identity_and_role_unchanged(id, user_id, organization_id, role)));



  create policy "members can read their orgs agents"
  on "public"."agents"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT rls.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)));



  create policy "members can update themselves"
  on "public"."agents"
  as permissive
  for update
  to authenticated
using ((user_id = ( SELECT auth.uid() AS uid)))
with check (((user_id = ( SELECT auth.uid() AS uid)) AND rls.agent_identity_and_role_unchanged(id, user_id, organization_id, role)));



  create policy "owners can delete their orgs agents"
  on "public"."agents"
  as permissive
  for delete
  to authenticated, anon
using ((organization_id IN ( SELECT rls.get_authorized_orgs('owner'::public.role) AS get_authorized_orgs)));



  create policy "owners can update their orgs agents"
  on "public"."agents"
  as permissive
  for update
  to authenticated, anon
using ((organization_id IN ( SELECT rls.get_authorized_orgs('owner'::public.role) AS get_authorized_orgs)))
with check (((organization_id IN ( SELECT rls.get_authorized_orgs('owner'::public.role) AS get_authorized_orgs)) AND rls.agent_identity_unchanged(id, user_id, organization_id)));



  create policy "owners can create their orgs api keys"
  on "public"."api_keys"
  as permissive
  for insert
  to authenticated, anon
with check ((organization_id IN ( SELECT rls.get_authorized_orgs('owner'::public.role) AS get_authorized_orgs)));



  create policy "owners can delete their orgs api keys"
  on "public"."api_keys"
  as permissive
  for delete
  to authenticated, anon
using ((organization_id IN ( SELECT rls.get_authorized_orgs('owner'::public.role) AS get_authorized_orgs)));



  create policy "owners can read their orgs api keys"
  on "public"."api_keys"
  as permissive
  for select
  to authenticated, anon
using (((key_hash = ( SELECT extensions.digest(((current_setting('request.headers'::text, true))::json ->> 'api-key'::text), 'sha256'::text) AS digest)) OR (organization_id IN ( SELECT rls.get_authorized_orgs('owner'::public.role) AS get_authorized_orgs))));



  create policy "members can delete non-synced contacts addresses"
  on "public"."contacts_addresses"
  as permissive
  for delete
  to authenticated, anon
using (((organization_id IN ( SELECT rls.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) AND ((organization_id, service, organization_address) IN ( SELECT v.organization_id,
    v.service,
    v.address
   FROM rls.get_visible_addresses() v(organization_id, service, address))) AND (((extra -> 'synced'::text) ->> 'action'::text) IS DISTINCT FROM 'add'::text)));



  create policy "members can insert contacts addresses"
  on "public"."contacts_addresses"
  as permissive
  for insert
  to authenticated, anon
with check (((organization_id IN ( SELECT rls.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) AND ((organization_id, service, organization_address) IN ( SELECT v.organization_id,
    v.service,
    v.address
   FROM rls.get_visible_addresses() v(organization_id, service, address))) AND (((extra -> 'synced'::text) ->> 'action'::text) IS DISTINCT FROM 'add'::text)));



  create policy "members can read visible contacts addresses"
  on "public"."contacts_addresses"
  as permissive
  for select
  to authenticated, anon
using (((organization_id IN ( SELECT rls.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) AND ((organization_id, service, organization_address) IN ( SELECT v.organization_id,
    v.service,
    v.address
   FROM rls.get_visible_addresses() v(organization_id, service, address)))));



  create policy "members can update non-synced contacts addresses"
  on "public"."contacts_addresses"
  as permissive
  for update
  to authenticated, anon
using (((organization_id IN ( SELECT rls.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) AND ((organization_id, service, organization_address) IN ( SELECT v.organization_id,
    v.service,
    v.address
   FROM rls.get_visible_addresses() v(organization_id, service, address))) AND (((extra -> 'synced'::text) ->> 'action'::text) IS DISTINCT FROM 'add'::text)))
with check (((organization_id IN ( SELECT rls.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) AND ((organization_id, service, organization_address) IN ( SELECT v.organization_id,
    v.service,
    v.address
   FROM rls.get_visible_addresses() v(organization_id, service, address))) AND (((extra -> 'synced'::text) ->> 'action'::text) IS DISTINCT FROM 'add'::text)));



  create policy "members can create their orgs local conversations"
  on "public"."conversations"
  as permissive
  for insert
  to authenticated, anon
with check (((organization_id IN ( SELECT rls.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) AND (service = 'local'::public.service)));



  create policy "members can delete their orgs local conversations"
  on "public"."conversations"
  as permissive
  for delete
  to authenticated, anon
using (((organization_id IN ( SELECT rls.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) AND (service = 'local'::public.service) AND ((((organization_id, service, organization_address) IN ( SELECT v.organization_id,
    v.service,
    v.address
   FROM rls.get_visible_addresses() v(organization_id, service, address))) AND (NOT (id IN ( SELECT rls.get_restricted_conversations() AS get_restricted_conversations)))) OR (id IN ( SELECT rls.get_participant_conversations() AS get_participant_conversations)))));



  create policy "members can read their orgs conversations"
  on "public"."conversations"
  as permissive
  for select
  to authenticated, anon
using (((organization_id IN ( SELECT rls.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) AND ((((organization_id, service, organization_address) IN ( SELECT v.organization_id,
    v.service,
    v.address
   FROM rls.get_visible_addresses() v(organization_id, service, address))) AND (NOT (id IN ( SELECT rls.get_restricted_conversations() AS get_restricted_conversations)))) OR (id IN ( SELECT rls.get_participant_conversations() AS get_participant_conversations)))));



  create policy "members can update their orgs local conversations"
  on "public"."conversations"
  as permissive
  for update
  to authenticated, anon
using (((organization_id IN ( SELECT rls.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) AND (service = 'local'::public.service) AND ((((organization_id, service, organization_address) IN ( SELECT v.organization_id,
    v.service,
    v.address
   FROM rls.get_visible_addresses() v(organization_id, service, address))) AND (NOT (id IN ( SELECT rls.get_restricted_conversations() AS get_restricted_conversations)))) OR (id IN ( SELECT rls.get_participant_conversations() AS get_participant_conversations)))))
with check (((organization_id IN ( SELECT rls.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) AND (service = 'local'::public.service)));



  create policy "members can create local membership rows"
  on "public"."conversations_agents"
  as permissive
  for insert
  to authenticated
with check ((EXISTS ( SELECT 1
   FROM public.conversations c
  WHERE ((c.id = conversations_agents.conversation_id) AND (c.service = 'local'::public.service) AND (((c.type = 'group'::text) AND (conversations_agents.conversation_id IN ( SELECT rls.get_participant_conversations() AS get_participant_conversations))) OR ((c.type = 'channel'::text) AND (conversations_agents.agent_id IN ( SELECT rls.get_own_agents() AS get_own_agents))))))));



  create policy "members can delete local membership rows"
  on "public"."conversations_agents"
  as permissive
  for delete
  to authenticated
using ((EXISTS ( SELECT 1
   FROM public.conversations c
  WHERE ((c.id = conversations_agents.conversation_id) AND (c.service = 'local'::public.service) AND (((c.type = 'group'::text) AND (conversations_agents.conversation_id IN ( SELECT rls.get_participant_conversations() AS get_participant_conversations))) OR ((c.type = 'channel'::text) AND (conversations_agents.agent_id IN ( SELECT rls.get_own_agents() AS get_own_agents))))))));



  create policy "members can update their own local membership rows"
  on "public"."conversations_agents"
  as permissive
  for update
  to authenticated
using (((agent_id IN ( SELECT rls.get_own_agents() AS get_own_agents)) AND (EXISTS ( SELECT 1
   FROM public.conversations c
  WHERE ((c.id = conversations_agents.conversation_id) AND (c.service = 'local'::public.service))))))
with check (((agent_id IN ( SELECT rls.get_own_agents() AS get_own_agents)) AND (EXISTS ( SELECT 1
   FROM public.conversations c
  WHERE ((c.id = conversations_agents.conversation_id) AND (c.service = 'local'::public.service))))));



  create policy "members can read their orgs invitations"
  on "public"."invitations"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT rls.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)));



  create policy "owners can manage their orgs invitations"
  on "public"."invitations"
  as permissive
  for all
  to authenticated, anon
using ((organization_id IN ( SELECT rls.get_authorized_orgs('owner'::public.role) AS get_authorized_orgs)))
with check ((organization_id IN ( SELECT rls.get_authorized_orgs('owner'::public.role) AS get_authorized_orgs)));



  create policy "members can read their orgs logs"
  on "public"."logs"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT rls.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)));



  create policy "members can create their orgs messages"
  on "public"."messages"
  as permissive
  for insert
  to authenticated, anon
with check (((organization_id IN ( SELECT rls.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) AND ((((organization_id, service, organization_address) IN ( SELECT v.organization_id,
    v.service,
    v.address
   FROM rls.get_visible_addresses() v(organization_id, service, address))) AND (NOT (conversation_id IN ( SELECT rls.get_restricted_conversations() AS get_restricted_conversations)))) OR (conversation_id IN ( SELECT rls.get_participant_conversations() AS get_participant_conversations)))));



  create policy "members can read their orgs messages"
  on "public"."messages"
  as permissive
  for select
  to authenticated, anon
using (((organization_id IN ( SELECT rls.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) AND ((((organization_id, service, organization_address) IN ( SELECT v.organization_id,
    v.service,
    v.address
   FROM rls.get_visible_addresses() v(organization_id, service, address))) AND (NOT (conversation_id IN ( SELECT rls.get_restricted_conversations() AS get_restricted_conversations)))) OR (conversation_id IN ( SELECT rls.get_participant_conversations() AS get_participant_conversations)))));



  create policy "admins can create onboarding tokens"
  on "public"."onboarding_tokens"
  as permissive
  for insert
  to authenticated, anon
with check ((organization_id IN ( SELECT rls.get_authorized_orgs('admin'::public.role) AS get_authorized_orgs)));



  create policy "admins can delete onboarding tokens"
  on "public"."onboarding_tokens"
  as permissive
  for delete
  to authenticated, anon
using ((organization_id IN ( SELECT rls.get_authorized_orgs('admin'::public.role) AS get_authorized_orgs)));



  create policy "admins can read their org onboarding tokens"
  on "public"."onboarding_tokens"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT rls.get_authorized_orgs('admin'::public.role) AS get_authorized_orgs)));



  create policy "owners can read their org exports"
  on "public"."organization_exports"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT rls.get_authorized_orgs('owner'::public.role) AS get_authorized_orgs)));



  create policy "admins can update their orgs"
  on "public"."organizations"
  as permissive
  for update
  to authenticated, anon
using ((id IN ( SELECT rls.get_authorized_orgs('admin'::public.role) AS get_authorized_orgs)))
with check ((id IN ( SELECT rls.get_authorized_orgs('admin'::public.role) AS get_authorized_orgs)));



  create policy "members can read their orgs"
  on "public"."organizations"
  as permissive
  for select
  to authenticated, anon
using ((id IN ( SELECT rls.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)));



  create policy "owners can delete their orgs"
  on "public"."organizations"
  as permissive
  for delete
  to authenticated, anon
using ((id IN ( SELECT rls.get_authorized_orgs('owner'::public.role) AS get_authorized_orgs)));



  create policy "members can read their orgs addresses"
  on "public"."organizations_addresses"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT rls.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)));



  create policy "owners can read their orgs webhook deliveries"
  on "public"."webhook_deliveries"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT rls.get_authorized_orgs('owner'::public.role) AS get_authorized_orgs)));



  create policy "owners can manage their orgs webhooks"
  on "public"."webhooks"
  as permissive
  for all
  to authenticated, anon
using ((organization_id IN ( SELECT rls.get_authorized_orgs('owner'::public.role) AS get_authorized_orgs)))
with check ((organization_id IN ( SELECT rls.get_authorized_orgs('owner'::public.role) AS get_authorized_orgs)));




  create policy "members join their realtime channels"
  on "realtime"."messages"
  as permissive
  for select
  to authenticated, anon
using (((extension = 'broadcast'::text) AND ((public.realtime_topic_uuid('org'::text) IN ( SELECT rls.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) OR (public.realtime_topic_uuid('agent'::text) IN ( SELECT a.id
   FROM public.agents a
  WHERE ((a.user_id = auth.uid()) AND (a.deleted_at IS NULL)))) OR (EXISTS ( SELECT 1
   FROM public.conversations c
  WHERE (c.id = public.realtime_topic_uuid('conv'::text)))))));






  create policy "members can download their orgs media"
  on "storage"."objects"
  as permissive
  for select
  to authenticated, anon
using (((bucket_id = 'media'::text) AND ((storage.foldername(name))[2] IN ( SELECT (rls.get_authorized_orgs('member'::public.role))::text AS get_authorized_orgs)) AND rls.is_media_visible(name)));



  create policy "members can upload their orgs media"
  on "storage"."objects"
  as permissive
  for insert
  to authenticated, anon
with check (((bucket_id = 'media'::text) AND ((storage.foldername(name))[2] IN ( SELECT (rls.get_authorized_orgs('member'::public.role))::text AS get_authorized_orgs))));



  create policy "owners can download their org exports"
  on "storage"."objects"
  as permissive
  for select
  to authenticated, anon
using (((bucket_id = 'exports'::text) AND ((storage.foldername(name))[2] IN ( SELECT (rls.get_authorized_orgs('owner'::public.role))::text AS get_authorized_orgs))));



