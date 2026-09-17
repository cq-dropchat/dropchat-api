-- F18. An owner's export of the organization's data.
--
-- request_organization_export (04-10) files a row; the org-export worker
-- (pg_cron → Edge Function) claims it, writes a ZIP with one NDJSON file per
-- table to the private `exports` bucket at
-- organizations/<org>/exports/<id>.zip, and marks it ready for 7 days.
-- Owners read their organization's rows (05-12) and sign a download URL for
-- the file (05-11). One pending or processing export per organization.
--
-- No FK to organizations, like deletion_requests: the row outlives a deleted
-- organization until the worker has removed its file (sweep_deletions
-- expires it at once) and purge_expired_rows deletes it.
create table public.organization_exports (
  id uuid default gen_random_uuid() not null,
  organization_id uuid not null,
  -- auth.users id of the owner who asked; null for an owner API key.
  requested_by uuid,
  -- pending → processing → ready → expired, or → failed.
  status text default 'pending' not null,
  object_name text,
  error text,
  requested_at timestamp with time zone default now() not null,
  started_at timestamp with time zone,
  completed_at timestamp with time zone,
  expires_at timestamp with time zone
);

alter table only public.organization_exports
add constraint organization_exports_pkey
primary key (id);

alter table only public.organization_exports
add constraint organization_exports_status_check
check (status in ('pending', 'processing', 'ready', 'failed', 'expired'));

create unique index organization_exports_active_key
on public.organization_exports
using btree (organization_id)
where status in ('pending', 'processing');

create index organization_exports_status_idx
on public.organization_exports
using btree (status, expires_at);

alter table public.organization_exports enable row level security;

revoke insert, update, delete, truncate on table public.organization_exports from anon, authenticated;

-- The worker starts on the request; the hourly `org-export` cron retries
-- stale claims and removes expired files.
create trigger handle_organization_export_requested
after insert
on public.organization_exports
for each row
execute function public.edge_function('/org-export', 'post');
