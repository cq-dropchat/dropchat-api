-- T2 — los niveles de modelo: una tabla en vez de un string por agente.
--
-- Failure scenario, and it is not hypothetical: a template (T4) that names
-- `gpt-5-mini` names it for every organization that installs it, so the day
-- the provider retires that id every one of them stops answering at once, and
-- the fix is a write per agent. A tier is the indirection that makes it one
-- UPDATE.
--
-- Two things this file guards, and the second is the quiet one.
--
-- PRICE. `provider` + `model` is the key against `billing.costs`, and a call
-- on platform credits with no price row does not degrade — it THROWS
-- `No pricing found for ${provider}/${model}`. A tier pointing at an unpriced
-- model is an agent that cannot answer, so every tier is checked against the
-- price table here, where it is cheap, instead of in production.
--
-- PROTOCOL. Not every provider speaks both protocols: Google's OpenAI-compat
-- layer 404s on /responses and Anthropic speaks its own Messages API. A tier
-- with `anthropic` + `responses` does not fail loudly either — the resolver
-- falls through to its default branch and the agent quietly talks to a base
-- URL called "anthropic" as `provider = custom`, unpriced. The CHECK refuses
-- that combination; this pins the CHECK.
begin;
select plan(16);

-- Bob is the platform admin for this transaction, as in 34.
insert into public.platform_admins (user_id, note)
values (tests.id('user_bob'), 'admin de prueba');

-- ---------------------------------------------------------------------------
-- The reference rows, and what they point at.
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int from public.model_tiers),
  3,
  'the three tiers of the spec are seeded, no more'
);

select is(
  (select array_agg(slug order by slug)::text from public.model_tiers),
  '{avanzado,equilibrado,rapido}',
  'and they are the slugs the spec names'
);

-- The assertion the item exists for.
select is(
  (select count(*)::int
   from public.model_tiers t
   where not exists (
     select 1 from billing.costs c
     where c.provider = t.provider and c.product = t.model
   )),
  0,
  'every tier points at a model billing.costs has a price for'
);

-- Non-vacuity: the query above would also read 0 if it were comparing the
-- wrong columns, so show it finds something when there IS something to find.
select is(
  (select count(*)::int
   from (select 'groq'::text as provider, 'modelo-que-no-existe'::text as model) t
   where not exists (
     select 1 from billing.costs c
     where c.provider = t.provider and c.product = t.model
   )),
  1,
  'and the check is not vacuous: an unpriced pair is found'
);

select is(
  (select bool_and(supports_forced_tools) from public.model_tiers),
  true,
  'every seeded tier accepts a forced tool, which multi_message_response needs'
);

-- ---------------------------------------------------------------------------
-- What may be stored at all.
-- ---------------------------------------------------------------------------

select throws_ok(
  $$insert into public.model_tiers (slug, name, provider, model, protocol)
    values ('roto', 'Roto', 'anthropic', 'claude-sonnet-5', 'responses')$$,
  '23514',
  null,
  'a provider that does not speak the protocol is refused by the table'
);

select lives_ok(
  $$insert into public.model_tiers (slug, name, provider, model, protocol)
    values ('valido', 'Válido', 'groq', 'openai/gpt-oss-20b', 'responses')$$,
  'and the same protocol on a provider that does speak it is fine'
);

select throws_ok(
  $$insert into public.model_tiers (slug, name, provider, model, protocol)
    values ('otro', 'Otro', 'inventado', 'x', 'chat_completions')$$,
  '23514',
  null,
  'a provider the code cannot reach is refused'
);

-- The tripwire. The list of providers lives twice by necessity — here as a
-- CHECK, and in `_shared/types/model_providers.ts` as the map that says how to
-- reach each one. Adding a provider on one side and not the other is the
-- failure this assertion is meant to make loud: it breaks, and whoever fixes
-- it has to look at both.
select is(
  (select pg_get_constraintdef(oid) from pg_constraint
   where conrelid = 'public.model_tiers'::regclass
     and conname = 'model_tiers_provider_known'),
  'CHECK ((provider = ANY (ARRAY[''openai''::text, ''anthropic''::text, ''google''::text, ''groq''::text])))',
  'and the providers it accepts are exactly the four the resolver knows'
);

delete from public.model_tiers where slug = 'valido';

-- ---------------------------------------------------------------------------
-- Who reads and who writes. The table is global, like the template catalogue:
-- every member of every organization reads the same three rows.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('amber@test.local');
select is(
  (select count(*)::int from public.model_tiers),
  3,
  'a member reads the tiers'
);
select throws_ok(
  $$insert into public.model_tiers (slug, name, provider, model)
    values ('mio', 'Mío', 'openai', 'gpt-5-mini')$$,
  '42501',
  null,
  'and does not write them'
);
select tests.clear_authentication();

select tests.authenticate_with_api_key(tests.val('key_a_member'));
select is(
  (select count(*)::int from public.model_tiers),
  3,
  'an API key reads them too — the agent form is built from this'
);
select tests.clear_authentication();

select tests.authenticate_with_api_key(tests.val('key_a_owner'));
select throws_ok(
  $$insert into public.model_tiers (slug, name, provider, model)
    values ('mio', 'Mío', 'openai', 'gpt-5-mini')$$,
  '42501',
  null,
  'an owner API key does not write them: this is not an organization setting'
);
select tests.clear_authentication();

select tests.authenticate_as_anon();
select is(
  (select count(*)::int from public.model_tiers),
  3,
  'anon reads them: the tiers are a catalogue, not tenant data'
);
select throws_ok(
  $$insert into public.model_tiers (slug, name, provider, model)
    values ('mio', 'Mío', 'openai', 'gpt-5-mini')$$,
  '42501',
  null,
  'and writes nothing'
);
select tests.clear_authentication();

select tests.authenticate_as('bob@test.local');
select lives_ok(
  $$update public.model_tiers set model = 'claude-sonnet-4-6'
    where slug = 'avanzado'$$,
  'the platform admin retires a model without a deploy, which is the point'
);
select tests.clear_authentication();

select * from finish();
rollback;
