-- T5 — the drills a template has to pass, and the record of having run them.
--
-- Two tables, and the split is the point. A DRILL is a definition: a business
-- profile, what the customer says, and what the answer must and must not
-- contain. A RUN is what happened when that definition met a version — kept
-- so the decision to publish can be audited later, which is the item's own
-- acceptance criterion and not a nice-to-have.
--
-- Both are the platform's. A tenant has no business reading the drills that
-- decide what gets published to everybody, and no business writing them: a
-- drill that a tenant could edit is a gate a tenant could open.
--
-- A run OUTLIVES its drill (`on delete set null`). Deleting a drill must not
-- erase the evidence that a version was published on the strength of it —
-- that is exactly the record somebody would want to remove.
begin;
select plan(14);

insert into public.platform_settings (id, template_org_id)
values (true, tests.id('org_b'));

insert into public.platform_admins (user_id, note)
values (tests.id('user_bob'), 'admin de prueba');

insert into public.agents (id, organization_id, user_id, name, role, extra)
values (
  'ffffffff-0000-4000-8000-0000000000a1'::uuid, tests.id('org_b'), null,
  'Plantillera', 'member', '{"mode": "active", "instructions": "base"}'
);

insert into public.agent_templates (id, slug, name, source_agent_id)
values (
  'ffffffff-0000-4000-8000-0000000000c1'::uuid, 'ventas-contra-entrega',
  'Ventas contra entrega', 'ffffffff-0000-4000-8000-0000000000a1'::uuid
);

insert into public.agent_template_versions
  (template_id, version, config, config_hash)
values (
  'ffffffff-0000-4000-8000-0000000000c1'::uuid, 1,
  '{"instructions": "Atendé pedidos"}'::jsonb, 'hash-v1'
);

insert into public.agent_template_tests
  (id, template_id, name, profile, turns, expectations)
values (
  'ffffffff-0000-4000-8000-0000000000e1'::uuid,
  'ffffffff-0000-4000-8000-0000000000c1'::uuid,
  'pregunta por despacho a regiones',
  '{"industry": "Zapatillas urbanas", "shipping_coverage": "Todo Chile"}'::jsonb,
  '[{"text": "¿llegan a Puerto Montt?"}]'::jsonb,
  '{"must_include": ["Todo Chile"], "must_not_include": ["gratis"]}'::jsonb
);

-- ---------------------------------------------------------------------------
-- The shape of a drill.
-- ---------------------------------------------------------------------------

select throws_ok(
  $$insert into public.agent_template_tests (template_id, name, turns)
    values ('ffffffff-0000-4000-8000-0000000000c1'::uuid,
            'pregunta por despacho a regiones',
            '[{"text": "otra cosa"}]'::jsonb)$$,
  '23505',
  null,
  'two drills of one template cannot share a name'
);

select throws_ok(
  $$insert into public.agent_template_tests (template_id, name, turns)
    values ('ffffffff-0000-4000-8000-0000000000c1'::uuid, 'sin turnos',
            '{"text": "hola"}'::jsonb)$$,
  '23514',
  null,
  'the turns are a list of turns, not one turn'
);

select throws_ok(
  $$insert into public.agent_template_tests (template_id, name, turns)
    values ('ffffffff-0000-4000-8000-0000000000c1'::uuid, 'vacía',
            '[]'::jsonb)$$,
  '23514',
  null,
  'and a drill with nothing to say is not a drill'
);

-- ---------------------------------------------------------------------------
-- Who reads and who writes. Nobody but the platform.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('alice@test.local');
select is(
  (select count(*)::int from public.agent_template_tests),
  0,
  'a tenant does not read the drills that decide what gets published'
);
select throws_ok(
  $$insert into public.agent_template_tests (template_id, name, turns)
    values ('ffffffff-0000-4000-8000-0000000000c1'::uuid, 'mía',
            '[{"text": "hola"}]'::jsonb)$$,
  '42501',
  null,
  'nor writes one: a drill a tenant could edit is a gate a tenant could open'
);
select tests.clear_authentication();

select tests.authenticate_with_api_key(tests.val('key_a_owner'));
select is(
  (select count(*)::int from public.agent_template_tests),
  0,
  'an owner API key reads none either — this is not an organization setting'
);
select tests.clear_authentication();

select tests.authenticate_as_anon();
select is(
  (select count(*)::int from public.agent_template_tests),
  0,
  'and anon reads nothing, without raising'
);
select tests.clear_authentication();

select tests.authenticate_as('bob@test.local');
select is(
  (select count(*)::int from public.agent_template_tests),
  1,
  'the platform admin reads them'
);
select lives_ok(
  $$insert into public.agent_template_tests (template_id, name, turns)
    values ('ffffffff-0000-4000-8000-0000000000c1'::uuid, 'otra prueba',
            '[{"text": "¿cambian talla?"}]'::jsonb)$$,
  'and writes them'
);
select tests.clear_authentication();

-- ---------------------------------------------------------------------------
-- The record of a run, which is the auditable half.
-- ---------------------------------------------------------------------------

insert into public.agent_template_test_runs
  (id, test_id, template_id, version, status,
   deterministic_total, deterministic_passed, transcript)
values (
  'ffffffff-0000-4000-8000-0000000000f1'::uuid,
  'ffffffff-0000-4000-8000-0000000000e1'::uuid,
  'ffffffff-0000-4000-8000-0000000000c1'::uuid, 1, 'passed',
  2, 2,
  '[{"role": "customer", "text": "¿llegan a Puerto Montt?"},
    {"role": "agent", "text": "Sí, despachamos a Todo Chile."}]'::jsonb
);

select throws_ok(
  $$insert into public.agent_template_test_runs
      (template_id, version, status)
    values ('ffffffff-0000-4000-8000-0000000000c1'::uuid, 1, 'inventado')$$,
  '23514',
  null,
  'a run is running, passed, failed or errored, and nothing else'
);

select throws_ok(
  $$insert into public.agent_template_test_runs
      (template_id, version, status)
    values ('ffffffff-0000-4000-8000-0000000000c1'::uuid, 99, 'running')$$,
  '23503',
  null,
  'and it is a run of a version that exists'
);

-- The assertion the table exists for: the evidence outlives the drill.
delete from public.agent_template_tests
where id = 'ffffffff-0000-4000-8000-0000000000e1'::uuid;

select is(
  (select count(*)::int from public.agent_template_test_runs
   where id = 'ffffffff-0000-4000-8000-0000000000f1'::uuid),
  1,
  'deleting a drill does not erase the runs that published a version'
);

select is(
  (select test_id from public.agent_template_test_runs
   where id = 'ffffffff-0000-4000-8000-0000000000f1'::uuid),
  null,
  'the run simply stops naming a drill that is no longer there'
);

select tests.authenticate_as('alice@test.local');
select is(
  (select count(*)::int from public.agent_template_test_runs),
  0,
  'and a tenant reads no runs either'
);
select tests.clear_authentication();

select * from finish();
rollback;
