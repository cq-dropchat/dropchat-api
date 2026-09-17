alter table public.webhook_deliveries enable row level security;

-- Owners only, like webhooks themselves (05-07): a delivery carries the
-- org's traffic.
create policy "owners can read their orgs webhook deliveries"
on public.webhook_deliveries
for select
to authenticated, anon
using (
  organization_id in (
    select rls.get_authorized_orgs('owner')
  )
);

-- Read-only for API roles; the default privileges would grant writes and
-- truncate too.
revoke all on table public.webhook_deliveries from anon, authenticated;
grant select on table public.webhook_deliveries to anon, authenticated;
