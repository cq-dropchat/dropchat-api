-- T4. Agent templates: the catalogue DropChat publishes and every organization
-- installs.
--
-- These are the first GLOBAL rows in this schema. Everything else is scoped to
-- a tenant by `rls.get_authorized_orgs()`, which never crosses organizations;
-- a template is the deliberate exception, because its whole purpose is to be
-- read by organizations that did not write it. That inverts where the danger
-- lies: not one tenant reading another's row, but one tenant WRITING a row the
-- rest of them read.

-- D12. Which organization is the source of templates (D6: a superadmin builds
-- them as ordinary agents inside a "DropChat" organization).
--
-- Single-row (the `check (id)` is what makes it so), like error_settings. A
-- column on `organizations` would be true in one row out of every tenant's,
-- and a flag in `organizations.extra` carries no constraint at all — nothing
-- would stop two organizations claiming to be the source, or a tenant writing
-- the flag itself. Here the foreign key makes the pointer be an organization
-- that exists, and the single row makes there be exactly one.
--
-- Ships EMPTY, like error_settings: `supabase/schemas/` is diffed, not
-- executed, so a seed INSERT here would live in the shadow database and never
-- reach a real one. The row is created by hand, once, with the runbook in
-- README.md — the same shape as the first platform admin, and for the same
-- reason: it is a deliberate act with no UI behind it.
--
-- `on delete set null` rather than cascade or restrict: deleting the source
-- organization must not delete the platform's settings row, and must not be
-- blocked by it either — `sweep_deletions` removes organization rows for real
-- (F18), and a restrict here would stall the sweep on a table the tenant has
-- nothing to do with.
create table public.platform_settings (
  id boolean not null default true,
  template_org_id uuid references public.organizations(id) on delete set null,
  updated_at timestamp with time zone not null default now()
);

alter table only public.platform_settings
add constraint platform_settings_pkey primary key (id);

alter table only public.platform_settings
add constraint platform_settings_singleton check (id);

create trigger set_updated_at
before update
on public.platform_settings
for each row
execute function public.moddatetime('updated_at');

-- The catalogue entry: one row per template, independent of its versions.
--
-- `source_agent_id` is the agent in the DropChat organization that the next
-- version is published FROM. It is a plain agent of a plain organization, so
-- it can be deleted: `on delete set null` orphans the template rather than
-- taking it down, because a published version is a COPY of the agent's
-- configuration and not a view of it. Losing the source stops future
-- publishing; it does not retract what is already out there.
--
-- `archived_at` retires the template as a whole — it stops being offered, and
-- the versions under it stop being installable with it. It is not a delete:
-- organizations that already installed it keep what they have (T6).
create table public.agent_templates (
  id uuid default gen_random_uuid() not null,
  slug text not null,
  name text not null,
  description text,
  category text,
  source_agent_id uuid,
  archived_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.agent_templates
add constraint agent_templates_pkey primary key (id);

alter table only public.agent_templates
add constraint agent_templates_slug_key unique (slug);

alter table only public.agent_templates
add constraint agent_templates_source_agent_id_fkey
foreign key (source_agent_id)
references public.agents(id)
on delete set null;

create trigger set_updated_at
before update
on public.agent_templates
for each row
execute function public.moddatetime('updated_at');

-- One row per published version. Versions are append-only by construction:
-- publishing inserts, and nothing rewrites a `config` that organizations may
-- already have installed.
--
-- `config` is the source agent's `extra` as it is stored — already masked by
-- extract_secrets — with every tool's `config` dropped (see
-- public.agent_template_config). `config_hash` is what T6 compares to know
-- whether an installed version has drifted from the published one; it is not
-- a security hash.
--
-- `retired_at` pulls a single version: a bad prompt, or a configuration that
-- should not have gone out. The table has no DELETE policy and no delete path,
-- because deleting a version would make the installs that point at it
-- unexplainable.
create table public.agent_template_versions (
  template_id uuid not null,
  version integer not null,
  config jsonb not null,
  config_hash text not null,
  changelog text,
  published_by uuid references auth.users(id) on delete set null,
  published_at timestamp with time zone default now() not null,
  retired_at timestamp with time zone,
  -- T5. Staged publication: the organizations this version is for, before it
  -- is for everybody. Null (or empty) means generally available.
  --
  -- A version that goes out to the whole customer base at once is a prompt
  -- change nobody piloted — every organization on that template starts
  -- answering differently in the same minute. So it can go to two or three
  -- first, be watched, and then be promoted.
  --
  -- Everything else falls out of RLS: the read policy hides a canary from the
  -- organizations it is not for, and install/update are SECURITY INVOKER, so
  -- their «newest version that is not retired» query is already filtered by
  -- what the caller may read. No second branch to keep in step with the first.
  canary_organizations uuid[]
);

alter table only public.agent_template_versions
add constraint agent_template_versions_pkey primary key (template_id, version);

alter table only public.agent_template_versions
add constraint agent_template_versions_template_id_fkey
foreign key (template_id)
references public.agent_templates(id)
on delete cascade;

alter table only public.agent_template_versions
add constraint agent_template_versions_version_check check (version > 0);

-- T6. What an installed agent points at.
--
-- Declared here and not in 03-04 because agents is created first: the same
-- reason organizations_addresses' agent FK lives in 03-04 and not in 03-01.
--
-- COMPOSITE, against (template_id, version) rather than against the template
-- alone: an agent that could name a version nobody published would resolve
-- against nothing, and «nothing» is a configuration with no instructions and
-- no tools — an agent that answers, badly, instead of one that fails loudly.
--
-- `on delete set null`: versions are retired, not deleted, so the only way
-- here is a template row going away for real, and that must not take an
-- organization's agent with it. It becomes an ordinary agent whose `extra` is
-- its whole configuration — which is exactly what unlinking does on purpose.
alter table only public.agents
add constraint agents_template_version_fkey
foreign key (template_id, template_version)
references public.agent_template_versions(template_id, version)
on delete set null;
