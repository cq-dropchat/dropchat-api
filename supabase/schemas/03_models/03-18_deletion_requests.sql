-- F18. Deletions as requests: mark now, sweep later.
--
-- An owner deleting an organization, or Meta's data-deletion callback
-- deleting an Instagram account, used to run the whole cascade (every
-- conversation and message) in the caller's one transaction — and the
-- callback did it for every organization holding that account.
--
-- One row per request, scoped to ONE organization:
--   service/address null  the organization itself
--   service/address set   one account (organizations_addresses row) of it
-- `id` is the confirmation code returned to Meta. Rows stay after
-- completion as the record of what was deleted and when; organization_id
-- has no FK for that reason.
--
-- Service role only, like public.rate_limits.
create table public.deletion_requests (
  id uuid default gen_random_uuid() not null,
  organization_id uuid not null,
  service public.service,
  address text,
  -- 'owner' (UI/API delete) or 'meta_data_deletion' (Meta callback).
  source text not null,
  requested_at timestamp with time zone default now() not null,
  started_at timestamp with time zone,
  completed_at timestamp with time zone,
  deleted_rows bigint default 0 not null
);

alter table only public.deletion_requests
add constraint deletion_requests_pkey
primary key (id);

alter table only public.deletion_requests
add constraint deletion_requests_scope_check
check ((service is null) = (address is null));

-- One pending request per target: repeating a request returns the pending one.
create unique index deletion_requests_pending_key
on public.deletion_requests
using btree (organization_id, service, address) nulls not distinct
where completed_at is null;

alter table public.deletion_requests enable row level security;

revoke all on table public.deletion_requests from anon, authenticated;
