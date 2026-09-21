set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.agent_template_config(_extra jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case
    when _extra is null then '{}'::jsonb
    when jsonb_typeof(_extra -> 'tools') = 'array' then
      jsonb_set(
        _extra,
        '{tools}',
        (
          select coalesce(jsonb_agg(e.tool - 'config' order by e.ord), '[]'::jsonb)
          from jsonb_array_elements(_extra -> 'tools') with ordinality as e(tool, ord)
        )
      )
    else _extra
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

  return _row;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.retire_agent_template_version(_template_id uuid, _version integer)
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

  -- coalesce: retiring twice keeps the first timestamp, which is the one that
  -- says when it stopped being offered.
  update public.agent_template_versions
  set retired_at = coalesce(retired_at, now())
  where template_id = _template_id and version = _version
  returning * into _row;

  if not found then
    raise exception 'no such version: % of %', _version, _template_id;
  end if;

  return _row;
end;
$function$
;



-- Hand-written, for the same reason as the E1 migration says: `db diff`
-- (migra) does not carry function privileges across, so everything below is
-- absent from the diff above even though it is declared in
-- supabase/schemas/04_functions_post_tables/04-16_agent_templates.sql — and
-- `db diff` reports "No schema changes found" all the same, so nothing warns
-- you.
--
-- Without it Postgres' default applies: EXECUTE to PUBLIC. agent_template_config
-- would be a live PostgREST endpoint, and so would the two functions that write
-- the catalogue — they check rls.is_platform_admin() themselves, so this is
-- depth rather than the only lock, but the sanitiser has no business being
-- callable at all.

revoke execute on function public.agent_template_config(jsonb)
from public, anon, authenticated, service_role;

revoke execute on function public.publish_agent_template_version(uuid, text)
from public, anon, service_role;

grant execute on function public.publish_agent_template_version(uuid, text)
to authenticated;

revoke execute on function public.retire_agent_template_version(uuid, integer)
from public, anon, service_role;

grant execute on function public.retire_agent_template_version(uuid, integer)
to authenticated;
