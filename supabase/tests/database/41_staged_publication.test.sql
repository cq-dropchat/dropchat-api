-- T5 — publishing to two organizations before publishing to everybody.
--
-- A version that goes out to the whole customer base at once is a prompt
-- change nobody piloted: every organization on that template starts answering
-- differently in the same minute, and the only way back is another version.
-- So a version may be published as a CANARY — named organizations only — and
-- promoted once it has been watched.
--
-- The design is one column, `canary_organizations`, and everything else falls
-- out of RLS. `install_agent_template` and `update_agent_template_version` are
-- SECURITY INVOKER, so their «newest version that is not retired» query is
-- already filtered by what the caller may READ: an organization that is not in
-- the list does not see the canary version and therefore lands on the last
-- generally available one, with no extra branch anywhere.
--
-- The one place that does need a branch is automatic updates (D7), which run
-- inside publishing as SECURITY DEFINER, where no policy applies.
begin;
select plan(14);

insert into public.platform_settings (id, template_org_id)
values (true, tests.id('org_b'));

insert into public.platform_admins (user_id, note)
values (tests.id('user_bob'), 'admin de prueba');

insert into public.agents (id, organization_id, user_id, name, role, extra)
values (
  '99999999-0000-4000-8000-0000000000a1'::uuid, tests.id('org_b'), null,
  'Plantillera', 'member', '{"mode": "active", "instructions": "base"}'
);

insert into public.agent_templates (id, slug, name, source_agent_id)
values (
  '99999999-0000-4000-8000-0000000000c1'::uuid, 'ventas-contra-entrega',
  'Ventas contra entrega', '99999999-0000-4000-8000-0000000000a1'::uuid
);

insert into public.agent_template_versions
  (template_id, version, config, config_hash)
values (
  '99999999-0000-4000-8000-0000000000c1'::uuid, 1,
  '{"instructions": "v1"}'::jsonb, 'hash-v1'
);

-- Org A installs the generally available version.
select tests.authenticate_as('alice@test.local');
select lives_ok(
  $$select public.install_agent_template(
      tests.id('org_a'), '99999999-0000-4000-8000-0000000000c1'::uuid)$$,
  'org A installs v1'
);
select tests.clear_authentication();

-- A canary for org B alone.
insert into public.agent_template_versions
  (template_id, version, config, config_hash, canary_organizations)
values (
  '99999999-0000-4000-8000-0000000000c1'::uuid, 2,
  '{"instructions": "v2"}'::jsonb, 'hash-v2',
  array[tests.id('org_b')]
);

-- ---------------------------------------------------------------------------
-- Who sees it.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('alice@test.local');
select is(
  (select count(*)::int from public.agent_template_versions
   where template_id = '99999999-0000-4000-8000-0000000000c1'::uuid
     and version = 2),
  0,
  'an organization outside the canary does not see the version at all'
);
select tests.clear_authentication();

select tests.authenticate_as('bob@test.local');
select is(
  (select count(*)::int from public.agent_template_versions
   where template_id = '99999999-0000-4000-8000-0000000000c1'::uuid
     and version = 2),
  1,
  'an organization inside it does'
);
select tests.clear_authentication();

-- Anon reads no version of any kind here (the catalogue policy is
-- `to authenticated`), and the point of this assertion is the OTHER half: the
-- canary check must answer «no» for a caller with no session instead of
-- raising 42501, which is what `rls.get_authorized_orgs` does on its own.
select tests.authenticate_as_anon();
select is(
  (select count(*)::int from public.agent_template_versions
   where template_id = '99999999-0000-4000-8000-0000000000c1'::uuid),
  0,
  'anon reads nothing here, and asking whether a canary is for it does not raise'
);
select tests.clear_authentication();

-- ---------------------------------------------------------------------------
-- What «take the newest» means when the newest is a canary.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('alice@test.local');
select throws_ok(
  $$select public.update_agent_template_version(
      (select id from public.agents
       where organization_id = tests.id('org_a') and template_id is not null),
      2)$$,
  'P0001',
  null,
  'and cannot take it by naming the number either'
);
select tests.clear_authentication();

select is(
  (select template_version from public.agents
   where organization_id = tests.id('org_a') and template_id is not null),
  1,
  'so it stays where it was'
);

-- Bob's organization installs, and gets the canary because it is in it.
select tests.authenticate_as('bob@test.local');
select lives_ok(
  $$select public.install_agent_template(
      tests.id('org_b'), '99999999-0000-4000-8000-0000000000c1'::uuid)$$,
  'the canary organization installs'
);
select tests.clear_authentication();

select is(
  (select template_version from public.agents
   where organization_id = tests.id('org_b') and template_id is not null),
  2,
  'and lands on the canary version'
);

-- ---------------------------------------------------------------------------
-- Automatic updates, which run where no policy applies.
-- ---------------------------------------------------------------------------

update public.agents set template_auto_update = true
where template_id = '99999999-0000-4000-8000-0000000000c1'::uuid;

update public.agents
set extra = '{"instructions": "cambia el hash"}'::jsonb
where id = '99999999-0000-4000-8000-0000000000a1'::uuid;

select tests.authenticate_as('bob@test.local');
select lives_ok(
  $$select public.publish_agent_template_version(
      '99999999-0000-4000-8000-0000000000c1'::uuid, 'tercera',
      array[tests.id('org_b')])$$,
  'a third version, canary again'
);
select tests.clear_authentication();

select is(
  (select template_version from public.agents
   where organization_id = tests.id('org_b') and template_id is not null),
  3,
  'the canary organization is moved automatically, as it asked'
);

select is(
  (select template_version from public.agents
   where organization_id = tests.id('org_a') and template_id is not null),
  1,
  'and one outside it is NOT: automatic means the versions it can have'
);

-- ---------------------------------------------------------------------------
-- Promoting.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('alice@test.local');
select throws_ok(
  $$select public.promote_agent_template_version(
      '99999999-0000-4000-8000-0000000000c1'::uuid, 3)$$,
  '42501',
  null,
  'a tenant does not promote a version to the whole customer base'
);
select tests.clear_authentication();

select tests.authenticate_as('bob@test.local');
select lives_ok(
  $$select public.promote_agent_template_version(
      '99999999-0000-4000-8000-0000000000c1'::uuid, 3)$$,
  'the platform promotes it'
);
select tests.clear_authentication();

select tests.authenticate_as('alice@test.local');
select is(
  (select count(*)::int from public.agent_template_versions
   where template_id = '99999999-0000-4000-8000-0000000000c1'::uuid
     and version = 3),
  1,
  'and now everybody sees it'
);
select tests.clear_authentication();

select * from finish();
rollback;
