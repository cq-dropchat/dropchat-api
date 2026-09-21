alter table "public"."agents" add column "template_auto_update" boolean not null default false;

alter table "public"."agents" add column "template_id" uuid;

alter table "public"."agents" add column "template_version" integer;

alter table "public"."agents" add constraint "agents_template_complete" CHECK (((template_id IS NULL) = (template_version IS NULL))) not valid;

alter table "public"."agents" validate constraint "agents_template_complete";

alter table "public"."agents" add constraint "agents_template_version_fkey" FOREIGN KEY (template_id, template_version) REFERENCES public.agent_template_versions(template_id, version) ON DELETE SET NULL not valid;

alter table "public"."agents" validate constraint "agents_template_version_fkey";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.agent_tool_key(_tool jsonb)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select coalesce(_tool ->> 'type', '?') || ':' ||
         coalesce(_tool ->> 'label', _tool ->> 'name', '');
$function$
;

CREATE OR REPLACE FUNCTION public.agent_tool_ready(_tool jsonb)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case
    when _tool ->> 'type' in ('mcp', 'sql', 'http')
      then jsonb_typeof(_tool -> 'config') = 'object'
        and _tool -> 'config' <> '{}'::jsonb
    else true
  end;
$function$
;

CREATE OR REPLACE FUNCTION public.install_agent_template(_organization_id uuid, _template_id uuid, _version integer DEFAULT NULL::integer, _name text DEFAULT NULL::text)
 RETURNS public.agents
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.resolve_agent_config(_config jsonb, _extra jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.unlink_agent_template(_agent_id uuid)
 RETURNS public.agents
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.update_agent_template_version(_agent_id uuid, _version integer DEFAULT NULL::integer)
 RETURNS public.agents
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.publish_agent_template_version(_template_id uuid, _changelog text DEFAULT NULL::text)
 RETURNS public.agent_template_versions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _template public.agent_templates;
  _agent public.agents;
  _template_org uuid;
  _config jsonb;
  _hash text;
  _version integer;
  _row public.agent_template_versions;
begin
  if not rls.is_platform_admin() then
    raise exception using errcode = '42501', message = 'not a platform admin';
  end if;

  select * into _template from public.agent_templates where id = _template_id;

  if not found then
    raise exception 'no such template: %', _template_id;
  end if;

  if _template.archived_at is not null then
    raise exception 'template % is archived', _template.slug;
  end if;

  if _template.source_agent_id is null then
    raise exception 'template % has no source agent', _template.slug;
  end if;

  select template_org_id into _template_org from public.platform_settings;

  if _template_org is null then
    raise exception
      'no template organization is configured (see platform_settings)';
  end if;

  select * into _agent from public.agents
  where id = _template.source_agent_id and deleted_at is null;

  if not found then
    raise exception 'the source agent of % is gone', _template.slug;
  end if;

  -- The guard that matters as much as the masking: a source outside the
  -- template organization would copy a TENANT's configuration into a
  -- catalogue everybody reads. `source_agent_id` is a plain column an admin
  -- can set to any agent in the product, so the check belongs here, at the
  -- only door.
  if _agent.organization_id <> _template_org then
    raise exception
      'the source agent of % is not in the template organization',
      _template.slug;
  end if;

  _config := public.agent_template_config(_agent.extra);
  _hash := md5(_config::text);

  -- A version that changes nothing is not a version: every organization that
  -- installed the last one would be told an update is available and get the
  -- same configuration back (T6/D7).
  if exists (
    select 1 from public.agent_template_versions
    where template_id = _template_id
      and config_hash = _hash
      and retired_at is null
  ) then
    raise exception
      'nothing changed since the last published version of %', _template.slug;
  end if;

  select coalesce(max(version), 0) + 1 into _version
  from public.agent_template_versions
  where template_id = _template_id;

  insert into public.agent_template_versions
    (template_id, version, config, config_hash, changelog, published_by)
  values (_template_id, _version, _config, _hash, _changelog, auth.uid())
  returning * into _row;

  -- D7/T6: the agents that asked to be moved, move now — in the same
  -- transaction that published the version, so there is no window where an
  -- agent wants the newest version and is not on it. Crossing tenants here is
  -- the point and is what this function is already allowed to do; what makes
  -- it safe is that each of those agents opted in, one column at a time.
  update public.agents
  set template_version = _version
  where template_id = _template_id
    and template_auto_update
    and deleted_at is null;

  return _row;
end;
$function$
;



-- Hand-appended, like T4's: `db diff` (migra) does NOT model function EXECUTE
-- privileges. It reports "No schema changes found" while every function above
-- stays callable by `anon` through PostgREST.
revoke execute on function public.agent_tool_key(jsonb)
from public, anon, authenticated, service_role;

revoke execute on function public.agent_tool_ready(jsonb)
from public, anon, authenticated, service_role;

-- The resolver itself is callable: unlinking runs as the person doing it, and
-- it reads nothing — both layers arrive as arguments.
revoke execute on function public.resolve_agent_config(jsonb, jsonb)
from public;

grant execute on function public.resolve_agent_config(jsonb, jsonb)
to authenticated, anon, service_role;

-- The three writers are SECURITY INVOKER: the policies of `public.agents`
-- decide, so `authenticated` and `anon` (which is what an API key connects as)
-- may call them and be refused by RLS if they are not admins. `service_role`
-- is revoked because nothing server-side installs a template for anybody.
revoke execute on function
  public.install_agent_template(uuid, uuid, integer, text)
from public, service_role;

grant execute on function
  public.install_agent_template(uuid, uuid, integer, text)
to authenticated, anon;

revoke execute on function public.update_agent_template_version(uuid, integer)
from public, service_role;

grant execute on function public.update_agent_template_version(uuid, integer)
to authenticated, anon;

revoke execute on function public.unlink_agent_template(uuid)
from public, service_role;

grant execute on function public.unlink_agent_template(uuid)
to authenticated, anon;
