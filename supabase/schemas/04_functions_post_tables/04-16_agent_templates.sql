-- T4. Publishing a template.
--
-- This is the only write in the schema that crosses every tenant boundary at
-- once: it takes one organization's agent configuration and puts it where the
-- entire customer base can read it. Everything here is shaped by that.

-- What of an agent's `extra` becomes a published template.
--
-- The agent's own `extra` as stored is already masked by extract_secrets, so
-- the api_key, a tool's password and token, and every value under a tool's
-- headers arrive here as '********'. This function's job is the part masking
-- does NOT cover.
--
-- It drops each tool's `config` entirely, and keeps the tool's identity
-- (provider, type, label/name). Two separate reasons, either one sufficient:
--
--   1. extract_secrets masks a FIXED list of key names. A tool whose config
--      carries `api_key`, `secret`, or anything else it was not taught about
--      is stored in cleartext, and publishing it would hand that credential to
--      every organization in the product.
--   2. Even fully masked, a config is the source organization's `host`,
--      `user`, `database`, `url` and `email`. Those are not credentials and
--      never get masked, and a catalogue every tenant reads is no place for
--      the platform's own infrastructure. They are also useless to the
--      installing organization, which has to point the tool at its own.
--
-- So a published template declares WHICH tools it uses and the installing
-- organization supplies the connection (T6).
--
-- The agent's top-level `api_key` is kept as the mask rather than dropped: it
-- states that the template expects one. On install, extract_secrets sees a
-- mask with nothing stored behind it and removes the key itself — "do not keep
-- the lie in extra" — so it cannot become a credential that looks configured
-- and is not.
create function public.agent_template_config(_extra jsonb) returns jsonb
language sql
immutable
set search_path to ''
as $$
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
$$;

revoke execute on function public.agent_template_config(jsonb)
from public, anon, authenticated, service_role;

-- Publish the source agent's current configuration as the next version.
--
-- SECURITY DEFINER because `agent_template_versions` has no write policy at
-- all: this function is the only way a row gets in, which is what makes the
-- sanitising above unavoidable rather than customary.
--
-- It reads `agents.extra` — the stored, masked row — and never public.secrets.
-- There is no branch here that could.
create function public.publish_agent_template_version(
  _template_id uuid,
  _changelog text default null,
  _canary_organizations uuid[] default null
) returns public.agent_template_versions
language plpgsql
security definer
set search_path to ''
as $$
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
$$;

revoke execute on function
  public.publish_agent_template_version(uuid, text, uuid[])
from public, anon, service_role;

-- `authenticated` and nothing else. service_role is revoked explicitly because
-- Supabase grants it separately from PUBLIC, so revoking PUBLIC does not reach
-- it — and publishing is an act of a signed-in person whose auth.uid() the
-- function records. Under service_role, auth.uid() is null and
-- rls.is_platform_admin() is false, so the call would fail anyway; this makes
-- the grant say so instead of relying on it.
grant execute on function
  public.publish_agent_template_version(uuid, text, uuid[])
to authenticated;

-- T5. Promote a staged version: it stops being for two organizations and
-- becomes the one everybody installs. SECURITY DEFINER for the same reason
-- publishing is — `agent_template_versions` has no write policy at all.
create function public.promote_agent_template_version(
  _template_id uuid,
  _version integer
) returns public.agent_template_versions
language plpgsql
security definer
set search_path to ''
as $$
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
$$;

revoke execute on function public.promote_agent_template_version(uuid, integer)
from public, anon, service_role;

grant execute on function public.promote_agent_template_version(uuid, integer)
to authenticated;

-- Pull a single version: a bad prompt, or a configuration that should not have
-- gone out. Retiring, not deleting — the organizations that installed it point
-- at this row, and deleting it would make their install unexplainable.
create function public.retire_agent_template_version(
  _template_id uuid,
  _version integer
) returns public.agent_template_versions
language plpgsql
security definer
set search_path to ''
as $$
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
$$;

revoke execute on function public.retire_agent_template_version(uuid, integer)
from public, anon, service_role;

grant execute on function public.retire_agent_template_version(uuid, integer)
to authenticated;
