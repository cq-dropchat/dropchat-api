-- F17 — billing periods never renewed.
--
-- Failure scenario: billing.initialize_subscription() grants the plan's
-- included balance products (AI credits) once, when the organization is
-- created, and sets current_period_start. Nothing ever set
-- current_period_end, rotated the period or granted again: once the included
-- credits were spent they never came back.
--
-- Now: billing.renew_subscriptions(batch), every 5 minutes by pg_cron, takes
-- the due subscriptions (current_period_end <= now()) with SKIP LOCKED,
-- advances them to the current period (catching up missed ones without
-- granting for them), expires what is left of the previous period's included
-- credits (top-ups are kept) and grants the plan's included amount again,
-- keyed by (organization, product, type, period_start).
begin;
select plan(30);

-- Balance of a product, as check_limit reads it.
create function pg_temp.balance(_org uuid) returns numeric language sql as $$
  select coalesce((
    select u.quantity from billing.usage u
    where u.organization_id = _org and u.product_id = 'ai_credits'
      and u.interval = 'lifetime' and u.period = '1970-01-01'
  ), 0);
$$;

create function pg_temp.entries(_org uuid, _type text) returns bigint language sql as $$
  select count(*) from billing.ledger l
  where l.organization_id = _org and l.product_id = 'ai_credits' and l.type = _type;
$$;

-- Fresh organizations: initialize_subscription gives each the free plan and
-- its $1 of AI credits.
insert into public.organizations (id, name) values
  ('f17f17f1-0000-4000-8000-000000000001', 'F17 due'),
  ('f17f17f1-0000-4000-8000-000000000002', 'F17 topup'),
  ('f17f17f1-0000-4000-8000-000000000003', 'F17 cron down'),
  ('f17f17f1-0000-4000-8000-000000000004', 'F17 canceled'),
  ('f17f17f1-0000-4000-8000-000000000005', 'F17 not due'),
  ('f17f17f1-0000-4000-8000-000000000006', 'F17 overspent');

-- ---------------------------------------------------------------------------
-- A new subscription has a whole period.
-- ---------------------------------------------------------------------------

select is(
  (select current_period_start + interval '1 month' = current_period_end from billing.subscriptions
   where organization_id = 'f17f17f1-0000-4000-8000-000000000001'),
  true,
  'initialize_subscription sets current_period_end one cycle after the start (free plan: monthly)'
);

select is(
  (select period_start = s.current_period_start
   from billing.ledger l join billing.subscriptions s using (organization_id)
   where l.organization_id = 'f17f17f1-0000-4000-8000-000000000001' and l.type = 'grant'),
  true,
  'the initial grant is keyed by its period'
);

-- ---------------------------------------------------------------------------
-- Put each subscription where the case needs it. The ledger's created_at
-- places consumption inside the period being closed.
-- ---------------------------------------------------------------------------

update billing.subscriptions
set current_period_start = now() - interval '40 days',
    current_period_end = now() - interval '10 days'
where organization_id in (
  'f17f17f1-0000-4000-8000-000000000001',
  'f17f17f1-0000-4000-8000-000000000002',
  'f17f17f1-0000-4000-8000-000000000004',
  'f17f17f1-0000-4000-8000-000000000006'
);
update billing.ledger set created_at = now() - interval '40 days'
where organization_id::text like 'f17f17f1-%';

-- 1: spent 30¢ of the included dollar.
insert into billing.ledger (organization_id, product_id, type, quantity, created_at) values
  ('f17f17f1-0000-4000-8000-000000000001', 'ai_credits', 'consumption', -0.30, now() - interval '20 days');

-- 2: the same, plus $5 bought.
insert into billing.ledger (organization_id, product_id, type, quantity, created_at) values
  ('f17f17f1-0000-4000-8000-000000000002', 'ai_credits', 'consumption', -0.30, now() - interval '20 days'),
  ('f17f17f1-0000-4000-8000-000000000002', 'ai_credits', 'topup', 5.00, now() - interval '15 days');

-- 6: spent $1.50 (50¢ out of a $2 top-up).
insert into billing.ledger (organization_id, product_id, type, quantity, created_at) values
  ('f17f17f1-0000-4000-8000-000000000006', 'ai_credits', 'topup', 2.00, now() - interval '30 days'),
  ('f17f17f1-0000-4000-8000-000000000006', 'ai_credits', 'consumption', -1.50, now() - interval '20 days');

-- 3: the cron was down for three periods.
update billing.subscriptions
set current_period_start = now() - interval '100 days',
    current_period_end = now() - interval '70 days'
where organization_id = 'f17f17f1-0000-4000-8000-000000000003';

-- 4: canceled at the end of the period that just closed.
update billing.subscriptions
set canceled_at = current_period_end
where organization_id = 'f17f17f1-0000-4000-8000-000000000004';

-- 5: not due (its period runs for another month).

create temp table before_run as
select organization_id, current_period_start, current_period_end
from billing.subscriptions where organization_id::text like 'f17f17f1-%';

select has_function('billing', 'renew_subscriptions', array['integer'], 'renew_subscriptions exists');

-- Other due subscriptions in the database are renewed too; the assertions
-- below only look at the F17 organizations.

select ok(
  billing.renew_subscriptions(1000) >= 4,
  'one run renews every due subscription it can lock'
);

-- ---------------------------------------------------------------------------
-- 1: exactly one period forward, one grant, the unspent included credits
-- expired.
-- ---------------------------------------------------------------------------

select is(
  (select s.current_period_start = b.current_period_end
   from billing.subscriptions s join before_run b using (organization_id)
   where organization_id = 'f17f17f1-0000-4000-8000-000000000001'),
  true,
  'the new period starts where the old one ended'
);
select is(
  (select current_period_start + interval '1 month' = current_period_end from billing.subscriptions
   where organization_id = 'f17f17f1-0000-4000-8000-000000000001'),
  true,
  'and lasts one cycle'
);
select ok(
  (select current_period_end > now() from billing.subscriptions
   where organization_id = 'f17f17f1-0000-4000-8000-000000000001'),
  'the renewed period is the current one'
);
select is(pg_temp.entries('f17f17f1-0000-4000-8000-000000000001', 'grant'), 2::bigint,
  'one new grant (plus the initial one)');
select is(
  (select quantity from billing.ledger
   where organization_id = 'f17f17f1-0000-4000-8000-000000000001' and type = 'expiration'),
  -0.70,
  'the unspent 70¢ of the included dollar expire'
);
select is(pg_temp.balance('f17f17f1-0000-4000-8000-000000000001'), 1.00,
  'included credits do not accumulate: the balance is the included amount');
select is(
  (select l.period_start = s.current_period_start
   from billing.ledger l join billing.subscriptions s using (organization_id)
   where l.organization_id = 'f17f17f1-0000-4000-8000-000000000001'
     and l.type = 'grant' order by l.created_at desc limit 1),
  true,
  'the grant is keyed by the new period'
);

-- ---------------------------------------------------------------------------
-- 2: top-ups are kept.
-- ---------------------------------------------------------------------------

select is(pg_temp.balance('f17f17f1-0000-4000-8000-000000000002'), 6.00,
  'bought credits survive the renewal ($5 bought + $1 included)');
select is(
  (select quantity from billing.ledger
   where organization_id = 'f17f17f1-0000-4000-8000-000000000002' and type = 'expiration'),
  -0.70,
  'only the included remainder expires'
);

-- 6: nothing included is left to expire.
select is(pg_temp.entries('f17f17f1-0000-4000-8000-000000000006', 'expiration'), 0::bigint,
  'when the included credits were spent, nothing expires');
select is(pg_temp.balance('f17f17f1-0000-4000-8000-000000000006'), 2.50,
  'the rest of the top-up stays and the included dollar is added');

-- ---------------------------------------------------------------------------
-- 3: catching up after downtime grants for the current period only.
-- ---------------------------------------------------------------------------

select ok(
  (select current_period_start <= now() and current_period_end > now()
   from billing.subscriptions where organization_id = 'f17f17f1-0000-4000-8000-000000000003'),
  'a subscription three periods behind lands on the current period'
);
select is(
  (select (select current_period_end from before_run
     where organization_id = 'f17f17f1-0000-4000-8000-000000000003') + interval '2 months' = current_period_start
   from billing.subscriptions where organization_id = 'f17f17f1-0000-4000-8000-000000000003'),
  true,
  'having skipped the two periods it missed'
);
select is(pg_temp.entries('f17f17f1-0000-4000-8000-000000000003', 'grant'), 2::bigint,
  'with a single grant (plus the initial one), not one per missed period');

-- ---------------------------------------------------------------------------
-- 4, 5: canceled and not-yet-due subscriptions are left alone.
-- ---------------------------------------------------------------------------

select is(
  (select (s.current_period_start, s.current_period_end) = (b.current_period_start, b.current_period_end)
   from billing.subscriptions s join before_run b using (organization_id)
   where organization_id = 'f17f17f1-0000-4000-8000-000000000004'),
  true,
  'a canceled subscription is not renewed'
);
select is(pg_temp.entries('f17f17f1-0000-4000-8000-000000000004', 'grant'), 1::bigint,
  'and receives no grant');
select is(
  (select (s.current_period_start, s.current_period_end) = (b.current_period_start, b.current_period_end)
   from billing.subscriptions s join before_run b using (organization_id)
   where organization_id = 'f17f17f1-0000-4000-8000-000000000005'),
  true,
  'a subscription whose period has not ended is not touched'
);

-- ---------------------------------------------------------------------------
-- Idempotency.
-- ---------------------------------------------------------------------------

select is(billing.renew_subscriptions(1000), 0, 'a second run finds nothing due');
select is(pg_temp.entries('f17f17f1-0000-4000-8000-000000000001', 'grant'), 2::bigint,
  'and grants nothing again');

select throws_ok(
  $$ insert into billing.ledger (organization_id, product_id, type, quantity, period_start)
     select organization_id, 'ai_credits', 'grant', 1, current_period_start
     from billing.subscriptions where organization_id = 'f17f17f1-0000-4000-8000-000000000001' $$,
  '23505', null,
  'the ledger refuses a second grant for the same period'
);

-- ---------------------------------------------------------------------------
-- Scheduled, and service only.
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int from cron.job
   where jobname = 'renew-subscriptions' and schedule = '*/5 * * * *'),
  1,
  'renew-subscriptions runs every 5 minutes'
);

create function pg_temp.refused(_who text) returns setof text language plpgsql as $$
begin
  return next throws_ok(
    $q$ select billing.renew_subscriptions(10) $q$,
    '42501', null, _who || ' cannot run the renewal'
  );
end;
$$;

select tests.authenticate_as('alice@test.local');
select pg_temp.refused('user A');
select tests.clear_authentication();

select tests.authenticate_as('bob@test.local');
select pg_temp.refused('user B');
select tests.clear_authentication();

select tests.authenticate_with_api_key('test-key-a-owner-0000000000000000000');
select pg_temp.refused('API key A');
select tests.clear_authentication();

select tests.authenticate_with_api_key('test-key-b-member-000000000000000000');
select pg_temp.refused('API key B');
select tests.clear_authentication();

select tests.authenticate_as_anon();
select pg_temp.refused('anon');
select tests.clear_authentication();

select * from finish();
rollback;
