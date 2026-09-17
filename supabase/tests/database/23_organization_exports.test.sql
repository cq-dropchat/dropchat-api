-- F18 — export an organization's data.
--
-- Failure scenario: an owner had no way to take their organization's data
-- out (conversations, messages, contacts, agents, webhooks, logs) other than
-- paging through the REST API table by table.
--
-- Now: request_organization_export(org), owners only, files one export at a
-- time per organization; the org-export worker (pg_cron → Edge Function)
-- claims it, writes a ZIP to the private `exports` bucket under the
-- organization's path, and marks it ready for 7 days; owners download it with
-- a signed URL. Deleting the organization or one of its accounts expires its
-- exports at once.
begin;
select plan(32);

create temp table marks as
select (select coalesce(max(id), 0) from net.http_request_queue) as queue_id;

select has_table('public', 'organization_exports', 'organization_exports exists');
select has_function('public', 'request_organization_export', array['uuid'], 'request_organization_export exists');
select is(
  (select public from storage.buckets where id = 'exports'),
  false,
  'the exports bucket exists and is private'
);

-- ---------------------------------------------------------------------------
-- Who may request.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('alice@test.local');
create temp table first_export as
select public.request_organization_export(tests.id('org_a')) as id;
grant select on first_export to anon, authenticated;

select is(
  (select status from public.organization_exports where id = (select id from first_export)),
  'pending',
  'the owner of A files an export of A'
);
select is(
  (select requested_by from public.organization_exports where id = (select id from first_export)),
  tests.id('user_alice'),
  'recording who asked'
);
select is(
  public.request_organization_export(tests.id('org_a')),
  (select id from first_export),
  'asking again while one is pending returns the pending export'
);
select throws_ok(
  $$ insert into public.organization_exports (organization_id) values (tests.id('org_a')) $$,
  '42501', null,
  'an owner cannot write the table directly'
);
select tests.clear_authentication();
select is(
  (select count(*)::int from net.http_request_queue q
   where q.id > (select queue_id from marks) and q.url like '%/org-export'),
  1,
  'the request wakes the org-export worker once'
);

select tests.authenticate_as('amber@test.local');
select throws_ok(
  $$ select public.request_organization_export(tests.id('org_a')) $$,
  '42501', null, 'a member cannot export'
);
select is((select count(*)::int from public.organization_exports), 0, 'a member sees no exports');
select tests.clear_authentication();

update public.agents set role = 'admin' where id = tests.id('agent_amber');
select tests.authenticate_as('amber@test.local');
select throws_ok(
  $$ select public.request_organization_export(tests.id('org_a')) $$,
  '42501', null, 'an admin cannot export'
);
select tests.clear_authentication();

select tests.authenticate_as('bob@test.local');
select throws_ok(
  $$ select public.request_organization_export(tests.id('org_a')) $$,
  '42501', null, 'the owner of B cannot export A'
);
select is((select count(*)::int from public.organization_exports), 0, 'user B sees none of A''s exports');
select tests.clear_authentication();

select tests.authenticate_with_api_key('test-key-a-member-000000000000000000');
select throws_ok(
  $$ select public.request_organization_export(tests.id('org_a')) $$,
  '42501', null, 'a member API key of A cannot export'
);
select tests.clear_authentication();

select tests.authenticate_with_api_key('test-key-a-owner-0000000000000000000');
select is(
  public.request_organization_export(tests.id('org_a')),
  (select id from first_export),
  'an owner API key of A may (the org-delete rule), and gets the pending export'
);
select tests.clear_authentication();

select tests.authenticate_with_api_key('test-key-b-member-000000000000000000');
select throws_ok(
  $$ select public.request_organization_export(tests.id('org_a')) $$,
  '42501', null, 'API key B cannot export A'
);
select tests.clear_authentication();

select tests.authenticate_as_anon();
select throws_ok(
  $$ select public.request_organization_export(tests.id('org_a')) $$,
  '42501', null, 'anon cannot export'
);
select tests.clear_authentication();

-- ---------------------------------------------------------------------------
-- The worker's lifecycle.
-- ---------------------------------------------------------------------------

select is(
  (select id from public.claim_organization_export()),
  (select id from first_export),
  'the worker claims the pending export'
);
select is(
  (select count(*)::int from public.claim_organization_export()),
  0,
  'a second worker finds nothing to claim'
);

select tests.authenticate_as('alice@test.local');
select is(
  public.request_organization_export(tests.id('org_a')),
  (select id from first_export),
  'while it is processing, a new request returns it'
);
select tests.clear_authentication();

select public.finish_organization_export(
  (select id from first_export),
  'organizations/aaaaaaaa-0000-4000-8000-000000000001/exports/' || (select id from first_export) || '.zip',
  null
);
select ok(
  (select status = 'ready' and expires_at between now() + interval '7 days' - interval '1 minute'
                                              and now() + interval '7 days' + interval '1 minute'
   from public.organization_exports where id = (select id from first_export)),
  'a finished export is ready for 7 days'
);

-- The file, as the worker uploads it. It is the platform's, not an
-- attachment: it does not count against the organization's storage.
create temp table storage_before as
select coalesce((select quantity from billing.usage
  where organization_id = tests.id('org_a') and product_id = 'storage' and interval = 'lifetime'), 0) as q;

insert into storage.objects (bucket_id, name, metadata)
select 'exports', object_name, '{"size": 5000000000, "mimetype": "application/zip"}'
from public.organization_exports where id = (select id from first_export);

select is(
  coalesce((select quantity from billing.usage
    where organization_id = tests.id('org_a') and product_id = 'storage' and interval = 'lifetime'), 0),
  (select q from storage_before),
  'an export file (5 GB, over the free cap) neither counts nor is refused by the storage cap'
);

select tests.authenticate_as('alice@test.local');
select is(
  (select count(*)::int from storage.objects where bucket_id = 'exports'),
  1,
  'the owner can read the file (and so sign a download URL)'
);
select isnt(
  public.request_organization_export(tests.id('org_a')),
  (select id from first_export),
  'once it is ready, a new request files a new export'
);
select tests.clear_authentication();

select tests.authenticate_as('amber@test.local');
select is(
  (select count(*)::int from storage.objects where bucket_id = 'exports'),
  0,
  'a non-owner member cannot'
);
select tests.clear_authentication();

select tests.authenticate_as('bob@test.local');
select is(
  (select count(*)::int from storage.objects where bucket_id = 'exports'),
  0,
  'nor can user B'
);
select tests.clear_authentication();

-- Expiry.
update public.organization_exports set expires_at = now() - interval '1 second'
where id = (select id from first_export);

select is(
  (select id from public.expired_organization_exports(10)),
  (select id from first_export),
  'an export past its expiry is handed to the worker'
);

select public.mark_organization_export_expired((select id from first_export));
select ok(
  (select status = 'expired' and object_name is null
   from public.organization_exports where id = (select id from first_export)),
  'once its file is removed it is marked expired'
);

update public.organization_exports set completed_at = now() - interval '8 days'
where id = (select id from first_export);
select ok(
  (public.purge_expired_rows(100) ->> 'organization_exports')::int >= 1,
  'purge_expired_rows deletes expired exports a week after they finished'
);

-- A deletion expires the organization's ready exports at once.
select public.finish_organization_export(e.id, 'organizations/aaaaaaaa-0000-4000-8000-000000000001/exports/second.zip', null)
from public.claim_organization_export() e;

select public.request_address_deletion(tests.id('org_a'), 'whatsapp', tests.val('wa_a'), 'meta_data_deletion');
select public.sweep_deletions(1);
select ok(
  (select bool_and(expires_at <= now()) from public.organization_exports
   where organization_id = tests.id('org_a') and status = 'ready'),
  'deleting an account expires the organization''s ready exports'
);

-- ---------------------------------------------------------------------------
-- Worker functions: service only.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('alice@test.local');
select throws_ok(
  $$ select * from public.claim_organization_export() $$,
  '42501', null, 'an owner cannot claim exports'
);
select tests.clear_authentication();

select tests.authenticate_as_anon();
select throws_ok(
  $$ select * from public.expired_organization_exports(10) $$,
  '42501', null, 'anon cannot list exports'
);
select tests.clear_authentication();

select * from finish();
rollback;
