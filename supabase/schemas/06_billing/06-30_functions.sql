-- Check if a product limit allows usage for an organization.
-- Returns true if allowed, raises exception if blocked.
--  1. No subscription → allow (no billing)
--  2. No tiers_products row → allow (no limit)
--  3. Cap is null → unlimited, allow
--  4. Counter/gauge: usage + amount > cap → block
--  5. Balance: balance - amount < cap → block (cap is a floor, e.g. 0 or negative for debt)
create function billing.check_limit(
  _organization_id uuid,
  _product_id text,
  _amount numeric default 1
) returns boolean
language plpgsql
security definer
set search_path to ''
as $$
declare
  _tier_id text;
  _kind text;
  _cap numeric;
  _interval text;
  _current numeric;
  _period date;
begin
  -- Get tier from subscription
  select s.tier_id into _tier_id
  from billing.subscriptions s
  where s.organization_id = _organization_id;

  -- No subscription = no billing = allow
  if not found then
    return true;
  end if;

  -- Get product kind
  select p.kind into _kind
  from billing.products p
  where p.id = _product_id;

  -- No product = no billing for this resource
  if not found then
    return true;
  end if;

  -- Get tier cap and interval
  select tp.cap, tp.interval
  into _cap, _interval
  from billing.tiers_products tp
  where tp.tier_id = _tier_id
    and tp.product_id = _product_id;

  -- No tier_product row = no limit for this product
  if not found then
    return true;
  end if;

  -- Cap is null = unlimited
  if _cap is null then
    return true;
  end if;

  -- Determine the period to check
  _period := case _interval
    when 'month' then date_trunc('month', current_date)::date
    when 'day' then current_date
    else '1970-01-01'::date
  end;

  -- Get current value
  select u.quantity into _current
  from billing.usage u
  where u.organization_id = _organization_id
    and u.product_id = _product_id
    and u.interval = _interval
    and u.period = _period;

  _current := coalesce(_current, 0);

  -- Balance products: cap is a floor (minimum allowed balance)
  -- e.g. cap=0 means no debt, cap=-5 allows up to $5 debt
  -- SQLSTATE PT402: PostgREST maps PTnnn to HTTP status nnn, so every
  -- PostgREST-fronted surface (UI, API keys, RPC callers) answers 402
  -- Payment Required instead of a generic 400.
  if _kind = 'balance' then
    if _current - _amount < _cap then
      raise exception 'Insufficient balance for %', _product_id
        using errcode = 'PT402';
    end if;
  else
    -- Counter/gauge: cap is a ceiling
    if _current + _amount > _cap then
      raise exception 'Usage limit reached for %', _product_id
        using errcode = 'PT402';
    end if;
  end if;

  return true;
end;
$$;

-- Generic: increment usage counters for a product.
-- Upserts day, month, and lifetime rows.
create function billing.update_usage(
  _organization_id uuid,
  _product_id text,
  _quantity numeric default 1
) returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  _today date := current_date;
  _month date := date_trunc('month', current_date)::date;
begin
  -- No product = no billing for this resource
  if not exists (select 1 from billing.products where id = _product_id) then
    return;
  end if;

  -- Upsert day
  insert into billing.usage (organization_id, product_id, interval, period, quantity)
  values (_organization_id, _product_id, 'day', _today, _quantity)
  on conflict (organization_id, product_id, interval, period)
  do update set quantity = billing.usage.quantity + _quantity;

  -- Upsert month
  insert into billing.usage (organization_id, product_id, interval, period, quantity)
  values (_organization_id, _product_id, 'month', _month, _quantity)
  on conflict (organization_id, product_id, interval, period)
  do update set quantity = billing.usage.quantity + _quantity;

  -- Upsert lifetime
  insert into billing.usage (organization_id, product_id, interval, period, quantity)
  values (_organization_id, _product_id, 'lifetime', '1970-01-01', _quantity)
  on conflict (organization_id, product_id, interval, period)
  do update set quantity = billing.usage.quantity + _quantity;
end;
$$;

-- Messages: which rows count against the cap (F09).
--
-- Sendable rows always do — account-authored, armed, not record-only: the
-- same three facts that arm handle_outgoing_message_to_dispatcher. Inbound
-- rows written by the service role (the webhooks) never do: blocking what a
-- contact said loses data and 500s the shared Meta webhook.
--
-- An API role (anon = API key, authenticated = signed-in member) is capped
-- on EVERY armed row it inserts, whatever its shape. Before this rule a
-- member key inserted rows shaped like inbound (sender_address set) without
-- limit: each one skipped the cap, woke agent-client and an LLM call, and
-- landed in the shared pg_net queue.
create function billing.check_message_limit() returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  -- auth.role(): the JWT claim, not current_role — this function is
  -- SECURITY DEFINER, so current_role would be its owner.
  if (
    new.sender_address is null
    and new.content ->> 'internal' is null
  ) or coalesce(auth.role(), '') in ('anon', 'authenticated') then
    perform billing.check_limit(new.organization_id, 'messages');
  end if;

  return new;
end;
$$;

-- Generic trigger: check limit before insert.
-- Product id is derived from the table name (e.g. messages, conversations).
create function billing.check_product_limit() returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  perform billing.check_limit(new.organization_id, tg_table_name);
  return new;
end;
$$;

-- F17. Upper bound of one LLM call's cost, for the reservation made before
-- the call: every input token at the input price plus the output budget at
-- the output price (input price when the provider publishes one rate).
-- `pricing` and `quantity` are a billing.costs row.
create function billing.estimate_ai_cost(
  _pricing jsonb,
  _quantity numeric,
  _input_tokens numeric,
  _max_output_tokens numeric
) returns numeric
language sql
immutable
set search_path to ''
as $$
  select round(
    (
      coalesce(_input_tokens, 0) * coalesce((_pricing ->> 'input')::numeric, 0)
      + coalesce(_max_output_tokens, 0) * coalesce(
          (_pricing ->> 'output')::numeric,
          (_pricing ->> 'input')::numeric,
          0
        )
    ) / nullif(_quantity, 0),
    8
  );
$$;

-- F17. Message usage, split by what the plan's quota is about. `messages`
-- counts exactly what check_message_limit caps — rows the account sends,
-- and every row an API role inserts — so the quota is spent by the
-- organization, not by its contacts. What contacts write is metered as
-- `messages_inbound` (no tier caps it; stats only). Record-only rows (tool
-- traces, notes) count as neither.
create function billing.update_message_usage() returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  if new.content ->> 'internal' is not null then
    return new;
  end if;

  if new.sender_address is null
    or coalesce(auth.role(), '') in ('anon', 'authenticated')
  then
    perform billing.update_usage(new.organization_id, 'messages');
  else
    perform billing.update_usage(new.organization_id, 'messages_inbound');
  end if;

  return new;
end;
$$;

-- Generic trigger: update usage after insert or delete.
-- Product id is derived from the table name.
-- Counter products ignore delete; gauge products decrement on delete.
create function billing.update_product_usage() returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  _kind text;
begin
  if tg_op = 'DELETE' then
    select p.kind into _kind
    from billing.products p
    where p.id = tg_table_name;

    if _kind = 'counter' then
      return old;
    end if;

    perform billing.update_usage(old.organization_id, tg_table_name, -1);
    return old;
  end if;

  perform billing.update_usage(new.organization_id, tg_table_name);
  return new;
end;
$$;

-- Trigger: check storage limit before upload
-- Path convention: organizations/<org_id>/attachments/<file_id>
create function billing.check_storage_limit() returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  _org_id uuid;
  _size_gb numeric;
begin
  _org_id := (string_to_array(new.name, '/'))[2]::uuid;
  _size_gb := coalesce((new.metadata->>'size')::numeric, 0) / 1000000000.0;

  perform billing.check_limit(_org_id, 'storage', _size_gb);
  return new;
end;
$$;

-- Trigger: update storage usage after insert or delete
-- Path convention: organizations/<org_id>/attachments/<file_id>
create function billing.update_storage_usage() returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  _org_id uuid;
  _size_gb numeric;
begin
  if tg_op = 'INSERT' then
    _org_id := (string_to_array(new.name, '/'))[2]::uuid;
    _size_gb := coalesce((new.metadata->>'size')::numeric, 0) / 1000000000.0;
    perform billing.update_usage(_org_id, 'storage', _size_gb);
    return new;
  elsif tg_op = 'DELETE' then
    _org_id := (string_to_array(old.name, '/'))[2]::uuid;
    -- Orphaned object: the org (and its billing rows) was already deleted and the
    -- storage-gc sweep is removing the leftover files. There is no usage to
    -- credit back, so skip accounting to avoid acting on a non-existent org.
    if not exists (select 1 from public.organizations where id = _org_id) then
      return old;
    end if;
    _size_gb := coalesce((old.metadata->>'size')::numeric, 0) / 1000000000.0;
    perform billing.update_usage(_org_id, 'storage', -_size_gb);
    return old;
  end if;

  return coalesce(new, old);
end;
$$;

-- Trigger: skip ledger insert if the product doesn't exist (no billing)
create function billing.guard_ledger_insert() returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  if not exists (select 1 from billing.products where id = new.product_id) then
    return null;
  end if;
  return new;
end;
$$;

-- Trigger: update usage after ledger insert
-- Updates the lifetime balance and tracks daily/monthly cost stats.
-- Non-billable entries are recorded for analytics but don't affect balance.
create function billing.process_ledger_entry() returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  if new.billable is distinct from false then
    perform billing.update_usage(new.organization_id, new.product_id, new.quantity);
  end if;

  return new;
end;
$$;

-- F17. Length of a plan's billing period. A plan without a cycle (the free
-- plan) renews monthly: its included credits come back every month.
create function billing.plan_period(_billing_cycle text) returns interval
language sql
immutable
set search_path to ''
as $$
  select case _billing_cycle when 'year' then interval '1 year' else interval '1 month' end;
$$;

-- F17. Grants a plan's included balance products (AI credits) for one
-- period. Shared by initialize_subscription and renew_subscriptions. Keyed by
-- (organization, product, 'grant', period_start): granting a period twice is
-- a no-op. Returns the number of grants written.
create function billing.grant_included_products(
  _organization_id uuid,
  _plan_id text,
  _period_start timestamp with time zone
) returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  _count integer;
begin
  insert into billing.ledger (organization_id, product_id, type, quantity, period_start)
  select _organization_id, pp.product_id, 'grant', pp.included, _period_start
  from billing.plans_products pp
  join billing.products p on p.id = pp.product_id
  where pp.plan_id = _plan_id
    and p.kind = 'balance'
    and pp.included is not null
    and pp.included > 0
  on conflict (organization_id, product_id, type, period_start) do nothing;

  get diagnostics _count = row_count;
  return _count;
end;
$$;

-- Trigger: initialize subscription on organization insert.
-- Assigns the lowest-level active tier, then the default plan if one exists:
-- tier from the plan's min_tier, the first period (F17: start and end), and a
-- ledger grant for each balance product the plan includes.
-- No tiers = no billing.
--
-- Changing plan later (upgrades, purchases) is an app-layer concern — an edge
-- function updating billing.subscriptions and billing.ledger as service_role —
-- deliberately not a database function: the billing schema is exposed to
-- PostgREST, where any function is one default EXECUTE grant away from being a
-- signed-in user's RPC (see 06-40_grants.sql).
create function billing.initialize_subscription() returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  _tier_id text;
  _plan billing.plans%rowtype;
  _start timestamp with time zone := now();
begin
  select t.id into _tier_id
  from billing.tiers t
  where t.active = true
  order by t.level asc
  limit 1;

  if not found then
    return new;
  end if;

  -- Create subscription with tier only
  insert into billing.subscriptions (organization_id, tier_id)
  values (new.id, _tier_id);

  -- Assign default plan if one exists
  select * into _plan
  from billing.plans p
  where p.is_default = true
    and p.active = true
  limit 1;

  if not found then
    return new;
  end if;

  -- Find the matching tier for this plan's min_tier level
  select t.id into _tier_id
  from billing.tiers t
  where t.level >= _plan.min_tier
    and t.active = true
  order by t.level asc
  limit 1;

  if _tier_id is null then
    raise exception 'No active tier found for plan %', _plan.id;
  end if;

  update billing.subscriptions
  set tier_id = _tier_id,
      plan_id = _plan.id,
      current_period_start = _start,
      current_period_end = _start + billing.plan_period(_plan.billing_cycle)
  where organization_id = new.id;

  perform billing.grant_included_products(new.id, _plan.id, _start);

  return new;
end;
$$;

-- F17. The renewal, run by pg_cron (`renew-subscriptions`, every 5 minutes).
--
-- Takes up to _batch subscriptions whose period has ended, FOR UPDATE SKIP
-- LOCKED (two overlapping runs never take the same row), skipping plan-less
-- ones, canceled ones and organizations being deleted. For each:
--
--   1. The period advances to the one containing now(): if the cron was down
--      for several periods they are skipped, not granted.
--   2. Included credits do not accumulate. What is left of the included
--      amount granted in the closing period expires (a negative
--      `expiration` entry): included credits are spent first, so the
--      remainder is the grants since the period started minus the
--      consumption since then, never more than the balance. Top-ups beyond
--      that are untouched.
--   3. The plan's included amount is granted for the new period.
--
-- Expirations and grants are keyed by period_start (ledger_period_entry_key),
-- so a repeated run cannot write them twice. Returns the subscriptions
-- renewed. Month arithmetic clamps to the month's last day: a period
-- anchored on the 31st moves to the 28th after February.
create function billing.renew_subscriptions(_batch integer default 500) returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  _sub record;
  _step interval;
  _start timestamp with time zone;
  _end timestamp with time zone;
  _pp record;
  _granted numeric;
  _consumed numeric;
  _balance numeric;
  _expire numeric;
  _count integer := 0;
begin
  for _sub in
    select s.organization_id, s.plan_id, s.current_period_start, s.current_period_end,
           p.billing_cycle
    from billing.subscriptions s
    join billing.plans p on p.id = s.plan_id
    join public.organizations o on o.id = s.organization_id
    where s.current_period_end <= now()
      and (s.canceled_at is null or s.canceled_at > s.current_period_end)
      and o.deletion_requested_at is null
    order by s.current_period_end
    limit _batch
    for update of s skip locked
  loop
    _step := billing.plan_period(_sub.billing_cycle);
    _start := _sub.current_period_end;
    _end := _start + _step;
    while _end <= now() loop
      _start := _end;
      _end := _start + _step;
    end loop;

    for _pp in
      select pp.product_id
      from billing.plans_products pp
      join billing.products p on p.id = pp.product_id
      where pp.plan_id = _sub.plan_id
        and p.kind = 'balance'
        and pp.included is not null
        and pp.included > 0
    loop
      select
        coalesce(sum(l.quantity) filter (where l.type = 'grant'), 0),
        coalesce(-sum(l.quantity) filter (
          where l.type = 'consumption' and l.billable is distinct from false
        ), 0)
      into _granted, _consumed
      from billing.ledger l
      where l.organization_id = _sub.organization_id
        and l.product_id = _pp.product_id
        and l.created_at >= coalesce(_sub.current_period_start, '-infinity');

      select u.quantity into _balance
      from billing.usage u
      where u.organization_id = _sub.organization_id
        and u.product_id = _pp.product_id
        and u.interval = 'lifetime'
        and u.period = '1970-01-01';

      _expire := greatest(0, least(_granted - _consumed, coalesce(_balance, 0)));

      if _expire > 0 then
        insert into billing.ledger (
          organization_id, product_id, type, quantity, period_start, metadata
        ) values (
          _sub.organization_id, _pp.product_id, 'expiration', -_expire, _start,
          jsonb_build_object('expired_period_start', _sub.current_period_start)
        )
        on conflict (organization_id, product_id, type, period_start) do nothing;
      end if;
    end loop;

    perform billing.grant_included_products(_sub.organization_id, _sub.plan_id, _start);

    update billing.subscriptions
    set current_period_start = _start,
        current_period_end = _end
    where organization_id = _sub.organization_id;

    _count := _count + 1;
  end loop;

  return _count;
end;
$$;

