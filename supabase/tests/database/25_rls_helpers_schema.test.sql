-- P8 — the RLS helpers live outside `public`.
--
-- Failure scenario: they are SECURITY DEFINER functions, and `public` is a
-- schema PostgREST exposes. Postgres grants EXECUTE on a new function to
-- PUBLIC — the role anon and authenticated inherit from — and a
-- `create or replace` puts that grant back, so every helper was a live RPC
-- endpoint: /rpc/get_visible_addresses, /rpc/get_authorized_orgs,
-- /rpc/get_restricted_conversations, callable with the anon key. Each one
-- answers about its caller, so what came back was the caller's own
-- organizations and accounts rather than someone else's — but they are the
-- machinery of row-level security, not an API, and nothing outside SQL has
-- ever called one.
--
-- They are in `rls` now, which is not in config.toml's exposed schemas.
--
-- The list below is hardcoded, so it is also this test's blind spot: a helper
-- that is not named here can sit in `public` and both assertions stay green,
-- because each one aggregates over the list rather than over the catalog.
-- `is_platform_admin` (E1) did exactly that until T3. Every new helper goes in
-- the list, or this test stops being about the helpers and becomes about the
-- ones somebody remembered.
begin;
select plan(13);

-- ---------------------------------------------------------------------------
-- Where they are, and where they are not.
-- ---------------------------------------------------------------------------

create temp table helpers (fn text, args text[]);
insert into helpers values
  ('get_authorized_orgs', array['public.role']),
  ('get_own_agents', array[]::text[]),
  ('get_own_sandbox_addresses', array[]::text[]),
  ('get_visible_addresses', array[]::text[]),
  ('get_participant_conversations', array[]::text[]),
  ('get_restricted_conversations', array[]::text[]),
  ('is_restricted_conversation', array['public.service', 'text', 'jsonb']),
  ('is_conversation_visible', array['uuid', 'uuid', 'text', 'public.service']),
  ('is_media_visible', array['text']),
  ('is_platform_admin', array[]::text[]),
  ('agent_identity_unchanged', array['uuid', 'uuid', 'uuid']),
  ('agent_identity_and_role_unchanged',
   array['uuid', 'uuid', 'uuid', 'public.role']);

select is(
  (
    select array_agg(h.fn order by h.fn)
    from helpers h
    join pg_proc p on p.proname = h.fn
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
  ),
  null,
  'no RLS helper is left in public, where PostgREST would publish it'
);

select is(
  (
    select count(*)::int
    from helpers h
    join pg_proc p on p.proname = h.fn
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'rls'
  ),
  (select count(*)::int from helpers),
  'every helper the list names is in rls'
);

-- A policy runs as the invoking role: without USAGE here every policy that
-- calls one fails, and the whole API answers nothing.
select ok(
  has_schema_privilege('anon', 'rls', 'usage'),
  'anon has usage on rls, so the policies can call them'
);
select ok(
  has_schema_privilege('authenticated', 'rls', 'usage'),
  'authenticated too'
);
select ok(
  has_schema_privilege('service_role', 'rls', 'usage'),
  'and service_role'
);

-- ---------------------------------------------------------------------------
-- And the visibility they decide still decides it, for each actor.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('alice@test.local');
select is(
  (select count(*) from public.conversations where organization_id = tests.id('org_a')),
  2::bigint,
  'user A still reads A''s conversations'
);
select is(
  (select count(*) from public.conversations where organization_id = tests.id('org_b')),
  0::bigint,
  'and none of B''s'
);
select tests.clear_authentication();

select tests.authenticate_as('bob@test.local');
select is(
  (select count(*) from public.conversations),
  1::bigint,
  'user B still reads only B''s'
);
select tests.clear_authentication();

select tests.authenticate_with_api_key(tests.val('key_a_member'));
select is(
  (select count(*) from public.messages where organization_id = tests.id('org_a')),
  4::bigint,
  'API key A still reads A''s messages'
);
select is(
  (select count(*) from public.messages where organization_id = tests.id('org_b')),
  0::bigint,
  'and none of B''s'
);
select tests.clear_authentication();

select tests.authenticate_with_api_key(tests.val('key_b_member'));
select is(
  (select count(*) from public.messages),
  2::bigint,
  'API key B still reads only B''s'
);
select tests.clear_authentication();

-- anon without an api-key header is refused at the helper itself: it raises
-- rather than returning an empty set, which is what the whole API answers to
-- an unauthenticated caller.
select tests.authenticate_as_anon();
select throws_ok(
  $$ select count(*) from public.conversations $$,
  '42501', 'authentication required',
  'anon still reads nothing'
);
select throws_ok(
  $$ select * from rls.get_visible_addresses() $$,
  '42501', 'authentication required',
  'and the helper says the same when called directly'
);
select tests.clear_authentication();

select * from finish();
rollback;
