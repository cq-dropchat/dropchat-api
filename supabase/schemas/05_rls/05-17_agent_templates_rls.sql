-- T4. The catalogue is global to read and closed to write.
--
-- Every other table in this schema answers "is this row mine?". These answer
-- "is this row published?", which is a different question with a different
-- failure mode: the risk is not leaking one tenant's data to another, it is
-- letting a tenant put a row into a catalogue everybody else installs from.
-- So every write policy below belongs to the platform admin, and the ones that
-- have no policy at all have none on purpose.

-- Who the source organization is, is the platform's business and nobody
-- else's. A tenant that could read it learns which organization to attack to
-- reach every other tenant's agents; a tenant that could write it would point
-- the source at itself.
alter table public.platform_settings enable row level security;

create policy "platform admins can read the platform settings"
on public.platform_settings
for select
to authenticated
using (rls.is_platform_admin());

-- No INSERT, UPDATE or DELETE policy, deliberately, and not even for an admin:
-- the row is created once by hand with the runbook in README.md. Repointing
-- the template source is not a thing to do from a browser session — it decides
-- what every organization installs.

alter table public.agent_templates enable row level security;

-- B3/B5: any signed-in member of any organization reads the catalogue, on
-- every plan. Templates are global on purpose (D6) — this is the policy that
-- makes them so.
--
-- `to authenticated` and not `anon` means API keys read nothing here:
-- installing a template is an act of a person choosing one, not of an
-- integration, and until T6 gives it an API there is no reason to widen this.
create policy "members can read the published catalogue"
on public.agent_templates
for select
to authenticated
using (archived_at is null or rls.is_platform_admin());

create policy "platform admins can write the catalogue"
on public.agent_templates
for insert
to authenticated
with check (rls.is_platform_admin());

create policy "platform admins can edit the catalogue"
on public.agent_templates
for update
to authenticated
using (rls.is_platform_admin())
with check (rls.is_platform_admin());

alter table public.agent_template_versions enable row level security;

-- Published and not retired, under a template that is not archived. The three
-- conditions are the same sentence said once for the version and once for its
-- template: a retired version and an archived template both mean "stop
-- offering this", and either one alone has to be enough.
create policy "members can read published versions"
on public.agent_template_versions
for select
to authenticated
using (
  rls.is_platform_admin()
  or (
    retired_at is null
    and exists (
      select 1
      from public.agent_templates t
      where t.id = agent_template_versions.template_id
        and t.archived_at is null
    )
  )
);

-- No write policy of any kind, not even for a platform admin. A version is
-- produced by public.publish_agent_template_version, which is the only code
-- that knows to copy the MASKED `extra` and to drop each tool's config; an
-- INSERT policy would be a second way in that skips exactly that, and the one
-- thing this item cannot afford is a second way in.

-- ---------------------------------------------------------------------------
-- Privileges, under the policies.
--
-- Supabase's default privileges hand `anon` and `authenticated` SELECT,
-- INSERT, UPDATE, DELETE and TRUNCATE on every new table in `public`. That
-- leaves row-level security as the only thing standing between a stolen
-- session and the catalogue every organization installs from — which is how
-- platform_admins was left, and this item cannot afford it twice.
--
-- What each table actually needs from an API role:
--   platform_settings        — nothing but SELECT. The row is set up by hand.
--   agent_template_versions  — nothing but SELECT. Versions are produced by
--                              public.publish_agent_template_version, which is
--                              SECURITY DEFINER and does not run as the caller.
--   agent_templates          — INSERT and UPDATE, gated by the admin policies
--                              above. Never DELETE: archiving is what retires a
--                              template, and deleting one would strand the
--                              installs that point at it.
revoke insert, update, delete, truncate
on public.platform_settings from anon, authenticated;

revoke insert, update, delete, truncate
on public.agent_template_versions from anon, authenticated;

revoke delete, truncate
on public.agent_templates from anon, authenticated;

-- T7. The version YOUR OWN agent runs on, whatever happened to it since.
--
-- The catalogue policy above hides retired versions and archived templates,
-- which is how the platform stops handing something out. But an organization
-- that already installed one has to keep reading it: B3 says the base
-- instructions are visible, and «this version was retired» is precisely the
-- notice that tells somebody to move — a screen that goes blank instead
-- explains nothing at the moment it matters most.
--
-- Narrow on purpose: it is YOUR agent's version, not anybody's. Somebody
-- else's install is not a reason to read a version that was pulled.
create policy "members can read the versions their agents run on"
on public.agent_template_versions
for select
to authenticated, anon
using (rls.runs_template_version(template_id, version));
