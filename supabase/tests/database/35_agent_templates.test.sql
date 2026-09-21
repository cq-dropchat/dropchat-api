-- T4 — where templates live, and who may see them.
--
-- Templates are the first thing in this schema that is deliberately GLOBAL:
-- one organization (DropChat, D6) builds them as ordinary agents, and every
-- other organization reads them. That inverts the rule the rest of the schema
-- is built on — `rls.get_authorized_orgs()` never crosses tenants — so the
-- policies here have to be written and tested the other way round: the danger
-- is not that a tenant reads another tenant's row, it is that a tenant WRITES
-- a row everybody else reads, or reads one that was archived or retired for a
-- reason.
--
-- Failure scenario for each table below:
--   platform_settings        — a tenant that can write it repoints the
--                              template source at its own organization and
--                              publishes to everybody.
--   agent_templates          — an archived template keeps being offered, or a
--                              tenant creates one.
--   agent_template_versions  — a retired version stays installable, which is
--                              how a version pulled for a bad prompt (or a
--                              leaked config) keeps spreading.
begin;
select plan(26);

-- Org B plays DropChat here on purpose: alice belongs to org A, so every read
-- she gets below is a read ACROSS tenants, which is exactly the new thing.
insert into public.platform_settings (id, template_org_id)
values (true, tests.id('org_b'));

insert into public.platform_admins (user_id, note)
values (tests.id('user_bob'), 'admin de prueba');

-- The source is an AI agent (user_id null), not a membership: a membership
-- that owns an organization cannot be deleted at all
-- (prevent_last_owner_deletion marks it instead), and the last assertions here
-- are about what happens when the source really goes away.
insert into public.agents (id, organization_id, user_id, name, role, extra)
values (
  'cccccccc-0000-4000-8000-0000000000a1'::uuid, tests.id('org_b'), null,
  'Plantillera', 'member',
  '{"mode": "active", "model": "gpt-5-mini", "instructions": "base"}'
);

insert into public.agent_templates (id, slug, name, description, category, source_agent_id)
values
  ('cccccccc-0000-4000-8000-0000000000c1'::uuid, 'ventas-contra-entrega',
   'Ventas contra entrega', 'Atiende pedidos con pago contra entrega',
   'ventas', 'cccccccc-0000-4000-8000-0000000000a1'::uuid),
  ('cccccccc-0000-4000-8000-0000000000c2'::uuid, 'plantilla-archivada',
   'Plantilla archivada', 'Ya no se ofrece', 'ventas', 'cccccccc-0000-4000-8000-0000000000a1'::uuid);

update public.agent_templates
set archived_at = now()
where slug = 'plantilla-archivada';

insert into public.agent_template_versions (template_id, version, config, config_hash, changelog)
values
  ('cccccccc-0000-4000-8000-0000000000c1'::uuid, 1,
   '{"instructions": "Atendé pedidos contra entrega", "model": "gpt-5-mini"}',
   'hash-v1', 'primera'),
  ('cccccccc-0000-4000-8000-0000000000c1'::uuid, 2,
   '{"instructions": "Versión retirada", "model": "gpt-5-mini"}',
   'hash-v2', 'retirada'),
  ('cccccccc-0000-4000-8000-0000000000c2'::uuid, 1,
   '{"instructions": "De una plantilla archivada", "model": "gpt-5-mini"}',
   'hash-v3', 'huerfana');

update public.agent_template_versions
set retired_at = now()
where template_id = 'cccccccc-0000-4000-8000-0000000000c1'::uuid and version = 2;

-- ---------------------------------------------------------------------------
-- platform_settings: which organization is the source. Read by the platform,
-- written by nobody through the API.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('alice@test.local');
select is(
  (select count(*)::int from public.platform_settings),
  0,
  'a tenant does not learn which organization is the template source'
);
select throws_ok(
  $$ update public.platform_settings set template_org_id = tests.id('org_a') $$,
  '42501',
  null,
  'and cannot repoint it at her own organization'
);
select tests.clear_authentication();

select tests.authenticate_as('bob@test.local');
select is(
  (select template_org_id from public.platform_settings),
  tests.id('org_b'),
  'the platform admin reads the source organization'
);
select throws_ok(
  $$ insert into public.platform_settings (id, template_org_id)
     values (true, tests.id('org_a')) $$,
  '42501',
  null,
  'and not even he writes it: the row is set up by hand, like the first admin'
);
select tests.clear_authentication();

select tests.authenticate_with_api_key(tests.val('key_a_member'));
select is(
  (select count(*)::int from public.platform_settings),
  0,
  'an API key reads nothing of the platform settings'
);
select tests.clear_authentication();

select tests.authenticate_as_anon();
select is(
  (select count(*)::int from public.platform_settings),
  0,
  'nor does anon'
);
select tests.clear_authentication();

-- ---------------------------------------------------------------------------
-- agent_templates: the catalogue. Global on purpose, archived means gone.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('alice@test.local');
select is(
  (select count(*)::int from public.agent_templates),
  1,
  'a member of another organization reads the catalogue: templates are global'
);
select is(
  (select slug from public.agent_templates),
  'ventas-contra-entrega',
  'and an archived template is not in it'
);
select throws_ok(
  $$ insert into public.agent_templates (slug, name)
     values ('mia', 'Mía') $$,
  '42501',
  null,
  'a tenant cannot add a template that every other tenant would see'
);
with touched as (
    update public.agent_templates set name = 'Secuestrada'
    where slug = 'ventas-contra-entrega'
    returning 1
)
select is(
  (select count(*)::int from touched),
  0,
  'nor rewrite one'
);
select tests.clear_authentication();

select tests.authenticate_as('bob@test.local');
select is(
  (select count(*)::int from public.agent_templates),
  2,
  'the platform admin sees the archived one too, which is how it gets un-archived'
);
select lives_ok(
  $$ insert into public.agent_templates (slug, name)
     values ('nueva', 'Nueva') $$,
  'and he is the one who adds to the catalogue'
);
select tests.clear_authentication();

select tests.authenticate_with_api_key(tests.val('key_a_member'));
select is(
  (select count(*)::int from public.agent_templates),
  0,
  'API key A reads no templates: installing is an act of a signed-in member'
);
select tests.clear_authentication();

select tests.authenticate_with_api_key(tests.val('key_b_member'));
select is(
  (select count(*)::int from public.agent_templates),
  0,
  'and neither does API key B, even though org B is the source'
);
select tests.clear_authentication();

select tests.authenticate_as_anon();
select is(
  (select count(*)::int from public.agent_templates),
  0,
  'nor anon'
);
select tests.clear_authentication();

-- ---------------------------------------------------------------------------
-- agent_template_versions: published and not retired, or nothing.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('alice@test.local');
select is(
  (select count(*)::int from public.agent_template_versions),
  1,
  'a member reads one version: the published, un-retired one'
);
select is(
  (select version from public.agent_template_versions),
  1,
  'the retired version is not it'
);

-- B3: the configuration is readable in full, base instructions included. The
-- alternative was hiding them, and T6 cannot resolve an override layer against
-- a base nobody is allowed to see.
select is(
  (select config ->> 'instructions' from public.agent_template_versions),
  'Atendé pedidos contra entrega',
  'and its config is readable in full, base instructions included (B3)'
);

select throws_ok(
  $$ insert into public.agent_template_versions
       (template_id, version, config, config_hash)
     values ('cccccccc-0000-4000-8000-0000000000c1'::uuid, 9, '{}', 'x') $$,
  '42501',
  null,
  'a tenant cannot publish a version to every other tenant'
);
select throws_ok(
  $$ update public.agent_template_versions set retired_at = null
     where template_id = 'cccccccc-0000-4000-8000-0000000000c1'::uuid $$,
  '42501',
  null,
  'nor bring a retired version back'
);
select tests.clear_authentication();

select tests.authenticate_as('bob@test.local');
select is(
  (select count(*)::int from public.agent_template_versions),
  3,
  'the platform admin sees every version, retired and orphaned alike'
);

-- Not even the admin writes a version by hand. publish_agent_template_version
-- is the only code that copies the MASKED extra and drops each tool's config;
-- an INSERT policy here would be a second way in that skips exactly that.
select throws_ok(
  $$ insert into public.agent_template_versions
       (template_id, version, config, config_hash)
     values ('cccccccc-0000-4000-8000-0000000000c1'::uuid, 9,
             '{"api_key": "sk-de-verdad"}', 'x') $$,
  '42501',
  null,
  'and not even he inserts one by hand: publishing goes through the function'
);
select tests.clear_authentication();

select tests.authenticate_with_api_key(tests.val('key_b_member'));
select is(
  (select count(*)::int from public.agent_template_versions),
  0,
  'API key B reads no versions'
);
select tests.clear_authentication();

select tests.authenticate_as_anon();
select is(
  (select count(*)::int from public.agent_template_versions),
  0,
  'nor anon'
);
select tests.clear_authentication();

-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- The source is an ordinary agent of an ordinary organization, so somebody
-- will eventually delete it. While its organization is alive that is a SOFT
-- delete: mark_agent_deleted cancels the DELETE and stamps `deleted_at`. So
-- the template keeps pointing at a source that no longer answers, which is
-- exactly the wanted shape — publishing a NEW version stops, and the versions
-- already published are not retracted, because each one is a copy and not a
-- view of the agent.
--
-- The hard delete only happens inside sweep_deletions, once the organization
-- itself is gone; that is the path that exercises `on delete set null`, and it
-- lives in 12_deletions where the sweep already runs.
-- ---------------------------------------------------------------------------

delete from public.agents
where id = 'cccccccc-0000-4000-8000-0000000000a1'::uuid;

select ok(
  (
    select deleted_at is not null from public.agents
    where id = 'cccccccc-0000-4000-8000-0000000000a1'::uuid
  ),
  'deleting the source agent marks it instead of removing it'
);
select is(
  (select count(*)::int from public.agent_template_versions
   where template_id = 'cccccccc-0000-4000-8000-0000000000c1'::uuid),
  2,
  'and the versions it already published stay published'
);

select * from finish();
rollback;
