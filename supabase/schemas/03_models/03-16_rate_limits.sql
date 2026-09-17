-- F09. Per-organization, per-minute counters behind the API-role rate limit
-- on messages (check_message_rate_limit, 02-03_trigger_functions.sql).
--
-- One row per (organization, minute). The trigger upserts with
-- `count = count + 1`, which takes the row lock and so serializes an
-- organization's inserts within one minute — that is the point, and at the
-- limits involved it costs nothing. Rows older than an hour are swept by
-- the trigger itself on the first hit of each new minute, so the table
-- never holds more than ~60 rows per active organization.
--
-- Closed to API roles like public.secrets: nothing here is theirs to read,
-- and a counter they could update would be a limit they could reset.
create table public.rate_limits (
  organization_id uuid not null,
  -- What is being counted; 'messages' today, room for more.
  scope text not null,
  window_start timestamp with time zone not null,
  count integer default 0 not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.rate_limits
add constraint rate_limits_pkey
primary key (organization_id, scope, window_start);

alter table only public.rate_limits
add constraint rate_limits_organization_id_fkey
foreign key (organization_id)
references public.organizations(id)
on delete cascade;

alter table public.rate_limits enable row level security;

revoke all on table public.rate_limits from anon, authenticated;

-- Fires for every armed row; the function decides by role (API roles only).
-- `a_` so it sorts — and runs — before check_billing_message_limit: a burst
-- is refused for being a burst before it is refused for the plan, and a
-- refused row never touches the billing tables.
create trigger a_check_message_rate_limit
before insert
on public.messages
for each row
when ((new.status ->> 'pending') is not null)
execute function public.check_message_rate_limit();
