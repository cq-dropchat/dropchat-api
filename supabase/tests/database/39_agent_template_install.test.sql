-- T6 — installing a template, and the layer that sits on top of it.
--
-- An installed agent does not COPY the template: it points at a version and
-- keeps its own `extra` as the override layer. That is what makes D7 possible
-- (a new version is one column away) and it is also what makes this the
-- trickiest resolution in the schema, for a reason §3.6 spells out: `extra` is
-- written as a JSON MERGE PATCH, and a merge patch replaces an array whole.
-- The layer therefore CANNOT edit one tool of a list.
--
-- So tools are not merged as jsonb. They are merged by IDENTITY — `type:label`
-- — which is the same key `extract_secrets` uses to file a tool's credentials,
-- so a renamed tool loses its connection in exactly the same way it already
-- loses its secrets.
--
-- And the part D13 forces: a published version declares its tools WITHOUT
-- their `config`, because a config is the source organization's host, user and
-- database. An installed template therefore arrives with tools that cannot
-- run, and the organization fills in its own connection. A tool still missing
-- one is left OUT of the resolved configuration rather than handed to the
-- model half-built.
begin;
select plan(29);

insert into public.platform_settings (id, template_org_id)
values (true, tests.id('org_b'));

insert into public.platform_admins (user_id, note)
values (tests.id('user_bob'), 'admin de prueba');

-- DropChat's own agent: an AI agent (user_id null) in the template org.
insert into public.agents (id, organization_id, user_id, name, role, extra)
values (
  'dddddddd-0000-4000-8000-0000000000a1'::uuid, tests.id('org_b'), null,
  'Plantillera', 'member',
  '{"mode": "active", "instructions": "base", "model_tier": "equilibrado"}'
);

insert into public.agent_templates (id, slug, name, description, category, source_agent_id)
values (
  'dddddddd-0000-4000-8000-0000000000c1'::uuid, 'ventas-contra-entrega',
  'Ventas contra entrega', 'Atiende pedidos con pago contra entrega',
  'ventas', 'dddddddd-0000-4000-8000-0000000000a1'::uuid
);

insert into public.agent_template_versions
  (template_id, version, config, config_hash, changelog)
values (
  'dddddddd-0000-4000-8000-0000000000c1'::uuid, 1,
  '{"mode": "active",
    "instructions": "Atendé pedidos contra entrega",
    "model_tier": "equilibrado",
    "guardrails": "No prometas fechas de entrega que no estén en el perfil.",
    "tools": [
      {"provider": "local", "type": "function", "name": "calculator"},
      {"provider": "local", "type": "sql", "label": "pedidos"}
    ]}'::jsonb,
  'hash-v1', 'primera'
);

-- ---------------------------------------------------------------------------
-- Resolving the two layers. Pure function, so it is checked directly — the
-- TypeScript twin is checked against this one in
-- `_traces/agent_config_parity.test.ts`.
-- ---------------------------------------------------------------------------

-- The case that must stay an identity: an agent with no template at all. Every
-- agent in the product is one of these today, so anything but "unchanged" here
-- is a regression for every organization.
select is(
  public.resolve_agent_config(
    null,
    '{"mode": "active", "instructions": "mías", "tools": [{"provider": "local", "type": "http", "label": "erp", "config": {"url": "https://erp.interno"}}]}'::jsonb
  ),
  '{"mode": "active", "instructions": "mías", "tools": [{"provider": "local", "type": "http", "label": "erp", "config": {"url": "https://erp.interno"}}]}'::jsonb,
  'no template: the layer IS the configuration, untouched'
);

select is(
  public.resolve_agent_config(
    '{"instructions": "de la plantilla", "model_tier": "equilibrado"}'::jsonb,
    '{"instructions": "mías"}'::jsonb
  ),
  '{"instructions": "mías", "model_tier": "equilibrado"}'::jsonb,
  'the layer overrides what it names and inherits what it does not'
);

-- A mask is not a value. `agent_template_config` keeps the source agent's
-- `api_key` as '********' on purpose — it says the template expects one — and
-- T4 assumed install would write that through extract_secrets, which strips a
-- mask with nothing behind it. Under a LAYERED install nothing of the template
-- is ever written to `agents.extra`, so that stripping never happens and the
-- mask would arrive at the provider as the key. It is dropped here instead.
select is(
  public.resolve_agent_config(
    '{"api_key": "********", "instructions": "de la plantilla"}'::jsonb,
    '{}'::jsonb
  ),
  '{"instructions": "de la plantilla"}'::jsonb,
  'a masked value of the template never becomes the effective configuration'
);

select is(
  public.resolve_agent_config(
    '{"guardrails": "No prometas fechas"}'::jsonb,
    '{"guardrails": "Prometé lo que sea"}'::jsonb
  ),
  '{"guardrails": "No prometas fechas"}'::jsonb,
  'guardrails are the template''s: the layer cannot unlock them'
);

-- Tools. The template declares them; the organization connects them.
select is(
  public.resolve_agent_config(
    '{"tools": [{"provider": "local", "type": "sql", "label": "pedidos"}]}'::jsonb,
    '{}'::jsonb
  ),
  '{"tools": []}'::jsonb,
  'a tool with no connection does not run — it is left out, not half-built'
);

select is(
  public.resolve_agent_config(
    '{"tools": [{"provider": "local", "type": "sql", "label": "pedidos"}]}'::jsonb,
    '{"tools": [{"provider": "local", "type": "sql", "label": "pedidos", "config": {"driver": "postgres", "host": "db.tienda"}}]}'::jsonb
  ),
  '{"tools": [{"provider": "local", "type": "sql", "label": "pedidos", "config": {"driver": "postgres", "host": "db.tienda"}}]}'::jsonb,
  'the organization''s connection merges into the template''s tool by identity'
);

select is(
  public.resolve_agent_config(
    '{"tools": [{"provider": "local", "type": "sql", "label": "pedidos"}]}'::jsonb,
    '{"tools": [{"provider": "local", "type": "sql", "label": "otra-base", "config": {"driver": "postgres"}}]}'::jsonb
  ) -> 'tools' -> 0 ->> 'label',
  'otra-base',
  'a tool of a different identity is a tool of its own, kept as the organization''s'
);

select is(
  jsonb_array_length(
    public.resolve_agent_config(
      '{"tools": [{"provider": "local", "type": "function", "name": "calculator"}]}'::jsonb,
      '{"tools": [{"provider": "local", "type": "http", "label": "erp", "config": {"url": "https://erp"}}]}'::jsonb
    ) -> 'tools'
  ),
  2,
  'a tool that needs no connection runs as published, alongside the organization''s own'
);

-- ---------------------------------------------------------------------------
-- Installing.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('amber@test.local');
select throws_ok(
  $$select public.install_agent_template(
      tests.id('org_a'), 'dddddddd-0000-4000-8000-0000000000c1'::uuid)$$,
  '42501',
  null,
  'a member does not install a template: it creates an AI agent'
);
select tests.clear_authentication();

select tests.authenticate_as('alice@test.local');

select lives_ok(
  $$select public.install_agent_template(
      tests.id('org_a'), 'dddddddd-0000-4000-8000-0000000000c1'::uuid)$$,
  'the admin installs it'
);

select tests.clear_authentication();

select is(
  (select extra ->> 'mode' from public.agents
   where organization_id = tests.id('org_a') and template_id is not null),
  'draft',
  'and it is born in draft (B4): a template does not start answering by itself'
);

select is(
  (select template_version from public.agents
   where organization_id = tests.id('org_a') and template_id is not null),
  1,
  'pinned to the version that was current when it was installed'
);

select is(
  (select template_auto_update from public.agents
   where organization_id = tests.id('org_a') and template_id is not null),
  false,
  'and updating is opt-in (D7)'
);

-- A version that was never published cannot be claimed: the composite foreign
-- key is against (template_id, version), not against the template alone.
select throws_ok(
  $$update public.agents set template_version = 99
    where organization_id = tests.id('org_a') and template_id is not null$$,
  '23503',
  null,
  'an agent cannot claim a version nobody published'
);

select throws_ok(
  $$update public.agents set template_version = null
    where organization_id = tests.id('org_a') and template_id is not null$$,
  '23514',
  null,
  'and cannot keep half a reference'
);

-- Cross-tenant: bob owns B and is also the platform admin, so if anything were
-- going to let a write cross, it would be him.
select tests.authenticate_as('bob@test.local');

update public.agents
set template_auto_update = true
where organization_id = tests.id('org_a');

select tests.clear_authentication();
select is(
  (select bool_or(template_auto_update) from public.agents
   where organization_id = tests.id('org_a') and template_id is not null),
  false,
  'the owner of another organization does not touch this agent''s template'
);

-- ---------------------------------------------------------------------------
-- Updating: by hand, and by having asked for it.
-- ---------------------------------------------------------------------------

insert into public.agent_template_versions
  (template_id, version, config, config_hash, changelog)
values (
  'dddddddd-0000-4000-8000-0000000000c1'::uuid, 2,
  '{"mode": "active", "instructions": "Segunda versión"}'::jsonb,
  'hash-v2', 'segunda'
);

select is(
  (select template_version from public.agents
   where organization_id = tests.id('org_a') and template_id is not null),
  1,
  'publishing a version moves nobody on its own (D7)'
);

select tests.authenticate_as('alice@test.local');
select lives_ok(
  $$select public.update_agent_template_version(
      (select id from public.agents
       where organization_id = tests.id('org_a') and template_id is not null))$$,
  'the admin takes the update'
);
select tests.clear_authentication();

select is(
  (select template_version from public.agents
   where organization_id = tests.id('org_a') and template_id is not null),
  2,
  'and lands on the newest version that is not retired'
);

-- Auto-update: the same act of publishing, for an agent that asked for it.
update public.agents set template_auto_update = true, template_version = 1
where organization_id = tests.id('org_a') and template_id is not null;

update public.agents
set extra = '{"instructions": "cambia el hash"}'::jsonb
where id = 'dddddddd-0000-4000-8000-0000000000a1'::uuid;

select tests.authenticate_as('bob@test.local');
select lives_ok(
  $$select public.publish_agent_template_version(
      'dddddddd-0000-4000-8000-0000000000c1'::uuid, 'tercera')$$,
  'the platform publishes a third version'
);
select tests.clear_authentication();

select is(
  (select template_version from public.agents
   where organization_id = tests.id('org_a') and template_id is not null),
  3,
  'an agent that asked for automatic updates is already on it'
);

-- ---------------------------------------------------------------------------
-- Unlinking: the configuration stops being a pointer and becomes the agent's.
-- ---------------------------------------------------------------------------

update public.agents
set template_auto_update = false, template_version = 1,
    extra = '{"tools": [{"provider": "local", "type": "sql", "label": "pedidos", "config": {"driver": "postgres", "host": "db.tienda"}}]}'::jsonb
where organization_id = tests.id('org_a') and template_id is not null;

select tests.authenticate_as('alice@test.local');
select lives_ok(
  $$select public.unlink_agent_template(
      (select id from public.agents
       where organization_id = tests.id('org_a') and template_id is not null))$$,
  'the admin unlinks it'
);
select tests.clear_authentication();

select is(
  (select count(*)::int from public.agents
   where organization_id = tests.id('org_a') and template_id is not null),
  0,
  'the pointer is gone'
);

select is(
  (select extra ->> 'instructions' from public.agents
   where organization_id = tests.id('org_a') and name = 'Ventas contra entrega'),
  'Atendé pedidos contra entrega',
  'and what the template used to say is now the agent''s own configuration'
);

-- By label, not by index: the resolved list is in the TEMPLATE's order, and
-- the template declares the calculator first. Which is worth stating — an
-- organization's tool order follows the version, not the order they connected
-- things in.
select is(
  (select t.tool #>> '{config,host}'
   from public.agents a,
        jsonb_array_elements(a.extra -> 'tools') as t(tool)
   where a.organization_id = tests.id('org_a')
     and a.name = 'Ventas contra entrega'
     and t.tool ->> 'label' = 'pedidos'),
  'db.tienda',
  'with the organization''s own connection frozen into it'
);

-- ---------------------------------------------------------------------------
-- T7 needs one thing T6 did not give it: an organization has to be able to
-- read the version ITS OWN agent runs on, even when that version was retired
-- or its template archived.
--
-- Otherwise the screen of an installed agent goes blank exactly when it most
-- needs to explain itself: B3 says the base instructions are readable, and
-- «this version was retired» is the notice that tells somebody why they should
-- move. The catalogue policy hides retired versions on purpose — that is how
-- the platform stops handing something out — so what is missing is a second,
-- narrower door.
-- ---------------------------------------------------------------------------

-- Put the agent back on the template and retire the version it is on.
update public.agents
set template_id = 'dddddddd-0000-4000-8000-0000000000c1'::uuid,
    template_version = 1
where organization_id = tests.id('org_a') and name = 'Ventas contra entrega';

update public.agent_template_versions
set retired_at = now()
where template_id = 'dddddddd-0000-4000-8000-0000000000c1'::uuid and version = 1;

select tests.authenticate_as('alice@test.local');

select is(
  (select count(*)::int from public.agent_template_versions
   where template_id = 'dddddddd-0000-4000-8000-0000000000c1'::uuid
     and version = 1),
  1,
  'an organization reads the retired version its own agent still runs on'
);

select tests.clear_authentication();

-- And the door is exactly that narrow: another organization's agent being on a
-- version is not a reason for THIS one to read it. Bob stops being the
-- platform admin for this one assertion — as one, he reads every version
-- there is, which would make the check pass for the wrong reason.
delete from public.platform_admins where user_id = tests.id('user_bob');

select tests.authenticate_as('bob@test.local');

select is(
  (select count(*)::int from public.agent_template_versions
   where template_id = 'dddddddd-0000-4000-8000-0000000000c1'::uuid
     and version = 1),
  0,
  'and nobody else reads it through somebody else''s install'
);

select tests.clear_authentication();

-- ---------------------------------------------------------------------------
-- Privileges. `db diff` does not model function EXECUTE at all — it reports
-- "no schema changes" while every one of these stays callable by anon — so the
-- grants are hand-written in the migration and asserted here, which is the
-- only place that would notice them going missing.
-- ---------------------------------------------------------------------------

select ok(
  not has_function_privilege('anon', 'public.agent_tool_key(jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'public.agent_tool_ready(jsonb)', 'execute'),
  'the two helpers of the resolver are private'
);

select ok(
  has_function_privilege('authenticated', 'public.resolve_agent_config(jsonb, jsonb)', 'execute')
  and not has_function_privilege('service_role', 'public.install_agent_template(uuid, uuid, integer, text)', 'execute'),
  'the resolver is callable and installing is not something the server does for you'
);

select * from finish();
rollback;
