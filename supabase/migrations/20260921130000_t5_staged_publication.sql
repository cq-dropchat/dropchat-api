drop policy "members can read published versions" on "public"."agent_template_versions";

drop function if exists "public"."publish_agent_template_version"(_template_id uuid, _changelog text);

alter table "public"."agent_template_versions" add column "canary_organizations" uuid[];

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.promote_agent_template_version(_template_id uuid, _version integer)
 RETURNS public.agent_template_versions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _row public.agent_template_versions;
begin
  if not rls.is_platform_admin() then
    raise exception using errcode = '42501', message = 'not a platform admin';
  end if;

  update public.agent_template_versions
  set canary_organizations = null
  where template_id = _template_id and version = _version
  returning * into _row;

  if not found then
    raise exception 'no such version: % of %', _version, _template_id;
  end if;

  return _row;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.publish_agent_template_version(_template_id uuid, _changelog text DEFAULT NULL::text, _canary_organizations uuid[] DEFAULT NULL::uuid[])
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
    (template_id, version, config, config_hash, changelog, published_by,
     canary_organizations)
  values (_template_id, _version, _config, _hash, _changelog, auth.uid(),
          nullif(_canary_organizations, '{}'::uuid[]))
  returning * into _row;

  -- D7/T6: the agents that asked to be moved, move now — in the same
  -- transaction that published the version, so there is no window where an
  -- agent wants the newest version and is not on it. Crossing tenants here is
  -- the point and is what this function is already allowed to do; what makes
  -- it safe is that each of those agents opted in, one column at a time.
  -- T5: and only the organizations this version is FOR. This is the one
  -- place a canary needs an explicit branch: it runs as SECURITY DEFINER, so
  -- no policy filters it, and «automatic» has to mean the versions that
  -- organization can have — not «the newest row that exists».
  update public.agents
  set template_version = _version
  where template_id = _template_id
    and template_auto_update
    and deleted_at is null
    and (
      _row.canary_organizations is null
      or organization_id = any (_row.canary_organizations)
    );

  return _row;
end;
$function$
;

CREATE OR REPLACE FUNCTION rls.version_is_for_caller(_organizations uuid[])
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if _organizations is null or cardinality(_organizations) = 0 then
    return true;
  end if;

  return exists (
    select 1
    from unnest(_organizations) as o(id)
    where o.id in (select rls.get_authorized_orgs('member'))
  );
exception when insufficient_privilege then
  return false;
end;
$function$
;


  create policy "members can read published versions"
  on "public"."agent_template_versions"
  as permissive
  for select
  to authenticated
using ((rls.is_platform_admin() OR ((retired_at IS NULL) AND rls.version_is_for_caller(canary_organizations) AND (EXISTS ( SELECT 1
   FROM public.agent_templates t
  WHERE ((t.id = agent_template_versions.template_id) AND (t.archived_at IS NULL)))))));




-- Hand-appended: `db diff` does not model function EXECUTE privileges, and
-- the two functions below are new or re-created (the old two-argument
-- `publish_agent_template_version` is dropped above, so its grants go with it).
revoke execute on function rls.version_is_for_caller(uuid[]) from public;

grant execute on function rls.version_is_for_caller(uuid[])
to anon, authenticated, service_role;

revoke execute on function
  public.publish_agent_template_version(uuid, text, uuid[])
from public, anon, service_role;

grant execute on function
  public.publish_agent_template_version(uuid, text, uuid[])
to authenticated;

revoke execute on function public.promote_agent_template_version(uuid, integer)
from public, anon, service_role;

grant execute on function public.promote_agent_template_version(uuid, integer)
to authenticated;
