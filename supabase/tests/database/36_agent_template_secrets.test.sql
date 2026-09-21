-- T4 — the mandatory one: nothing that looks like a credential leaves the
-- source organization.
--
-- Publishing a template copies one organization's agent configuration to every
-- other organization in the product. It is the only write in this schema that
-- crosses every tenant boundary at once, so a credential that survives the
-- copy is not leaked to one attacker — it is handed to the entire customer
-- base, in a row they are allowed to read.
--
-- Two mechanisms stand between that and this test, and they are NOT the same
-- mechanism:
--
--   1. extract_secrets() has already masked the agent row itself. Publishing
--      reads `agents.extra` as stored, never public.secrets, so what it copies
--      is already '********' for the agent's api_key, a tool's password and
--      token, and every value under a tool's headers.
--
--   2. The tool `config` is dropped entirely on publish. This is the one that
--      is easy to think is redundant and is not: extract_secrets masks a FIXED
--      list of keys, so a tool whose config carries `api_key` — a name it
--      never looks at — stays in CLEARTEXT in the agent row. Below it is
--      asserted twice: unmasked where it is stored, absent where it is
--      published.
--
-- And the thing neither mechanism covers, which is why config goes altogether:
-- `host`, `user`, `database`, `url`, `email` are not credentials and are not
-- masked, but they are the source organization's infrastructure, and a
-- catalogue every tenant reads is no place for them.
begin;
select plan(21);

-- A full jsonb walk. The scan below has to be recursive or it is theatre: the
-- interesting values are three and four levels down, inside an array.
create function pg_temp.walk(_doc jsonb)
returns table (path text, leaf jsonb)
language sql stable
as $walk$
  with recursive w(path, node) as (
    select '$'::text, _doc
    union all
    select child.p, child.v
    from w
    cross join lateral (
      select w.path || '.' || e.key, e.value
      from jsonb_each(w.node) e where jsonb_typeof(w.node) = 'object'
      union all
      select w.path || '[]', a.value
      from jsonb_array_elements(w.node) a where jsonb_typeof(w.node) = 'array'
    ) child(p, v)
  )
  select path, node from w where jsonb_typeof(node) not in ('object', 'array');
$walk$;

-- Every fake secret in one place, so the blunt assertion at the end can say
-- "none of these strings appears anywhere in what was published".
create temp table fake_secrets (value text);
insert into fake_secrets values
  ('sk-agente-de-mentira-0000'),
  ('Bearer token-de-mentira-1111'),
  ('clave-de-mentira-2222'),
  ('sk-del-tool-en-claro-3333'),
  ('db.interno.dropchat');

insert into public.platform_settings (id, template_org_id)
values (true, tests.id('org_b'));

insert into public.platform_admins (user_id, note)
values (tests.id('user_bob'), 'admin de prueba');

-- The source agent, carrying one of every shape that matters.
insert into public.agents (id, organization_id, user_id, name, role, extra)
values (
  'eeeeeeee-0000-4000-8000-0000000000a1'::uuid, tests.id('org_b'), null,
  'Plantillera', 'member',
  jsonb_build_object(
    'mode', 'active',
    'model', 'gpt-5-mini',
    'instructions', 'Atendé pedidos contra entrega',
    'api_key', 'sk-agente-de-mentira-0000',
    'tools', jsonb_build_array(
      jsonb_build_object(
        'provider', 'local', 'type', 'http', 'label', 'dropi',
        'config', jsonb_build_object(
          'url', 'https://api.dropi.cl',
          'headers', jsonb_build_object(
            'Authorization', 'Bearer token-de-mentira-1111'
          )
        )
      ),
      jsonb_build_object(
        'provider', 'local', 'type', 'sql', 'label', 'pedidos',
        'config', jsonb_build_object(
          'driver', 'postgres',
          'host', 'db.interno.dropchat',
          'user', 'postgres',
          'database', 'pedidos',
          'password', 'clave-de-mentira-2222'
        )
      ),
      jsonb_build_object(
        'provider', 'local', 'type', 'mcp', 'label', 'agenda',
        'config', jsonb_build_object(
          'url', 'https://mcp.interno.dropchat',
          'api_key', 'sk-del-tool-en-claro-3333'
        )
      )
    )
  )
);

insert into public.agent_templates (id, slug, name, source_agent_id)
values ('eeeeeeee-0000-4000-8000-0000000000c1'::uuid, 'ventas', 'Ventas',
        'eeeeeeee-0000-4000-8000-0000000000a1'::uuid);

-- ---------------------------------------------------------------------------
-- Preconditions. If these are wrong the rest proves nothing, and one of them
-- is the gap that makes dropping `config` load-bearing.
-- ---------------------------------------------------------------------------

select is(
  (select extra ->> 'api_key' from public.agents
   where id = 'eeeeeeee-0000-4000-8000-0000000000a1'::uuid),
  '********',
  'extract_secrets already masked the agent api_key in the row itself'
);

select is(
  (select value -> 'api_key' #>> '{}' from public.secrets
   where scope = 'agent' and ref = 'eeeeeeee-0000-4000-8000-0000000000a1'),
  'sk-agente-de-mentira-0000',
  'and the real one is in public.secrets, which publishing never reads'
);

-- The gap: `api_key` inside a TOOL config is not in extract_secrets' list
-- (which is password, token and headers), so it is stored in cleartext.
select is(
  (
    select t -> 'config' ->> 'api_key'
    from public.agents a,
         lateral jsonb_array_elements(a.extra -> 'tools') t
    where a.id = 'eeeeeeee-0000-4000-8000-0000000000a1'::uuid
      and t ->> 'label' = 'agenda'
  ),
  'sk-del-tool-en-claro-3333',
  'a tool config api_key is NOT masked: extract_secrets only knows a fixed list'
);

-- ---------------------------------------------------------------------------
-- Publishing is the superadmin's, and nobody else's.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('alice@test.local');
select throws_ok(
  $$ select public.publish_agent_template_version(
       'eeeeeeee-0000-4000-8000-0000000000c1'::uuid, 'mia') $$,
  '42501',
  null,
  'a tenant cannot publish to the catalogue'
);
select tests.clear_authentication();

select tests.authenticate_as('bob@test.local');
select is(
  (select version from public.publish_agent_template_version(
     'eeeeeeee-0000-4000-8000-0000000000c1'::uuid, 'primera')),
  1,
  'the platform admin publishes version 1'
);
select tests.clear_authentication();

select is(
  (select published_by from public.agent_template_versions
   where template_id = 'eeeeeeee-0000-4000-8000-0000000000c1'::uuid and version = 1),
  tests.id('user_bob'),
  'and the version records who published it'
);

-- ---------------------------------------------------------------------------
-- THE SCAN. Recursive, over the whole published document.
-- ---------------------------------------------------------------------------

-- Not vacuous: the walk really does reach credential-shaped paths. Without
-- this, a walk that returned nothing at all would make the next assertion
-- green and mean nothing.
select ok(
  (
    select count(*) > 0
    from public.agent_template_versions v,
         lateral pg_temp.walk(v.config) w
    where w.path ~* '(api_key|apikey|authorization|token|password|secret|credential|headers)'
  ),
  'the scan reaches credential-shaped paths at all'
);

select is(
  (
    select array_agg(w.path || ' = ' || (w.leaf #>> '{}') order by w.path)
    from public.agent_template_versions v,
         lateral pg_temp.walk(v.config) w
    where w.path ~* '(api_key|apikey|authorization|token|password|secret|credential|headers)'
      and jsonb_typeof(w.leaf) = 'string'
      and w.leaf #>> '{}' <> '********'
  ),
  null,
  'and every one of them is the mask, with no exception anywhere in the tree'
);

-- The blunt one. Whatever the key was called, these strings must not be in
-- what every organization can read.
select is(
  (
    select count(*)::int
    from public.agent_template_versions v, fake_secrets f
    where v.template_id = 'eeeeeeee-0000-4000-8000-0000000000c1'::uuid
      and v.config::text like '%' || f.value || '%'
  ),
  0,
  'not one of the source organization''s secrets appears in the published text'
);

-- The decision that covers what the mask does not.
select is(
  (
    select count(*)::int
    from public.agent_template_versions v,
         lateral jsonb_array_elements(v.config -> 'tools') t
    where v.version = 1 and t ? 'config'
  ),
  0,
  'no tool carries a config: the connection is the installing organization''s'
);

-- ...without losing what the template is FOR.
select is(
  (
    select array_agg(t ->> 'label' order by t ->> 'label')
    from public.agent_template_versions v,
         lateral jsonb_array_elements(v.config -> 'tools') t
    where v.version = 1
  ),
  array['agenda', 'dropi', 'pedidos'],
  'the template still declares which tools it uses, by type and label'
);

select is(
  (select config ->> 'instructions' from public.agent_template_versions
   where template_id = 'eeeeeeee-0000-4000-8000-0000000000c1'::uuid and version = 1),
  'Atendé pedidos contra entrega',
  'and the configuration that is not a credential travels intact'
);

-- ---------------------------------------------------------------------------
-- The guards around publishing.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('bob@test.local');

-- The hash earns its keep: a version that changes nothing breaks what "update
-- available" means for every organization that installed the last one.
select throws_ok(
  $$ select public.publish_agent_template_version(
       'eeeeeeee-0000-4000-8000-0000000000c1'::uuid, 'igualita') $$,
  'P0001',
  null,
  'publishing an identical configuration is refused'
);
select tests.clear_authentication();

update public.agents
set extra = jsonb_build_object('instructions', 'Ahora también cambios')
where id = 'eeeeeeee-0000-4000-8000-0000000000a1'::uuid;

select tests.authenticate_as('bob@test.local');
select is(
  (select version from public.publish_agent_template_version(
     'eeeeeeee-0000-4000-8000-0000000000c1'::uuid, 'segunda')),
  2,
  'a real change publishes the next version'
);
select tests.clear_authentication();

-- A source outside the template organization would copy a TENANT's
-- configuration into the catalogue. That is the same failure as a leaked
-- credential, arriving through the front door.
update public.agent_templates
set source_agent_id = tests.id('agent_alice')
where id = 'eeeeeeee-0000-4000-8000-0000000000c1'::uuid;

select tests.authenticate_as('bob@test.local');
select throws_ok(
  $$ select public.publish_agent_template_version(
       'eeeeeeee-0000-4000-8000-0000000000c1'::uuid, 'ajena') $$,
  'P0001',
  null,
  'publishing from an agent outside the template organization is refused'
);

update public.agent_templates
set source_agent_id = null
where id = 'eeeeeeee-0000-4000-8000-0000000000c1'::uuid;

select throws_ok(
  $$ select public.publish_agent_template_version(
       'eeeeeeee-0000-4000-8000-0000000000c1'::uuid, 'sin fuente') $$,
  'P0001',
  null,
  'and so is publishing a template with no source at all'
);
select tests.clear_authentication();

-- ---------------------------------------------------------------------------
-- Retiring: the only way a published version stops being installable.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('alice@test.local');
select throws_ok(
  $$ select public.retire_agent_template_version(
       'eeeeeeee-0000-4000-8000-0000000000c1'::uuid, 1) $$,
  '42501',
  null,
  'a tenant cannot retire a version'
);
select tests.clear_authentication();

select tests.authenticate_as('bob@test.local');
select ok(
  (select retired_at is not null from public.retire_agent_template_version(
     'eeeeeeee-0000-4000-8000-0000000000c1'::uuid, 1)),
  'the platform admin retires it'
);
select tests.clear_authentication();

select tests.authenticate_as('alice@test.local');
select is(
  (select count(*)::int from public.agent_template_versions
   where template_id = 'eeeeeeee-0000-4000-8000-0000000000c1'::uuid),
  1,
  'and a member stops seeing it: only the un-retired version is left'
);
select tests.clear_authentication();

-- ---------------------------------------------------------------------------
-- Privileges. `db diff` does not carry function grants across, so these are
-- hand-written in the migration and this is what proves they arrived — a
-- revoke that lives only in supabase/schemas/ is a revoke that never happened,
-- and `db diff` says "No schema changes found" either way.
--
-- agent_template_config is not in 11_service_only_functions: that file's third
-- assertion is that service_role still executes everything it lists, and this
-- one is revoked from service_role too. Same shape as record_error_issue (E1),
-- which is asserted in its own test for the same reason.
-- ---------------------------------------------------------------------------

select is(
  (
    select array_agg(r.role order by r.role)
    from (values ('anon'), ('authenticated'), ('service_role')) r(role)
    where has_function_privilege(
      r.role, 'public.agent_template_config(jsonb)', 'execute')
  ),
  null,
  'the sanitiser is callable by no API role at all: only its caller runs it'
);

select is(
  (
    select array_agg(f.fn || ' / ' || r.role order by f.fn, r.role)
    from (values ('public.publish_agent_template_version(uuid, text)'),
                 ('public.retire_agent_template_version(uuid, integer)')) f(fn),
         (values ('anon'), ('service_role')) r(role)
    where has_function_privilege(r.role, f.fn::regprocedure, 'execute')
  ),
  null,
  'and writing the catalogue is a signed-in act: not anon, not service_role'
);

select * from finish();
rollback;
