-- Edge Function calls (F12): the durable queue between a message trigger and
-- agent-client / media-preprocessor.
--
-- enqueue_edge_call (04-11) INSERTS here from the triggers on messages, inside
-- the writer's transaction, and does nothing else. deliver_edge_calls(), run
-- by pg_cron every 5 seconds, settles the attempts in flight from
-- net._http_response and sends what is due through pg_net — SKIP LOCKED, at
-- most a few calls per organization per tick so one tenant's burst does not
-- queue in front of the others — retrying with backoff and failing after the
-- fifth attempt. edge_calls_health (04-11) is the backlog per function and
-- organization.
--
-- What this replaces: net.http_post straight from the triggers — one shot,
-- no retry, no fairness, no metric. The outgoing dispatchers keep their own
-- lease and sweep (F11) and still call pg_net directly.
--
-- Service role only.
create table public.edge_calls (
  id uuid default gen_random_uuid() not null,
  organization_id uuid not null,
  -- The Edge Function: 'agent-client' or 'media-preprocessor'.
  function text not null,
  -- The row the call is about (messages.id).
  record_id uuid not null,
  -- The body: {old_record, record, type, table, schema}, as the triggers sent.
  payload jsonb not null,
  -- Headers to add to the call: the x-request-id of the writing request (F26).
  forward_headers jsonb default '{}'::jsonb not null,
  -- pending → sending → done | pending (retry) | failed
  status text default 'pending' not null,
  attempts integer default 0 not null,
  next_attempt_at timestamp with time zone default now() not null,
  -- While sending: after this, an attempt with no response is retried.
  locked_until timestamp with time zone,
  -- pg_net request of the attempt in flight.
  request_id bigint,
  last_status_code integer,
  last_error text,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.edge_calls
add constraint edge_calls_pkey
primary key (id);

alter table only public.edge_calls
add constraint edge_calls_function_check
check (function in ('agent-client', 'media-preprocessor'));

alter table only public.edge_calls
add constraint edge_calls_status_check
check (status in ('pending', 'sending', 'done', 'failed'));

alter table only public.edge_calls
add constraint edge_calls_organization_id_fkey
foreign key (organization_id)
references public.organizations(id)
on delete cascade;

-- What the worker reads: due calls, and calls in flight.
create index edge_calls_pending_idx
on public.edge_calls
using btree (organization_id, next_attempt_at)
where status = 'pending';

create index edge_calls_sending_idx
on public.edge_calls
using btree (request_id)
where status = 'sending';

create index edge_calls_record_idx
on public.edge_calls
using btree (record_id);

create trigger set_updated_at
before update
on public.edge_calls
for each row
execute function public.moddatetime('updated_at');

alter table public.edge_calls enable row level security;

revoke all on table public.edge_calls from anon, authenticated;
