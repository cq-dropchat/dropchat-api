-- T6. Installing a template, resolving the two layers, updating, unlinking.
--
-- An installed agent is a POINTER plus a layer: `template_id` +
-- `template_version` say what it is based on, and `agents.extra` is what this
-- organization changed. Nothing of the template is copied into the agent, and
-- that is the whole design — taking a new version (D7) is one column, not a
-- re-install that would silently discard the organization's edits.
--
-- The resolution below exists TWICE on purpose, here and in
-- `_shared/agent_templates.ts`. TypeScript answers it on every message (a
-- round trip per invocation is not free) and SQL answers it when unlinking
-- freezes the result. `_traces/agent_config_parity.test.ts` runs both over the
-- same cases, the same way H4's schedule is checked.

-- A tool's identity: its type and the name it is filed under.
--
-- The same key `extract_secrets` uses to store a tool's credentials, and that
-- is not a coincidence to be undone later: it means renaming a tool loses its
-- template connection in exactly the same way it already loses its secrets,
-- instead of in some second, surprising way.
create function public.agent_tool_key(_tool jsonb) returns text
language sql
immutable
set search_path to ''
as $$
  select coalesce(_tool ->> 'type', '?') || ':' ||
         coalesce(_tool ->> 'label', _tool ->> 'name', '');
$$;

revoke execute on function public.agent_tool_key(jsonb)
from public, anon, authenticated, service_role;

-- Whether a tool can actually be called.
--
-- D13: a published version declares its tools WITHOUT their `config`, because
-- a config is the source organization's host, user, database and url. So a
-- freshly installed template carries tools that have nowhere to connect, and
-- handing one to the model produces a tool call that fails in front of a
-- customer. Until the organization fills it in, the tool is not offered.
create function public.agent_tool_ready(_tool jsonb) returns boolean
language sql
immutable
set search_path to ''
as $$
  select case
    when _tool ->> 'type' in ('mcp', 'sql', 'http')
      then jsonb_typeof(_tool -> 'config') = 'object'
        and _tool -> 'config' <> '{}'::jsonb
    else true
  end;
$$;

revoke execute on function public.agent_tool_ready(jsonb)
from public, anon, authenticated, service_role;

-- The effective configuration of an agent: the version's config underneath,
-- the organization's `extra` on top.
--
-- Why this is not `_config || _extra`:
--
--   1. TOOLS ARE A LIST, and `extra` is written as a JSON merge patch, where
--      an array is replaced WHOLE (§3.6). A layer that had to restate every
--      tool in order to connect one would also silently drop any tool a new
--      version added. They are merged by identity instead.
--   2. A MASK IS NOT A VALUE. `agent_template_config` keeps the source
--      agent's `api_key` as '********' to say "this template expects one".
--      T4 assumed install would write it through `extract_secrets`, which
--      drops a mask with nothing behind it — but a layered install never
--      writes the template's config anywhere, so that never happens. The mask
--      is dropped here, or it reaches the provider as the key.
--   3. GUARDRAILS ARE THE TEMPLATE'S. They are the one block the installing
--      organization cannot edit: slot 4 of the system prompt exists so a
--      template can state what its agent must not do.
--
-- With no template (`_config` null) this is the identity function on `_extra`,
-- and it has to be: every agent in the product is that case today.
-- SECURITY DEFINER for one reason and no other: it calls the two helpers
-- above, which are private, and `unlink_agent_template` below is invoker. It
-- reads nothing and writes nothing — both layers arrive as arguments — so
-- definer buys no access here, it only lets the function use its own parts.
create function public.resolve_agent_config(_config jsonb, _extra jsonb)
returns jsonb
language plpgsql
immutable
security definer
set search_path to ''
as $$
declare
  _base jsonb := coalesce(_config, '{}'::jsonb);
  _over jsonb := coalesce(_extra, '{}'::jsonb);
  _resolved jsonb;
  _tools jsonb := '[]'::jsonb;
  _tool jsonb;
  _override jsonb;
  _merged jsonb;
begin
  select coalesce(jsonb_object_agg(f.key, f.value), '{}'::jsonb)
  into _base
  from jsonb_each(_base) as f(key, value)
  where f.value <> '"********"'::jsonb;

  _resolved := (_base - 'tools') || (_over - 'tools');

  if _base ? 'guardrails' then
    _resolved := jsonb_set(_resolved, '{guardrails}', _base -> 'guardrails');
  end if;

  -- The template's tools, each connected by the layer if the layer names it.
  for _tool in
    select value from jsonb_array_elements(
      coalesce(_base -> 'tools', '[]'::jsonb)
    )
  loop
    select value into _override
    from jsonb_array_elements(coalesce(_over -> 'tools', '[]'::jsonb))
    where public.agent_tool_key(value) = public.agent_tool_key(_tool)
    limit 1;

    if _override is null then
      _merged := _tool;
    else
      _merged := _tool || _override;

      if (_tool ? 'config') or (_override ? 'config') then
        _merged := jsonb_set(
          _merged,
          '{config}',
          coalesce(_tool -> 'config', '{}'::jsonb) ||
            coalesce(_override -> 'config', '{}'::jsonb)
        );
      end if;
    end if;

    if public.agent_tool_ready(_merged) then
      _tools := _tools || jsonb_build_array(_merged);
    end if;

    _override := null;
  end loop;

  -- And the organization's own, which the template knows nothing about. These
  -- are NOT filtered by readiness: they are exactly what an agent without a
  -- template carries today, and that behaviour does not change here.
  for _tool in
    select value from jsonb_array_elements(
      coalesce(_over -> 'tools', '[]'::jsonb)
    )
  loop
    if not exists (
      select 1
      from jsonb_array_elements(coalesce(_base -> 'tools', '[]'::jsonb)) as b(value)
      where public.agent_tool_key(b.value) = public.agent_tool_key(_tool)
    ) then
      _tools := _tools || jsonb_build_array(_tool);
    end if;
  end loop;

  if (_base ? 'tools') or (_over ? 'tools') then
    _resolved := jsonb_set(_resolved, '{tools}', _tools);
  end if;

  return _resolved;
end;
$$;

revoke execute on function public.resolve_agent_config(jsonb, jsonb)
from public;

-- Callable, unlike its helpers: unlinking runs as the person doing it, and T7
-- will want to show what a template resolves to before anybody installs it.
grant execute on function public.resolve_agent_config(jsonb, jsonb)
to authenticated, anon, service_role;

-- Install: create an agent that points at a version.
--
-- SECURITY INVOKER, deliberately. Creating an AI agent is already an admin's
-- act («admins can create their orgs ai agents»), so the INSERT below is
-- refused for anybody else by the policy that already exists — no second
-- authority to keep in step with the first.
--
-- B4: it is born in `draft`, which does not answer (H1). A template that
-- started talking to customers the moment it was installed would be a
-- configuration nobody had read yet.
create function public.install_agent_template(
  _organization_id uuid,
  _template_id uuid,
  _version integer default null,
  _name text default null
) returns public.agents
language plpgsql
set search_path to ''
as $$
declare
  _template public.agent_templates;
  _row public.agent_template_versions;
  _agent public.agents;
begin
  select * into _template
  from public.agent_templates where id = _template_id;

  if not found then
    raise exception 'no such template: %', _template_id;
  end if;

  if _template.archived_at is not null then
    raise exception 'template % is archived', _template.slug;
  end if;

  if _version is null then
    select * into _row from public.agent_template_versions
    where template_id = _template_id and retired_at is null
    order by version desc limit 1;
  else
    select * into _row from public.agent_template_versions
    where template_id = _template_id and version = _version;
  end if;

  if not found then
    raise exception 'template % has no installable version', _template.slug;
  end if;

  if _row.retired_at is not null then
    raise exception
      'version % of % was retired', _row.version, _template.slug;
  end if;

  insert into public.agents
    (organization_id, user_id, name, extra, template_id, template_version)
  values (
    _organization_id,
    null,
    coalesce(_name, _template.name),
    '{"mode": "draft"}'::jsonb,
    _template_id,
    _row.version
  )
  returning * into _agent;

  return _agent;
end;
$$;

revoke execute on function
  public.install_agent_template(uuid, uuid, integer, text)
from public, service_role;

grant execute on function
  public.install_agent_template(uuid, uuid, integer, text)
to authenticated, anon;

-- Take a version. D7: opt-in, so this is a call somebody makes — or, for an
-- agent with `template_auto_update`, one that publishing makes for them.
create function public.update_agent_template_version(
  _agent_id uuid,
  _version integer default null
) returns public.agents
language plpgsql
set search_path to ''
as $$
declare
  _agent public.agents;
  _row public.agent_template_versions;
begin
  select * into _agent from public.agents where id = _agent_id;

  if not found or _agent.template_id is null then
    raise exception 'agent % is not based on a template', _agent_id;
  end if;

  if _version is null then
    select * into _row from public.agent_template_versions
    where template_id = _agent.template_id and retired_at is null
    order by version desc limit 1;
  else
    select * into _row from public.agent_template_versions
    where template_id = _agent.template_id and version = _version;
  end if;

  if not found then
    raise exception 'no version to move to';
  end if;

  update public.agents
  set template_version = _row.version
  where id = _agent_id
  returning * into _agent;

  -- The UPDATE went through «admins can update their orgs agents» or it
  -- matched no row at all; a policy that refuses simply touches nothing.
  if not found then
    raise exception using errcode = '42501', message = 'not allowed';
  end if;

  return _agent;
end;
$$;

revoke execute on function public.update_agent_template_version(uuid, integer)
from public, service_role;

grant execute on function public.update_agent_template_version(uuid, integer)
to authenticated, anon;

-- Unlink: stop pointing, and keep what you had.
--
-- The resolved configuration is written into `extra`, so the agent goes on
-- answering exactly as it did the moment before — including the tools the
-- organization connected. What it loses is future versions.
--
-- `extra` is merge-patched on update (set_extra), and that is fine here: the
-- resolved object contains every key the layer had, and a merge patch replaces
-- the tools array whole. The stored result is the resolved configuration.
create function public.unlink_agent_template(_agent_id uuid)
returns public.agents
language plpgsql
set search_path to ''
as $$
declare
  _agent public.agents;
  _config jsonb;
begin
  select * into _agent from public.agents where id = _agent_id;

  if not found or _agent.template_id is null then
    raise exception 'agent % is not based on a template', _agent_id;
  end if;

  select config into _config
  from public.agent_template_versions
  where template_id = _agent.template_id
    and version = _agent.template_version;

  update public.agents
  set extra = public.resolve_agent_config(_config, _agent.extra),
      template_id = null,
      template_version = null,
      template_auto_update = false
  where id = _agent_id
  returning * into _agent;

  if not found then
    raise exception using errcode = '42501', message = 'not allowed';
  end if;

  return _agent;
end;
$$;

revoke execute on function public.unlink_agent_template(uuid)
from public, service_role;

grant execute on function public.unlink_agent_template(uuid)
to authenticated, anon;

-- T7. Whether one of the caller's own agents runs on this version.
--
-- A helper and not an inline `exists`, for a reason that only shows up at the
-- edge: `rls.get_authorized_orgs` RAISES 42501 for a caller with neither a JWT
-- nor an api-key header, instead of resolving to an empty set. Written inline,
-- this policy would turn "anon reads nothing here" — which is what
-- `35_agent_templates` pins — into "anon gets an error", for a table whose
-- other policy has always answered anonymous readers with an empty list.
--
-- So the raise is caught and answered the way a policy should answer: no.
create function rls.runs_template_version(_template_id uuid, _version integer)
returns boolean
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  return exists (
    select 1
    from public.agents a
    where a.template_id = _template_id
      and a.template_version = _version
      and a.organization_id in (select rls.get_authorized_orgs('member'))
  );
exception when insufficient_privilege then
  return false;
end;
$$;

revoke execute on function rls.runs_template_version(uuid, integer) from public;

grant execute on function rls.runs_template_version(uuid, integer)
to anon, authenticated, service_role;
