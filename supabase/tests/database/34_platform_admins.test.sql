-- T3 — who may see the platform, and who may appoint them.
--
-- public.platform_admins is the only permission in this schema that is not a
-- membership in an organization: it crosses every tenant by definition, so
-- none of the usual helpers apply and none of the usual tests cover it.
--
-- Failure scenario: Supabase's default privileges grant SELECT, INSERT, UPDATE
-- and DELETE on a new public table to `anon` and `authenticated`, and those
-- grants are still in place here (unlike error_issues, where they were
-- narrowed). Row-level security is therefore the ONLY thing between a stolen
-- session and a row that appoints its own owner — there is no privilege safety
-- net underneath. The table carries exactly one policy, for SELECT, on
-- purpose: an admin who can appoint admins is a privilege escalation from a
-- single stolen session, and an admin who can read the list learns who else to
-- steal from.
--
-- Two shapes of "cannot write", both asserted below because they fail
-- differently: INSERT raises 42501, while UPDATE and DELETE with no policy are
-- silent no-ops that touch zero rows and report success.
begin;
select plan(15);

-- Bob is the platform admin for this transaction. Seeded as the session user,
-- which is how the runbook in README.md does it: from the SQL editor, never
-- through the API.
insert into public.platform_admins (user_id, note)
values (tests.id('user_bob'), 'admin de prueba');

-- ---------------------------------------------------------------------------
-- Reading: your own row, or nothing at all.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('alice@test.local');
select is(
  (select count(*)::int from public.platform_admins),
  0,
  'a common user does not read another platform admin''s row'
);
select tests.clear_authentication();

-- The positive control. Without it the assertion above would also pass with a
-- policy that hides the table from everybody, including the panel it exists to
-- open.
select tests.authenticate_as('bob@test.local');
select is(
  (select count(*)::int from public.platform_admins),
  1,
  'the platform admin reads his own row'
);
select is(
  (select user_id from public.platform_admins),
  tests.id('user_bob'),
  'and it is his own, not the list of who else can see the panel'
);
select tests.clear_authentication();

-- The policy is `to authenticated`: an API key caller runs as `anon`, so it
-- never matches, for either organization.
select tests.authenticate_with_api_key(tests.val('key_a_member'));
select is(
  (select count(*)::int from public.platform_admins),
  0,
  'API key A reads nothing: platform admin is not an organization permission'
);
select tests.clear_authentication();

select tests.authenticate_with_api_key(tests.val('key_b_member'));
select is(
  (select count(*)::int from public.platform_admins),
  0,
  'API key B reads nothing either, not even its own owner''s row'
);
select tests.clear_authentication();

select tests.authenticate_as_anon();
select is(
  (select count(*)::int from public.platform_admins),
  0,
  'anon reads nothing'
);
select tests.clear_authentication();

-- ---------------------------------------------------------------------------
-- Writing: nobody, through no policy. This is the escalation the design
-- refuses, and the grants above mean RLS is the only thing refusing it.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('alice@test.local');
select throws_ok(
  $$ insert into public.platform_admins (user_id, note)
     values (tests.id('user_alice'), 'me nombro solo') $$,
  '42501',
  null,
  'a common user cannot appoint herself'
);
select tests.clear_authentication();

-- The one that matters most: being an admin is not a licence to make more of
-- them. A single stolen admin session must not become two.
select tests.authenticate_as('bob@test.local');
select throws_ok(
  $$ insert into public.platform_admins (user_id, note)
     values (tests.id('user_amber'), 'un amigo') $$,
  '42501',
  null,
  'a platform admin cannot appoint another one'
);
select tests.clear_authentication();

select tests.authenticate_as('alice@test.local');
with touched as (
  update public.platform_admins set note = 'ahora es mia'
  where user_id = tests.id('user_bob')
  returning 1
)
select is(
  (select count(*)::int from touched),
  0,
  'a common user changes no row of an admin she cannot even see'
);
select tests.clear_authentication();

select tests.authenticate_as('bob@test.local');
with touched as (
  update public.platform_admins set note = 'me asciendo'
  where user_id = tests.id('user_bob')
  returning 1
)
select is(
  (select count(*)::int from touched),
  0,
  'and the admin cannot rewrite his own row either: reading it is all he may do'
);
with touched as (
  delete from public.platform_admins
  where user_id = tests.id('user_bob')
  returning 1
)
select is(
  (select count(*)::int from touched),
  0,
  'nor delete it: revoking an admin is a deliberate act from the SQL editor'
);
select tests.clear_authentication();

-- ---------------------------------------------------------------------------
-- The helper the other three error-panel policies are built on.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('bob@test.local');
select ok(
  rls.is_platform_admin(),
  'rls.is_platform_admin() is true for the admin'
);
select tests.clear_authentication();

select tests.authenticate_as('alice@test.local');
select ok(
  not rls.is_platform_admin(),
  'and false for a common user, who would otherwise read every tenant''s errors'
);
select tests.clear_authentication();

select tests.authenticate_as_anon();
select ok(
  not rls.is_platform_admin(),
  'and false for anon, which the error panel''s other policies all rest on'
);
select tests.clear_authentication();

-- ---------------------------------------------------------------------------
-- The design itself, so that widening it is a deliberate act and not a commit
-- that happens to keep the assertions above green.
-- ---------------------------------------------------------------------------

select is(
  (
    select array_agg(cmd::text order by cmd::text)
    from pg_policies
    where schemaname = 'public' and tablename = 'platform_admins'
  ),
  array['SELECT'],
  'platform_admins carries exactly one policy, and it is SELECT'
);

select * from finish();
rollback;
