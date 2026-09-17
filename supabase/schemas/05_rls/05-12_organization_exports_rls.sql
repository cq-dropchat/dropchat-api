-- F18: owners see their organization's exports; nobody writes the table
-- through the API (request_organization_export files them).
create policy "owners can read their org exports"
on public.organization_exports
for select
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs('owner')
  )
);
