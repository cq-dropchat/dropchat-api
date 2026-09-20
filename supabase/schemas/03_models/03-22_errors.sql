-- E1. Crash reporting without an external APM.
--
-- The unit of storage is the *issue* — one row per distinct error — not the
-- occurrence. The second time a bug fires it costs an UPDATE of two counters,
-- so the table grows with the number of distinct bugs, not with traffic. That
-- is what makes "only persist new errors" literal rather than a filter applied
-- when reading.
--
-- public.logs is not this table and cannot become it: it is a per-tenant audit
-- trail (organization_id not null, members read it, integrators receive it by
-- webhook). A crash in the browser before login, or an Edge Function that dies
-- with no organization in scope, has no row to write there.

-- Where the error was captured. The client does not get to choose: report_error
-- derives it from who is calling (service key → 'edge', anyone else →
-- 'frontend'), so a browser cannot post an issue that looks like a backend one.
create type public.error_source as enum ('frontend', 'edge', 'db');

-- 'preexisting' is the one that earns its keep: it is what a fingerprint gets
-- while the baseline is open (see error_settings). Those rows are recorded and
-- counted like any other, but the panel hides them — so the day this ships the
-- panel is empty instead of being a list of everything that was already broken.
--
-- Nothing ever leaves 'preexisting' on its own: an old bug firing again is
-- still an old bug. Only a person reopens it from the panel.
create type public.error_status as enum (
  'new',
  'acknowledged',
  'resolved',
  'ignored',
  'preexisting'
);

-- Who may see the panel. There is no platform-wide role in this schema: every
-- permission is a membership in an organization (public.role), and an error
-- panel is the opposite of that — it crosses tenants by definition. Hence a
-- table instead of a flag on a member: it belongs to nobody's organization.
--
-- No policy grants INSERT: rows are added from the SQL editor or a migration,
-- never through the API. An admin who could appoint admins is a privilege
-- escalation from a single stolen session.
create table public.platform_admins (
  user_id uuid not null references auth.users(id) on delete cascade,
  note text,
  created_at timestamp with time zone not null default now()
);

alter table only public.platform_admins
add constraint platform_admins_pkey primary key (user_id);

-- Single-row settings table (the `check (id)` is what makes it single-row).
--
-- baseline_open is the manual switch: while it is true every fingerprint seen
-- for the first time is filed as 'preexisting'. Closing it is a deliberate act
-- from the panel — "from here on, surprise me" — and there is no timer that
-- closes it for you. A fixed window would file as "new" any bug living in a
-- screen nobody happened to open during it, which is the exact noise this is
-- meant to prevent.
--
-- The table ships EMPTY, and an absent row reads as "baseline open" everywhere
-- (close_error_baseline upserts it; record_error_issue coalesces to true). So
-- the schema stays pure DDL — `supabase/schemas/` is diffed, not executed, and
-- a seed INSERT here would live in the shadow database and never reach a real
-- one — and the default is the safe one: until someone deliberately closes the
-- baseline, nothing surfaces.
create table public.error_settings (
  id boolean not null default true,
  baseline_open boolean not null default true,
  baseline_closed_at timestamp with time zone,
  baseline_closed_by uuid references auth.users(id) on delete set null,
  updated_at timestamp with time zone not null default now()
);

alter table only public.error_settings
add constraint error_settings_pkey primary key (id);

alter table only public.error_settings
add constraint error_settings_singleton check (id);

create table public.error_issues (
  id uuid not null default gen_random_uuid(),
  -- md5 of source + kind + the normalized message + culprit (see
  -- public.error_fingerprint). Not a security hash: it groups occurrences.
  fingerprint text not null,
  source public.error_source not null,
  -- The error's class: 'TypeError', 'PostgrestError', the name of a thrown
  -- Error. Free text because every runtime names them differently.
  kind text not null,
  -- The message as it first arrived, untouched — the normalized form is only
  -- ever an input to the fingerprint. A message with the ids stripped out is
  -- unreadable, and reading it is the whole point.
  title text not null,
  -- Where it happened, in whatever terms the source can offer: the Edge
  -- Function's name, the route the browser was on, the top stack frame.
  culprit text,
  -- The build the issue was FIRST seen in. Kept from the first occurrence on
  -- purpose: "which deploy introduced this" is the question worth answering.
  release text,
  status public.error_status not null default 'new',
  first_seen timestamp with time zone not null default now(),
  last_seen timestamp with time zone not null default now(),
  -- When a 'resolved' issue fired again. Sentry calls it a regression; here it
  -- is what flips the row back to 'new' so it returns to the panel.
  regressed_at timestamp with time zone,
  events bigint not null default 1,
  -- Two occurrences, not a history: the first (what it looked like when it
  -- appeared) and the most recent (what it looks like now). Stack, url,
  -- request_id, browser, organization, user. A third table of every occurrence
  -- would reintroduce exactly the growth this design avoids; the counter
  -- answers "how often" and these two answer "what happened".
  first_sample jsonb not null default '{}'::jsonb,
  last_sample jsonb not null default '{}'::jsonb,
  -- Free text for whoever triages: "this is Safari 16 only", a ticket id.
  notes text,
  -- No resolved_at/resolved_by: `status` and `updated_at` already say what was
  -- decided and when, and the UPDATE grant below is narrow enough that the
  -- only way updated_at moves is a person triaging from the panel. Who did it
  -- is a question with one possible answer while platform_admins has one row.
  updated_at timestamp with time zone not null default now()
);

alter table only public.error_issues
add constraint error_issues_pkey primary key (id);

-- The dedupe hinges on this: report_error's upsert targets it.
alter table only public.error_issues
add constraint error_issues_fingerprint_key unique (fingerprint);

-- The panel's default view: open issues, most recent first.
create index idx_error_issues_status_last_seen
on public.error_issues
using btree (status, last_seen desc);

-- The hourly cap in report_error counts new fingerprints over a window.
create index idx_error_issues_first_seen
on public.error_issues
using btree (first_seen desc);

create trigger handle_updated_at
before update
on public.error_issues
for each row
execute function public.moddatetime('updated_at');
