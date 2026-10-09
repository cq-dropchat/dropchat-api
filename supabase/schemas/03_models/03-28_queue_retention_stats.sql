-- Aggregated evidence survives terminal payload purge. One row per tenant/day/status.
create table public.queue_retention_stats (
 organization_id uuid not null references public.organizations(id) on delete cascade,
 table_name text not null check (table_name in ('edge_calls','webhook_deliveries')),
 status text not null check (status in ('done','delivered','failed')),
 day date not null,
 purged_rows bigint not null,
 payload_bytes bigint not null,
 attempts bigint not null,
 oldest_created_at timestamptz not null,
 newest_created_at timestamptz not null,
 primary key (organization_id,table_name,status,day)
);
alter table public.queue_retention_stats enable row level security;
revoke all on public.queue_retention_stats from anon,authenticated;
