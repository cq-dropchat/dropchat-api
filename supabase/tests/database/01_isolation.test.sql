-- Tenant isolation: the Apéndice A.5 cases of the audit, as tests. Five
-- actors — user of A, user of B, API key of A, API key of B, anon — against
-- messages, conversations, organizations and the visibility RPC.
begin;
select plan(16);

-- ---------------------------------------------------------------------------
-- Users
-- ---------------------------------------------------------------------------

select tests.authenticate_as('alice@test.local');

select is(
  (select count(*) from public.messages where organization_id = tests.id('org_a')),
  4::bigint,
  'owner of A reads all of A''s messages'
);

select is(
  (select count(*) from public.messages where organization_id = tests.id('org_b')),
  0::bigint,
  'owner of A reads none of B''s messages'
);

select is(
  (select count(*) from public.organizations),
  1::bigint,
  'owner of A sees exactly one organization'
);

select tests.clear_authentication();
select tests.authenticate_as('bob@test.local');

select is(
  (select count(*) from public.messages where organization_id = tests.id('org_a')),
  0::bigint,
  'owner of B reads none of A''s messages'
);

select is(
  (select count(*) from public.conversations where organization_id = tests.id('org_a')),
  0::bigint,
  'owner of B reads none of A''s conversations'
);

select is(
  (select count(*) from public.messages),
  2::bigint,
  'owner of B reads only B''s messages'
);

-- ---------------------------------------------------------------------------
-- API keys
-- ---------------------------------------------------------------------------

select tests.clear_authentication();
select tests.authenticate_with_api_key(tests.val('key_a_member'));

select is(
  (select count(*) from public.messages where organization_id = tests.id('org_a')),
  4::bigint,
  'member key of A reads A''s messages'
);

select is(
  (select count(*) from public.messages where organization_id = tests.id('org_b')),
  0::bigint,
  'member key of A reads none of B''s messages'
);

select tests.clear_authentication();
select tests.authenticate_with_api_key(tests.val('key_b_member'));

select is(
  (select count(*) from public.messages where organization_id = tests.id('org_a')),
  0::bigint,
  'member key of B reads none of A''s messages'
);

select is(
  (select count(*) from public.conversations),
  1::bigint,
  'member key of B sees only B''s conversation'
);

-- The visibility RPC is public and SECURITY DEFINER: it must be scoped too.
-- B's three accounts: its whatsapp number, its `local` team chat and, since
-- S1, its `sandbox` simulator. What is asserted is the ORGANIZATION on every
-- row — one of A's leaking in here is the failure this guards against.
select results_eq(
  $$ select organization_id from rls.get_visible_addresses() $$,
  $$ select tests.id('org_b') from generate_series(1, 3) $$,
  'get_visible_addresses() as key B lists B''s three accounts and nothing else'
);

select tests.clear_authentication();
select tests.authenticate_with_api_key('not-a-real-key-00000000000000000000');

select is(
  (select count(*) from public.messages),
  0::bigint,
  'an unknown api key reads nothing and raises nothing'
);

select is(
  (select count(*) from public.organizations),
  0::bigint,
  'an unknown api key sees no organization'
);

-- ---------------------------------------------------------------------------
-- Anonymous: no JWT, no header
-- ---------------------------------------------------------------------------

select tests.clear_authentication();
select tests.authenticate_as_anon();

select throws_ok(
  $$ select count(*) from public.messages $$,
  '42501',
  'authentication required',
  'anon without api-key is refused on messages'
);

select throws_ok(
  $$ select count(*) from public.conversations $$,
  '42501',
  'authentication required',
  'anon without api-key is refused on conversations'
);

select throws_ok(
  $$ select * from rls.get_visible_addresses() $$,
  '42501',
  'authentication required',
  'anon without api-key is refused on the visibility RPC'
);

select * from finish();
rollback;
