-- Billing reference data: the products the triggers branch on, and the
-- provider prices a platform-credits call is blocked on.
--
-- Hand-written DML, which is one of the cases `db diff` cannot produce.
--
-- WHY THIS EXISTS. Both tables lived only in `supabase/seed.sql`, which runs
-- on `supabase db reset` and never against a deployed project. Production had
-- the schema and none of the rows, and three things failed without saying so:
--
--   1. `No pricing found for groq/openai/gpt-oss-20b` — the first agent to
--      run on platform credits, eight months after billing shipped, because
--      until the simulator (S1) no agent had ever answered in production.
--   2. `guard_ledger_insert` returns NULL for an unknown product, and a
--      BEFORE INSERT trigger returning NULL drops the row. Every consumption
--      entry was discarded in silence, leaving `billing.ledger` — the only
--      table carrying `agent_id`, and the source M1 aggregates cost from —
--      permanently empty.
--   3. `initialize_subscription` returns early with no tier, so every
--      organization created in production has no subscription.
--
-- WHAT STAYS OUT, AND WHY. `tiers`, `plans`, `tiers_products` and
-- `plans_products` remain seed-only. They are the commercial offer — what a
-- plan costs and includes — and that is not decided yet (no company, no
-- pricing sheet signed off). Freezing it in a migration would decide it by
-- accident. Point 3 above therefore stays open on purpose: it is a business
-- decision, not a bug.
--
-- The WhatsApp template rows that were in the seed are also gone. Nothing
-- reads `provider = 'whatsapp'` — the only consumers of this table are
-- agent-client's two protocols and media-preprocessor, which all look up the
-- agent's own provider — and they priced Argentina while the market is Chile.
-- Meta's rates are per country, volume-tiered and published as CSV rate cards
-- rather than in the docs, so when something does need them they should be
-- fetched for Chile (CLP), not inherited from here.

-- ---------------------------------------------------------------------------
-- Products.
-- ---------------------------------------------------------------------------

insert into billing.products (id, name, unit, kind) values
  ('messages',         'Messages',          'count', 'counter'),
  ('messages_inbound', 'Inbound messages',  'count', 'counter'),
  ('conversations',    'Conversations',     'count', 'counter'),
  ('storage',          'Storage',           'gb',    'gauge'),
  ('ai_credits',       'AI Credits',        'usd',   'balance')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Costs. USD per million tokens, read from each provider's own page on
-- 2026-09-21; `effective_at` is fixed rather than `now()` so the primary key
-- is the same in every environment.
--
-- The table holds ONE `input` per model and `estimate_ai_cost` reads only
-- `input` and `output`. Gemini 2.5 Pro charges by prompt size (1.25 up to
-- 200k tokens, 2.50 above); the row below is the low tier, which is the one
-- these conversations hit. A prompt over 200k would be under-charged.
-- ---------------------------------------------------------------------------

insert into billing.costs (provider, product, effective_at, quantity, unit, pricing) values
  -- https://console.groq.com/docs/model/openai/gpt-oss-20b (2026-09-21)
  ('groq', 'openai/gpt-oss-20b', '2026-09-21 00:00:00+00', 1000000, 'tokens',
   '{"input": 0.075, "output": 0.30, "cache_read": 0.037}'),
  -- https://console.groq.com/docs/model/openai/gpt-oss-120b (2026-09-21)
  ('groq', 'openai/gpt-oss-120b', '2026-09-21 00:00:00+00', 1000000, 'tokens',
   '{"input": 0.15, "output": 0.60, "cache_read": 0.075}'),

  -- https://developers.openai.com/api/docs/pricing (2026-09-21)
  ('openai', 'gpt-5-mini', '2026-09-21 00:00:00+00', 1000000, 'tokens',
   '{"input": 0.25, "output": 2.00, "cache_read": 0.025}'),

  -- https://platform.claude.com/docs/en/about-claude/pricing (2026-09-21).
  -- `cache_write` is the 5-minute rate.
  ('anthropic', 'claude-sonnet-4-6', '2026-09-21 00:00:00+00', 1000000, 'tokens',
   '{"input": 3.00, "output": 15.00, "cache_read": 0.30, "cache_write": 3.75}'),
  ('anthropic', 'claude-sonnet-5', '2026-09-21 00:00:00+00', 1000000, 'tokens',
   '{"input": 2.00, "output": 10.00, "cache_read": 0.20, "cache_write": 2.50}'),

  -- https://ai.google.dev/gemini-api/docs/pricing (2026-09-21).
  -- gemini-2.5-flash carried an `audio_cache_read` of 0.10 in the seed; that
  -- figure is not on the page for this model and is left out rather than
  -- copied forward.
  ('google', 'gemini-2.5-flash', '2026-09-21 00:00:00+00', 1000000, 'tokens',
   '{"input": 0.30, "output": 2.50, "cache_read": 0.03, "audio_input": 1.00}'),
  -- Preview pricing, stated on the page as current through 2026-12-31 with an
  -- increase scheduled for 2027-01-01. When the new rate is published, add a
  -- row with that `effective_at` instead of editing this one.
  ('google', 'gemini-3-flash-preview', '2026-09-21 00:00:00+00', 1000000, 'tokens',
   '{"input": 0.50, "output": 3.00, "cache_read": 0.05, "audio_input": 1.00, "audio_cache_read": 0.10}'),
  -- Reachable through media-preprocessor (PreprocessingConfig.model), which
  -- the seed never priced.
  ('google', 'gemini-2.5-pro', '2026-09-21 00:00:00+00', 1000000, 'tokens',
   '{"input": 1.25, "output": 10.00, "cache_read": 0.125}')
on conflict (provider, product, effective_at) do nothing;
