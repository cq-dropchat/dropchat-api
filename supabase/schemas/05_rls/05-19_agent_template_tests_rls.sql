alter table public.agent_template_tests enable row level security;
alter table public.agent_template_test_runs enable row level security;

-- The platform's, both of them. Unlike the catalogue — which exists to be read
-- by every tenant — these decide what gets published, so a tenant has nothing
-- to read here and nothing to write.
--
-- `rls.is_platform_admin()` and not `get_authorized_orgs`: this is not an
-- organization permission, and the helper answers false for a caller with no
-- session instead of raising, which keeps anon reading an empty list.
create policy "platform admins manage the drills"
on public.agent_template_tests
for all
to authenticated
using (rls.is_platform_admin())
with check (rls.is_platform_admin());

create policy "platform admins manage the runs"
on public.agent_template_test_runs
for all
to authenticated
using (rls.is_platform_admin())
with check (rls.is_platform_admin());

revoke truncate on public.agent_template_tests from anon, authenticated;
revoke truncate on public.agent_template_test_runs from anon, authenticated;
