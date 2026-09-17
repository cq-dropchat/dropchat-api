-- F03 — `external_id` is unique across the whole table, not per tenant.
--
-- Failure scenario: org A and org B both hold a whatsapp-web session for the
-- same number (allowed by design). The same message arrives through both
-- with the same id; B's upsert collides with A's row on
-- messages_external_id_key and merges into it — B never gets a row, never
-- wakes its agent, never fires its webhooks. Every edit/revoke keyed by
-- external_id lands on A's row whichever session it came through.
begin;
select plan(8);

-- ---------------------------------------------------------------------------
-- Schema: the key is (organization_id, external_id).
-- ---------------------------------------------------------------------------

-- The constraint's index goes with it.
select hasnt_index(
  'public', 'messages', 'messages_external_id_key',
  'the global unique constraint on external_id is gone'
);

select has_index(
  'public', 'messages', 'messages_org_external_id_key',
  array['organization_id', 'external_id'],
  'messages has an index on (organization_id, external_id)'
);

select index_is_unique(
  'public', 'messages', 'messages_org_external_id_key',
  'and it is unique'
);

-- ---------------------------------------------------------------------------
-- Two tenants, one external id: two rows.
-- ---------------------------------------------------------------------------

insert into public.messages (
  organization_id, service, organization_address, conversation_address,
  sender_address, external_id, content, status, timestamp
) values (
  tests.id('org_a'), 'whatsapp', tests.val('wa_a'), tests.val('contact_a1'),
  tests.val('contact_a1'), '3EB0SHARED1',
  '{"version": "1", "type": "text", "kind": "text", "text": "from A''s session"}',
  '{"delivered": "2026-09-10T10:00:00Z"}', '2026-09-10T10:00:00Z'
);

select lives_ok(
  $$
  insert into public.messages (
    organization_id, service, organization_address, conversation_address,
    sender_address, external_id, content, status, timestamp
  ) values (
    tests.id('org_b'), 'whatsapp', tests.val('wa_b'), tests.val('contact_b1'),
    tests.val('contact_b1'), '3EB0SHARED1',
    '{"version": "1", "type": "text", "kind": "text", "text": "from B''s session"}',
    '{"delivered": "2026-09-10T10:00:00Z"}', '2026-09-10T10:00:00Z'
  )
  $$,
  'org B can store the same external_id org A already holds'
);

select is(
  (select count(*) from public.messages where external_id = '3EB0SHARED1'),
  2::bigint,
  'both rows exist'
);

select is(
  (select content->>'text' from public.messages
   where external_id = '3EB0SHARED1' and organization_id = tests.id('org_b')),
  'from B''s session',
  'B''s row carries B''s content — nothing merged into A'
);

-- The same tenant, twice: still one row (the upsert target the ingestors use).
select throws_ok(
  $$
  insert into public.messages (
    organization_id, service, organization_address, conversation_address,
    sender_address, external_id, content, status, timestamp
  ) values (
    tests.id('org_a'), 'whatsapp', tests.val('wa_a'), tests.val('contact_a1'),
    tests.val('contact_a1'), '3EB0SHARED1',
    '{"version": "1", "type": "text", "kind": "text", "text": "again"}',
    '{"delivered": "2026-09-10T10:00:00Z"}', '2026-09-10T10:00:00Z'
  )
  $$,
  '23505',
  null,
  'the same external_id twice in one org is still a conflict'
);

-- An update keyed by external_id AND organization_id touches one tenant.
update public.messages
set status = '{"deleted": "2026-09-10T11:00:00Z"}'
where external_id = '3EB0SHARED1' and organization_id = tests.id('org_b');

select is(
  (select status->>'deleted' from public.messages
   where external_id = '3EB0SHARED1' and organization_id = tests.id('org_a')),
  null,
  'a revoke scoped to org B leaves org A''s row alone'
);

select * from finish();
rollback;
