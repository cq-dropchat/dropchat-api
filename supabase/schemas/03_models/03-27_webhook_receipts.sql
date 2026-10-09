-- Platform ledger: a verified webhook may contain several tenants.
-- Raw payloads are never readable by tenant users or published through Realtime.
create table public.webhook_receipts (
  id uuid primary key default gen_random_uuid(),
  digest text not null unique check (digest ~ '^[0-9a-f]{64}$'),
  payload jsonb not null,
  correlation_id text,
  status text not null default 'pending' check (status in ('pending','processing','done','failed')),
  attempts integer not null default 0,
  lease_token uuid,
  lease_until timestamptz,
  next_attempt_at timestamptz not null default now(),
  last_error_class text,
  last_scheduled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.webhook_receipts enable row level security;
revoke all on public.webhook_receipts from anon, authenticated;
create index webhook_receipts_due_idx on public.webhook_receipts(next_attempt_at,id) where status='pending';
create index webhook_receipts_lease_idx on public.webhook_receipts(lease_until,id) where status='processing';
create trigger set_updated_at before update on public.webhook_receipts for each row execute function public.moddatetime('updated_at');
