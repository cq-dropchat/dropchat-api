-- F18 — deletions: mark, then sweep in batches.
--
-- Failure scenarios:
-- 1. Instagram's data-deletion callback deleted organizations_addresses by
--    `address` and `service` alone: two organizations that had connected
--    the same account (the second takes the connection over; the first row
--    stays) both lost the account and, by cascade, every conversation and
--    message on it.
-- 2. Every deletion — an owner deleting the organization, the callback
--    deleting an account — ran the whole cascade (15 tables, all messages)
--    in the caller's single transaction: one long lock on a large tenant,
--    inside an HTTP request.
--
-- Now a deletion is a request (public.deletion_requests) that takes effect
-- for readers at once and is swept by pg_cron in bounded batches, scoped to
-- one organization.
begin;
select plan(34);

select has_table('public', 'deletion_requests', 'deletion_requests exists');
select has_column('public', 'organizations', 'deletion_requested_at', 'organizations can be marked');

-- The same Instagram account connected in both organizations, each with a
-- conversation and a message on it.
insert into public.organizations_addresses (organization_id, service, address, status, created_at) values
  (tests.id('org_a'), 'instagram', '17840000000000001', 'disconnected', now() - interval '2 days'),
  (tests.id('org_b'), 'instagram', '17840000000000001', 'connected', now() - interval '1 day');

insert into public.messages (organization_id, service, organization_address, conversation_address, sender_address, content, status) values
  (tests.id('org_a'), 'instagram', '17840000000000001', '9990000000001', '9990000000001',
   '{"version": "1", "type": "text", "kind": "text", "text": "A on IG"}', '{"delivered": "2026-09-10T10:00:00Z"}'),
  (tests.id('org_b'), 'instagram', '17840000000000001', '9990000000001', '9990000000001',
   '{"version": "1", "type": "text", "kind": "text", "text": "B on IG"}', '{"delivered": "2026-09-10T10:00:00Z"}');

create temp table counts as
select
  (select count(*) from public.messages where organization_id = tests.id('org_a')) as a_messages,
  (select count(*) from public.messages where organization_id = tests.id('org_b')) as b_messages,
  (select count(*) from public.conversations where organization_id = tests.id('org_b')) as b_conversations;
grant select on counts to anon, authenticated;

-- A sweep with no requests does nothing.
select is(public.sweep_deletions(), '{"request": null}'::jsonb, 'nothing to sweep');

-- ---------------------------------------------------------------------------
-- Account scope: one organization's account, not every organization's.
-- ---------------------------------------------------------------------------

select ok(
  public.request_address_deletion(tests.id('org_b'), 'instagram', '17840000000000001', 'meta_data_deletion') is not null,
  'an account deletion request returns its id (the confirmation code)'
);

select is(
  (select status from public.organizations_addresses
   where organization_id = tests.id('org_b') and service = 'instagram'),
  'deleting',
  'the account stops being connected at once'
);

select is(
  public.request_address_deletion(tests.id('org_b'), 'instagram', '17840000000000001', 'meta_data_deletion'),
  (select id from public.deletion_requests where organization_id = tests.id('org_b')),
  'a repeated request returns the pending one'
);

-- Swept to completion (a small budget: several runs).
do $$
begin
  for i in 1..20 loop
    exit when (select completed_at is not null from public.deletion_requests where organization_id = tests.id('org_b'));
    perform public.sweep_deletions(1);
  end loop;
end;
$$;

select ok(
  (select completed_at is not null from public.deletion_requests where organization_id = tests.id('org_b')),
  'the account request completes'
);
select is(
  (select count(*)::int from public.organizations_addresses where organization_id = tests.id('org_b') and service = 'instagram'),
  0,
  'org B''s Instagram account is gone'
);
select is(
  (select count(*)::int from public.messages where organization_id = tests.id('org_b') and service = 'instagram'),
  0,
  'with its messages'
);
select is(
  (select count(*)::int from public.messages where organization_id = tests.id('org_b')),
  (select b_messages::int - 1 from counts),
  'and only those: org B''s WhatsApp history stays'
);
select is(
  (select count(*)::int from public.organizations_addresses where organization_id = tests.id('org_a') and service = 'instagram'),
  1,
  'org A''s connection of the same account is untouched'
);
select is(
  (select count(*)::int from public.messages where organization_id = tests.id('org_a') and service = 'instagram'),
  1,
  'as are org A''s messages on it'
);

-- ---------------------------------------------------------------------------
-- Organization scope: the owner's delete becomes a mark.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('amber@test.local');
delete from public.organizations where id = tests.id('org_a');
select tests.clear_authentication();

select is(
  (select count(*)::int from public.deletion_requests where organization_id = tests.id('org_a')),
  0,
  'a member cannot request the organization''s deletion'
);

select tests.authenticate_as('alice@test.local');
delete from public.organizations where id = tests.id('org_a');
select tests.clear_authentication();

select ok(
  (select deletion_requested_at is not null from public.organizations where id = tests.id('org_a')),
  'the owner''s delete marks the organization instead of deleting it'
);
select is(
  (select count(*)::int from public.deletion_requests where organization_id = tests.id('org_a') and completed_at is null and source = 'owner'),
  1,
  'and files one request'
);
select is(
  (select count(*)::int from public.messages where organization_id = tests.id('org_a')),
  (select a_messages::int from counts),
  'nothing is deleted in the owner''s transaction'
);

-- Gone for every reader at once.
select tests.authenticate_as('alice@test.local');
select is((select count(*)::int from public.organizations where id = tests.id('org_a')), 0, 'the owner no longer sees the organization');
select is((select count(*)::int from public.conversations where organization_id = tests.id('org_a')), 0, 'nor its conversations');
select is((select count(*)::int from public.messages where organization_id = tests.id('org_a')), 0, 'nor its messages');
-- A second delete from the UI is a no-op, not a second request.
delete from public.organizations where id = tests.id('org_a');
select tests.clear_authentication();

select tests.authenticate_as('amber@test.local');
select is((select count(*)::int from public.contacts_addresses where organization_id = tests.id('org_a')), 0, 'a member no longer sees its contacts');
select tests.clear_authentication();

select tests.authenticate_with_api_key('test-key-a-owner-0000000000000000000');
select is((select count(*)::int from public.messages), 0, 'its API keys no longer read anything');
select tests.clear_authentication();

select tests.authenticate_as('bob@test.local');
select is(
  (select count(*)::int from public.conversations where organization_id = tests.id('org_b')),
  (select b_conversations::int - 1 from counts),
  'user B still sees org B (minus the deleted Instagram conversation)'
);
select tests.clear_authentication();

select tests.authenticate_with_api_key('test-key-b-member-000000000000000000');
select ok((select count(*) > 0 from public.messages), 'API key B still reads org B');
select tests.clear_authentication();

select is(
  (select count(*)::int from public.deletion_requests where organization_id = tests.id('org_a')),
  1,
  'a repeated delete does not file a second request'
);

-- A bounded sweep leaves the organization in place until its data is gone.
select public.sweep_deletions(2);

select ok(
  (select count(*) from public.messages where organization_id = tests.id('org_a')) between 1 and (select a_messages - 2 from counts),
  'one sweep deletes at most its budget'
);
select is(
  (select count(*)::int from public.organizations where id = tests.id('org_a')),
  1,
  'the organization row outlives its data'
);

do $$
begin
  for i in 1..50 loop
    exit when (select completed_at is not null from public.deletion_requests where organization_id = tests.id('org_a'));
    perform public.sweep_deletions(2);
  end loop;
end;
$$;

select ok(
  (select completed_at is not null from public.deletion_requests where organization_id = tests.id('org_a')),
  'the organization request completes'
);
select is((select count(*)::int from public.organizations where id = tests.id('org_a')), 0, 'the organization is gone');
select is(
  (select count(*)::int from public.messages where organization_id = tests.id('org_a'))
  + (select count(*)::int from public.conversations where organization_id = tests.id('org_a'))
  + (select count(*)::int from public.contacts_addresses where organization_id = tests.id('org_a'))
  + (select count(*)::int from public.agents where organization_id = tests.id('org_a')),
  0,
  'with everything in it'
);
select ok(
  (select deleted_rows >= (select a_messages from counts) from public.deletion_requests where organization_id = tests.id('org_a')),
  'the request records what it deleted'
);
select is(
  (select count(*)::int from public.organizations where id = tests.id('org_b')),
  1,
  'org B is untouched'
);

-- ---------------------------------------------------------------------------
-- Service role only.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('bob@test.local');
select throws_ok(
  $$ select count(*) from public.deletion_requests $$,
  '42501', null, 'user B cannot read deletion requests'
);
select throws_ok(
  $$ select public.request_address_deletion(tests.id('org_b'), 'whatsapp', tests.val('wa_b'), 'owner') $$,
  '42501', null, 'user B cannot request an account deletion directly'
);
select tests.clear_authentication();

select tests.authenticate_as_anon();
select throws_ok(
  $$ select public.sweep_deletions() $$,
  '42501', null, 'anon cannot run the sweep'
);
select tests.clear_authentication();

select * from finish();
rollback;
