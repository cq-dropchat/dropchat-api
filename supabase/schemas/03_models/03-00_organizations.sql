create table public.organizations (
  id uuid default gen_random_uuid() not null,
  name text not null,
  extra jsonb,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  -- F18: set when the owner deletes the organization. From then on
  -- get_authorized_orgs no longer returns it; sweep_deletions removes the
  -- data in batches and finally the row.
  deletion_requested_at timestamp with time zone,
  -- H1: which AI agent takes a conversation that has no assignment yet — the
  -- organization's front door. Null means "the oldest eligible one", which is
  -- what every conversation got before assignments existed; the H1 migration
  -- backfills it with exactly that agent so no organization's behaviour moves
  -- on deploy day.
  --
  -- The reference is composite (see 03-21) so it cannot name another tenant's
  -- agent. Set to null when that agent is deleted: the organization falls back
  -- to the oldest eligible one rather than losing its front door silently.
  entry_agent_id uuid
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

-- H4: named `validate_` so it sorts after `set_extra`, because BEFORE
-- triggers fire in alphabetical order and only the MERGED row is worth
-- validating. On INSERT there is no merge and `extra` arrives whole, which is
-- why this covers both events and `set_extra` only covers UPDATE.
create trigger validate_extra
before insert or update
on public.organizations
for each row
when (new.extra is not null)
execute function public.validate_organization_attention();

-- F18: an owner's DELETE files a deletion request and marks the row instead
-- (see request_organization_deletion); only the sweep deletes for real.
create trigger request_deletion
before delete
on public.organizations
for each row
execute function public.request_organization_deletion();
