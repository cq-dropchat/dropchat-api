-- T5. The drills a template has to pass, and the record of having run them.
--
-- Two tables, and the split is the point. A DRILL is a definition — a business
-- profile (T1), what the customer says, and what the answer must and must not
-- contain. A RUN is what happened when that definition met a version.
--
-- Both are the platform's, not a tenant's: these are what decide whether a
-- version goes out to everybody. A drill a tenant could edit is a gate a
-- tenant could open.
create table public.agent_template_tests (
  id uuid default gen_random_uuid() not null,
  template_id uuid not null,
  name text not null,
  -- A business profile of the shape T1 stores, used as the organization's own
  -- for the drill. It is what makes a drill about a KIND of business rather
  -- than about a prompt: the same template answers differently for a bakery
  -- and for a shoe shop, and that difference is what is being tested.
  profile jsonb default '{}'::jsonb not null,
  -- What the customer says, in order: [{"text": "...", "referral": {...}}].
  turns jsonb not null,
  -- `must_include` / `must_not_include` (text or `/regex/flags`),
  -- `expect_escalation` (true, false, or {"category": "..."}), and
  -- `expect_tool_call` (a `type:label` tool identity). The authority on what
  -- these mean is `_shared/template_tests.ts`, which is also the only thing
  -- that evaluates them.
  expectations jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.agent_template_tests
add constraint agent_template_tests_pkey primary key (id);

alter table only public.agent_template_tests
add constraint agent_template_tests_template_id_name_key
unique (template_id, name);

alter table only public.agent_template_tests
add constraint agent_template_tests_template_id_fkey
foreign key (template_id)
references public.agent_templates(id)
on delete cascade;

-- A drill with nothing to say is not a drill, and a single turn written as an
-- object instead of a list is the mistake that would produce one.
alter table only public.agent_template_tests
add constraint agent_template_tests_turns_shape
check (jsonb_typeof(turns) = 'array' and jsonb_array_length(turns) > 0);

alter table only public.agent_template_tests
add constraint agent_template_tests_expectations_shape
check (jsonb_typeof(expectations) = 'object');

create trigger set_updated_at
before update
on public.agent_template_tests
for each row
execute function public.moddatetime('updated_at');

-- The run: the auditable half, and the item's own acceptance criterion —
-- «guardar la corrida completa para poder auditarla».
--
-- `test_id` is `on delete set null` and that is the whole design of this
-- table: deleting a drill must not erase the evidence that a version was
-- published on the strength of it. That is precisely the record somebody
-- would want gone.
create table public.agent_template_test_runs (
  id uuid default gen_random_uuid() not null,
  test_id uuid,
  template_id uuid not null,
  version integer not null,
  status text default 'running'::text not null,
  -- The gate. Deterministic expectations are 100 % or the run failed; an LLM
  -- judge has variance and cannot decide that (§12).
  deterministic_total integer default 0 not null,
  deterministic_passed integer default 0 not null,
  -- 0..1, null when no rubric ran. Informative, never a gate.
  judge_score numeric,
  /** The whole conversation, as `_shared/template_tests.ts` reads it. */
  transcript jsonb default '[]'::jsonb not null,
  -- One sentence per failed expectation, so the panel does not have to
  -- re-evaluate anything to explain a failure.
  failures jsonb default '[]'::jsonb not null,
  error text,
  started_at timestamp with time zone default now() not null,
  finished_at timestamp with time zone
);

alter table only public.agent_template_test_runs
add constraint agent_template_test_runs_pkey primary key (id);

alter table only public.agent_template_test_runs
add constraint agent_template_test_runs_test_id_fkey
foreign key (test_id)
references public.agent_template_tests(id)
on delete set null;

-- Composite, like an installed agent's: a run of a version nobody published
-- is a run of nothing.
alter table only public.agent_template_test_runs
add constraint agent_template_test_runs_version_fkey
foreign key (template_id, version)
references public.agent_template_versions(template_id, version)
on delete cascade;

alter table only public.agent_template_test_runs
add constraint agent_template_test_runs_status_known
check (status in ('running', 'passed', 'failed', 'error'));

create index agent_template_test_runs_template_idx
on public.agent_template_test_runs
using btree (template_id, version, started_at desc);
