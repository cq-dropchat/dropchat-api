-- Outgoing webhook deliveries (F06/F12): the durable queue between a row
-- change and the integrator's endpoint.
--
-- notify_webhook (02-03_trigger_functions.sql) INSERTS here — one row per
-- matching webhook, inside the writer's transaction — and does nothing
-- else. Delivery is deliver_webhooks() (04-04_webhook_delivery.sql), run by
-- pg_cron every 30 seconds: it takes what is due with SKIP LOCKED, POSTs
-- through pg_net with a 5 s timeout and an HMAC signature, and on the next
-- tick settles each attempt from net._http_response — success, or a retry
-- with backoff (1 s, 5 s, 30 s, 5 min, 1 h), or the dead letter after the
-- fifth failure.
--
-- What this replaces: net.http_post straight from the trigger — one shot,
-- no retry, no signature, `limit 3` with no order, and the trigger's own
-- latency paid by every message insert and status update.
--
-- Owners can read their organization's deliveries (a dead-letter view for
-- the dashboard); no API role writes here.
create table public.webhook_deliveries (
  id uuid default gen_random_uuid() not null,
  organization_id uuid not null,
  webhook_id uuid not null,
  -- 'messages.insert', 'organizations_addresses.update', …
  event text not null,
  -- The body as delivered: {"data": <row>, "entity": <table>, "action": <op>}.
  payload jsonb not null,
  -- pending → delivering → delivered | pending (retry) | failed (dead letter)
  status text default 'pending'::text not null,
  attempts integer default 0 not null,
  next_at timestamp with time zone default now() not null,
  -- pg_net request of the attempt in flight (settled on the next tick).
  request_id bigint,
  last_status_code integer,
  last_error text,
  delivered_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.webhook_deliveries
add constraint webhook_deliveries_pkey
primary key (id);

alter table only public.webhook_deliveries
add constraint webhook_deliveries_status_check
check (status in ('pending', 'delivering', 'delivered', 'failed'));

alter table only public.webhook_deliveries
add constraint webhook_deliveries_organization_id_fkey
foreign key (organization_id)
references public.organizations(id)
on delete cascade;

-- Deleting a webhook drops its backlog too: nothing left to deliver to.
alter table only public.webhook_deliveries
add constraint webhook_deliveries_webhook_id_fkey
foreign key (webhook_id)
references public.webhooks(id)
on delete cascade;

-- The worker's two probes, and only those rows: what is due, and what is
-- in flight. Delivered/failed rows never match, so the index stays the size
-- of the backlog whatever the history grows to.
create index webhook_deliveries_due_idx
on public.webhook_deliveries
using btree (next_at)
where status in ('pending', 'delivering');

-- Dashboard / dead-letter listing per organization.
create index webhook_deliveries_organization_idx
on public.webhook_deliveries
using btree (organization_id, created_at desc);

create trigger set_updated_at
before update
on public.webhook_deliveries
for each row
execute function public.moddatetime('updated_at');
