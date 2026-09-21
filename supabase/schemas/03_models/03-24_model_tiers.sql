-- T2. Model tiers: «rápido», «equilibrado», «avanzado» instead of a model id
-- typed into every agent.
--
-- The problem is not that `gpt-5-mini` is a bad default. It is that it is
-- written down in as many places as there are agents, and a template (T4)
-- writes it into every organization that installs it. The day a provider
-- retires a model, every one of those agents stops answering at once and the
-- repair is a write per agent. A tier turns that into one UPDATE here.
--
-- GLOBAL, like the template catalogue: three rows that every organization
-- reads and only a platform admin writes.
--
-- What is NOT here is how to reach each provider — the base URL, the name of
-- the environment variable holding its key, and which protocols it answers.
-- That lives in `_shared/types/model_providers.ts`, in code, and the split is
-- deliberate: a model changes when a provider retires one, and should not
-- need a deploy; a PROVIDER cannot be added without a deploy anyway, because
-- its secret has to reach the function's environment first.
create table public.model_tiers (
  slug text not null,
  name text not null,
  description text,
  provider text not null,
  model text not null,
  protocol text not null default 'chat_completions',
  -- `multi_message_response` (default ON) hands the model a synthetic
  -- `respond` tool with `tool_choice: "required"`, which is how one turn
  -- becomes three bubbles. A reasoning-mode model rejects that outright, so a
  -- tier that points at one has to say so here — the agent then answers in
  -- plain text instead of failing.
  supports_forced_tools boolean not null default true,
  -- What the picker shows first. Not the slug's alphabetical order, which
  -- would put «avanzado» at the top.
  sort_order integer not null default 0,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now()
);

alter table only public.model_tiers
add constraint model_tiers_pkey primary key (slug);

-- The four the resolver knows how to reach. This list exists twice by
-- necessity — here, and as the map in `_shared/types/model_providers.ts` — so
-- `38_model_tiers.test.sql` asserts this constraint's text verbatim: adding a
-- provider on one side and not the other breaks a test instead of producing an
-- agent that talks to a base URL named after a company.
alter table only public.model_tiers
add constraint model_tiers_provider_known
check (provider in ('openai', 'anthropic', 'google', 'groq'));

alter table only public.model_tiers
add constraint model_tiers_protocol_known
check (protocol in ('chat_completions', 'responses'));

-- Google's OpenAI-compat layer 404s on /responses and Anthropic speaks its own
-- Messages API, so those two are chat_completions only. Without this, a tier
-- with `anthropic` + `responses` would not fail loudly: the resolver falls
-- through to its default branch, the agent talks to a base URL called
-- "anthropic" as `provider = custom`, and the call is unpriced.
alter table only public.model_tiers
add constraint model_tiers_protocol_supported
check (protocol = 'chat_completions' or provider in ('openai', 'groq'));

create trigger set_updated_at
before update
on public.model_tiers
for each row
execute function public.moddatetime('updated_at');
