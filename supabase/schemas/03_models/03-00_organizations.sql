create table public.organizations (
  id uuid default gen_random_uuid() not null,
  name text not null,
  extra jsonb,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  -- F18: set when the owner deletes the organization. From then on
  -- get_authorized_orgs no longer returns it; sweep_deletions removes the
  -- data in batches and finally the row.
  deletion_requested_at timestamp with time zone
);

alter table only public.organizations
add constraint organizations_pkey
primary key (id);

create trigger handle_new_organization
after insert
on public.organizations
for each row
execute function public.after_insert_on_organizations();

create trigger set_extra
before update
on public.organizations
for each row
when (
  new.extra is not null
)
execute function public.merge_update('extra');

create trigger set_updated_at
before update
on public.organizations
for each row
execute function public.moddatetime('updated_at');

-- F18: an owner's DELETE files a deletion request and marks the row instead
-- (see request_organization_deletion); only the sweep deletes for real.
create trigger request_deletion
before delete
on public.organizations
for each row
execute function public.request_organization_deletion();
