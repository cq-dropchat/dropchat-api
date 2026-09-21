alter table public.model_tiers enable row level security;

-- A catalogue, not tenant data: the three rows are the same for everybody, and
-- the agent form is built from them. `anon` is in the list because an API key
-- caller runs as `anon`, and because there is nothing here to keep from
-- anybody — the names of the models this platform calls are on the screen that
-- creates an agent.
create policy "anyone may read the tiers"
on public.model_tiers
for select
to authenticated, anon
using (true);

-- Writing is the platform's. A tier is read by every organization at once, so
-- an organization that could write one could change what every other
-- organization's agents run on.
create policy "platform admins manage the tiers"
on public.model_tiers
for all
to authenticated
using (rls.is_platform_admin())
with check (rls.is_platform_admin());

-- Supabase grants every new public table to `anon` and `authenticated` by
-- default, and RLS is what is left holding the door. TRUNCATE is not reachable
-- through a policy at all, so it is taken away outright.
revoke truncate on public.model_tiers from anon, authenticated;
