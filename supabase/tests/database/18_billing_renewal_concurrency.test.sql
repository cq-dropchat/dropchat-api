-- F17 — renew_subscriptions under concurrency: two sessions (two overlapping
-- cron runs, or a slow run and the next one) must not renew the same
-- subscription twice. The rows are taken FOR UPDATE SKIP LOCKED.
--
-- A second session is opened with dblink. It can only see committed rows, so
-- this file commits its setup through dblink (an organization of its own)
-- and deletes it at the end; everything else runs in this transaction.
begin;
select plan(5);

create extension if not exists dblink;
set local lock_timeout = '5s';

-- dblink refuses a connection that did not authenticate with a password
-- unless the caller is a superuser, and loopback connections are `trust` in
-- the Supabase image: connect through the container's own network address
-- (scram), the one this session came in on.
create temp table peer as
select format(
  'host=%s port=%s dbname=%s user=postgres password=postgres',
  host(inet_server_addr()), inet_server_port(), current_database()
) as conninfo;

select dblink_connect('f17_setup', (select conninfo from peer));
select dblink_connect('f17_other', (select conninfo from peer));

-- Committed: an organization whose period ended yesterday (after removing
-- one an aborted run may have left).
select dblink_exec('f17_setup', $$
  set app.deletion_sweep = 'on';
  delete from public.organizations where id = 'f17f17f1-0000-4000-8000-0000000000cc';
  reset app.deletion_sweep;
  insert into public.organizations (id, name)
  values ('f17f17f1-0000-4000-8000-0000000000cc', 'F17 concurrency');
  update billing.subscriptions
  set current_period_start = now() - interval '1 month 1 day',
      current_period_end = now() - interval '1 day'
  where organization_id = 'f17f17f1-0000-4000-8000-0000000000cc';
$$);

-- The other session renews inside a transaction it keeps open: it holds the
-- row lock.
select dblink_exec('f17_other', 'begin');
select is(
  (select n from dblink('f17_other', 'select billing.renew_subscriptions(1000)') as t(n int)) >= 1,
  true,
  'the other session renews the due subscription and keeps its lock'
);

-- This session runs meanwhile: it neither waits (lock_timeout would raise)
-- nor renews the locked row.
select lives_ok(
  $$ select billing.renew_subscriptions(1000) $$,
  'a concurrent run does not block on the locked row'
);
select is(
  (select count(*)::int from billing.ledger
   where organization_id = 'f17f17f1-0000-4000-8000-0000000000cc' and type = 'grant'),
  1,
  'and grants nothing for it (only the initial grant is visible here)'
);

select dblink_exec('f17_other', 'commit');

select is(
  (select n from dblink('f17_setup', $$
     select count(*)::int from billing.ledger
     where organization_id = 'f17f17f1-0000-4000-8000-0000000000cc' and type = 'grant'
   $$) as t(n int)),
  2,
  'after both sessions: the initial grant and exactly one renewal grant'
);

select is(
  (select n from dblink('f17_setup', 'select billing.renew_subscriptions(1000)') as t(n int)),
  0,
  'a later run finds nothing due'
);

-- The F18 trigger turns an organization DELETE into a deletion request
-- unless the sweep is deleting.
select dblink_exec('f17_setup', $$
  set app.deletion_sweep = 'on';
  delete from public.organizations where id = 'f17f17f1-0000-4000-8000-0000000000cc';
  reset app.deletion_sweep;
$$);
select dblink_disconnect('f17_setup');
select dblink_disconnect('f17_other');

select * from finish();
rollback;
