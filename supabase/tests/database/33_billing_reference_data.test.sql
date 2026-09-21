-- Billing reference data ships as a migration, not as seed.
--
-- Failure scenario, observed in production on 2026-09-21: `billing.products`,
-- `billing.costs` and the four commercial tables lived only in `seed.sql`,
-- which runs on `supabase db reset` and never against a deployed project. The
-- schema was there and every row was missing, and nothing said so:
--
--   * an agent on platform credits died with `No pricing found for
--     groq/openai/gpt-oss-20b` the first time anybody ran one — which was
--     eight months after billing shipped, because until the simulator (S1)
--     no agent had ever answered in production;
--   * `billing.guard_ledger_insert` returns NULL for an unknown product, and
--     a BEFORE INSERT trigger returning NULL drops the row. With no products
--     every consumption entry was discarded **in silence**, so the one table
--     that carries `agent_id` — the source M1 aggregates cost from — stayed
--     empty and no error was ever raised;
--   * `billing.initialize_subscription` returns early when no tier exists, so
--     every organization created in production has no subscription at all.
--
-- This file pins the half that is not a commercial decision. Tiers and plans
-- stay out on purpose: what a plan includes is a business choice that is not
-- made yet, and freezing it in a migration would decide it by accident.
begin;
select plan(16);

-- ---------------------------------------------------------------------------
-- Products: the vocabulary the triggers branch on.
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int from billing.products
   where id in ('messages', 'messages_inbound', 'conversations',
                'storage', 'ai_credits')),
  5,
  'the five products exist'
);

-- `check_limit` branches on `kind`, and `guard_ledger_insert` drops any row
-- whose product is missing. A wrong kind is as bad as a missing row.
select is(
  (select kind from billing.products where id = 'ai_credits'),
  'balance',
  'ai_credits is a balance, so a reservation can draw it down'
);

select is(
  (select kind from billing.products where id = 'storage'),
  'gauge',
  'storage is a gauge, measured rather than counted'
);

select is(
  (select count(*)::int from billing.products
   where id in ('messages', 'messages_inbound', 'conversations')
     and kind = 'counter'),
  3,
  'the three message-shaped products are counters'
);

-- The guard that made the silence possible, stated as a test.
select lives_ok(
  $$ insert into billing.ledger (organization_id, product_id, type, quantity, billable)
     values (tests.id('org_a'), 'ai_credits', 'consumption', 0.01, true) $$,
  'a ledger entry for a known product is accepted'
);

select is(
  (select count(*)::int from billing.ledger
   where organization_id = tests.id('org_a') and product_id = 'ai_credits'
     and quantity = 0.01),
  1,
  'and it is actually there — the guard drops unknown products silently'
);

-- ---------------------------------------------------------------------------
-- Costs: every model the code can reach for has a price.
-- ---------------------------------------------------------------------------

-- The per-provider defaults of agent-client (protocols/chat-completions.ts
-- and protocols/responses.ts): an agent that names only a provider gets these.
select is(
  (select count(*)::int from billing.costs
   where (provider, product) in (
     ('groq',      'openai/gpt-oss-20b'),
     ('anthropic', 'claude-sonnet-4-6'),
     ('google',    'gemini-3-flash-preview'),
     ('openai',    'gpt-5-mini')
   )),
  4,
  'every provider default of agent-client has a price'
);

-- The models the UI offers as covered by credits (routes/_auth/agents/new.tsx,
-- `creditModels`) beyond the defaults above.
select is(
  (select count(*)::int from billing.costs
   where (provider, product) in (
     ('groq',      'openai/gpt-oss-120b'),
     ('google',    'gemini-2.5-flash'),
     ('anthropic', 'claude-sonnet-5')
   )),
  3,
  'every other credit-covered model has a price'
);

-- media-preprocessor accepts gemini-2.5-pro (extra_types.ts:
-- PreprocessingConfig.model) and priced only the flash default until now.
select isnt(
  (select pricing from billing.costs
   where provider = 'google' and product = 'gemini-2.5-pro'),
  null,
  'the other model of the media preprocessor is priced too'
);

-- ---------------------------------------------------------------------------
-- Shape. `estimate_ai_cost` reads `input` and `output` and coalesces a missing
-- one to zero, so a typo in a key prices that side at nothing rather than
-- failing. It also divides by `quantity`.
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int from billing.costs
   where unit = 'tokens'
     and (pricing -> 'input') is null),
  0,
  'every token price names its input'
);

select is(
  (select count(*)::int from billing.costs
   where unit = 'tokens'
     and (pricing -> 'output') is null),
  0,
  'every token price names its output'
);

select is(
  (select count(*)::int from billing.costs
   where unit = 'tokens'
     and (jsonb_typeof(pricing -> 'input') <> 'number'
          or jsonb_typeof(pricing -> 'output') <> 'number')),
  0,
  'and both are numbers, not strings'
);

select is(
  (select count(*)::int from billing.costs where coalesce(quantity, 0) <= 0),
  0,
  'no row divides by zero'
);

select is(
  (select count(*)::int from billing.costs
   where unit = 'tokens' and quantity <> 1000000),
  0,
  'token prices are all per million, so they can be compared'
);

-- The estimate is what a call is blocked on, so it has to be a real number
-- for a real model, not zero.
select ok(
  (select billing.estimate_ai_cost(pricing, quantity, 12000, 1000) > 0
   from billing.costs
   where provider = 'groq' and product = 'openai/gpt-oss-20b'
   order by effective_at desc limit 1),
  'the default model estimates a cost above zero'
);

-- ---------------------------------------------------------------------------
-- What deliberately stays out.
-- ---------------------------------------------------------------------------

-- Nothing reads `provider = 'whatsapp'`: the only consumers of this table are
-- agent-client's two protocols and media-preprocessor, all of which look up
-- the agent's own provider. The rows that were here priced Argentina while
-- the market is Chile, which is the kind of wrong that survives precisely
-- because nobody reads it.
select is(
  (select count(*)::int from billing.costs where provider = 'whatsapp'),
  0,
  'no WhatsApp template prices: nothing reads them, and they named the wrong country'
);

select * from finish();
rollback;
