alter table "billing"."ledger" drop constraint "ledger_type_check";

alter table "billing"."ledger" add column "period_start" timestamp with time zone;

alter table "billing"."subscriptions" add column "canceled_at" timestamp with time zone;

-- CONCURRENTLY by hand: the ledger gets a row per AI call.
CREATE UNIQUE INDEX CONCURRENTLY ledger_period_entry_key ON billing.ledger USING btree (organization_id, product_id, type, period_start);

alter table "billing"."ledger" add constraint "ledger_type_check" CHECK ((type = ANY (ARRAY['grant'::text, 'consumption'::text, 'topup'::text, 'expiration'::text]))) not valid;

alter table "billing"."ledger" validate constraint "ledger_type_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION billing.grant_included_products(_organization_id uuid, _plan_id text, _period_start timestamp with time zone)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION billing.plan_period(_billing_cycle text)
 RETURNS interval
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case _billing_cycle when 'year' then interval '1 year' else interval '1 month' end;
$function$
;

CREATE OR REPLACE FUNCTION billing.renew_subscriptions(_batch integer DEFAULT 500)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION billing.initialize_subscription()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;



-- ---------------------------------------------------------------------------
-- Hand-written: privileges, backfill and schedule (db diff models none).
-- ---------------------------------------------------------------------------

-- 06-40: a billing function is born executable by PUBLIC. The renewal and
-- the grant helper run only from pg_cron and the organization trigger.
revoke execute on function billing.plan_period(text) from public, anon, authenticated;
grant execute on function billing.plan_period(text) to service_role;
revoke execute on function billing.grant_included_products(uuid, text, timestamp with time zone) from public, anon, authenticated, service_role;
revoke execute on function billing.renew_subscriptions(integer) from public, anon, authenticated, service_role;

-- Subscriptions created before this migration have a start and no end. Their
-- first period ends one cycle after it started; those already past it are
-- renewed by the first run (once, to the current period).
update billing.subscriptions s
set current_period_end = s.current_period_start + billing.plan_period(p.billing_cycle)
from billing.plans p
where p.id = s.plan_id
  and s.current_period_end is null
  and s.current_period_start is not null;

select cron.schedule(
  'renew-subscriptions',
  '*/5 * * * *',
  $$ select billing.renew_subscriptions(500) $$
);
