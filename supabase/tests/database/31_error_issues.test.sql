-- E1 — the error panel's storage rules.
--
-- Failure scenario without this: the panel is only worth opening if what is in
-- it is what you have not seen before. Every property below is one way that
-- stops being true — a fingerprint that fails to group, a baseline that lets
-- the past through, a repeat that reopens a decision a person already made, a
-- grant that lets a browser file a backend error or rewrite the evidence — and
-- each of them turns the panel back into the noise it exists to replace.
begin;
select plan(28);

-- ---------------------------------------------------------------------------
-- Normalization: what makes a stream of messages a countable bug.
-- ---------------------------------------------------------------------------

select is(
  public.normalize_error_message('no encuentro 9f2c8a10-1111-2222-3333-444455556666'),
  public.normalize_error_message('no encuentro aaaabbbb-9999-8888-7777-666655554444'),
  'two uuids in the same sentence normalize alike'
);

select is(
  public.normalize_error_message('falla en item 12345'),
  public.normalize_error_message('falla en item 9'),
  'bare numbers normalize alike'
);

select is(
  public.normalize_error_message('GET https://a.com/x?y=1 fallo'),
  public.normalize_error_message('GET https://b.cl/z fallo'),
  'urls normalize alike'
);

select is(
  public.normalize_error_message('expiro 2026-09-20T10:00:00'),
  public.normalize_error_message('expiro 2026-01-02T03:04:05'),
  'timestamps normalize alike'
);

select is(
  public.normalize_error_message('token abcdef0123456789'),
  public.normalize_error_message('token 0123456789abcdef'),
  'long hex normalizes alike'
);

-- The other half of the job, and the easier one to lose: over-normalizing
-- merges unrelated bugs into one row, which hides them just as effectively.
select isnt(
  public.normalize_error_message('no puedo leer el agente'),
  public.normalize_error_message('no puedo leer el contacto'),
  'genuinely different messages stay apart'
);

select isnt(
  public.error_fingerprint('frontend', 'TypeError', 'x', '/a'),
  public.error_fingerprint('edge', 'TypeError', 'x', '/a'),
  'the same message from a different source is a different issue'
);

select isnt(
  public.error_fingerprint('frontend', 'TypeError', 'x', '/a'),
  public.error_fingerprint('frontend', 'TypeError', 'x', '/b'),
  'the same message from a different culprit is a different issue'
);

-- ---------------------------------------------------------------------------
-- The baseline. No settings row is the shipped state, and it has to read as
-- "open" — a fresh install that filed everything as `new` would hand you a
-- panel full of the past on day one, which is the failure this feature exists
-- to avoid.
-- ---------------------------------------------------------------------------

delete from public.error_issues;
delete from public.error_settings;

select lives_ok(
  $$ select public.report_error('TypeError', 'roto desde antes', '/conversations') $$,
  'reporting works with no settings row at all'
);

select is(
  (select status::text from public.error_issues where kind = 'TypeError'),
  'preexisting',
  'with no settings row the baseline is open: the issue is filed as preexisting'
);

-- Dedupe: the second occurrence is two counters, not a row.
select public.report_error(
  'TypeError', 'roto desde antes', '/conversations'
);

select is(
  (select count(*)::int from public.error_issues),
  1,
  'the same error twice is one row'
);

select is(
  (select events::int from public.error_issues where kind = 'TypeError'),
  2,
  'the second occurrence increments the counter'
);

select ok(
  (select last_seen >= first_seen from public.error_issues where kind = 'TypeError'),
  'the second occurrence moves last_seen and leaves first_seen'
);

-- ---------------------------------------------------------------------------
-- Closing the baseline: the line between "was already broken" and "is news".
-- ---------------------------------------------------------------------------

insert into public.error_settings (id, baseline_open, baseline_closed_at)
values (true, false, now())
on conflict (id) do update set baseline_open = false;

select public.report_error('ReferenceError', 'recien roto', '/agents');

select is(
  (select status::text from public.error_issues where kind = 'ReferenceError'),
  'new',
  'after the baseline closes, an unseen fingerprint is new'
);

-- The property the whole design rests on: closing the baseline does not drag
-- the past in behind it. An old bug firing again is still an old bug.
select public.report_error('TypeError', 'roto desde antes', '/conversations');

select is(
  (select status::text from public.error_issues where kind = 'TypeError'),
  'preexisting',
  'a preexisting issue that fires again stays preexisting'
);

select is(
  (select events::int from public.error_issues where kind = 'TypeError'),
  3,
  'and it still counts the occurrence'
);

-- ---------------------------------------------------------------------------
-- Triage decisions survive repetition — except a fix that did not hold.
-- ---------------------------------------------------------------------------

update public.error_issues set status = 'ignored' where kind = 'ReferenceError';
select public.report_error('ReferenceError', 'recien roto', '/agents');

select is(
  (select status::text from public.error_issues where kind = 'ReferenceError'),
  'ignored',
  'an ignored issue that fires again stays ignored'
);

update public.error_issues
set status = 'resolved', regressed_at = null
where kind = 'ReferenceError';

select public.report_error('ReferenceError', 'recien roto', '/agents');

select is(
  (select status::text from public.error_issues where kind = 'ReferenceError'),
  'new',
  'a resolved issue that fires again is a regression and comes back as new'
);

select ok(
  (select regressed_at is not null from public.error_issues where kind = 'ReferenceError'),
  'and the regression is stamped'
);

-- ---------------------------------------------------------------------------
-- Source is settled by the grant, not by the caller. This is the one argument
-- a browser must never control: an issue that claims to come from the backend
-- sends you reading Edge Function logs for a bug that happened in a tab.
-- ---------------------------------------------------------------------------

select public.report_error('TypeError', 'desde el navegador', '/x');

select is(
  (select source::text from public.error_issues where title = 'desde el navegador'),
  'frontend',
  'report_error always files as frontend'
);

select public.report_edge_error('TypeError', 'desde una funcion', 'whatsapp-webhook');

select is(
  (select source::text from public.error_issues where title = 'desde una funcion'),
  'edge',
  'report_edge_error always files as edge'
);

select ok(
  not has_function_privilege('anon', 'public.record_error_issue(public.error_source,text,text,text,text,text,jsonb)', 'execute'),
  'anon cannot reach the function that takes source as an argument'
);

select ok(
  not has_function_privilege('authenticated', 'public.record_error_issue(public.error_source,text,text,text,text,text,jsonb)', 'execute'),
  'neither can an authenticated user'
);

select ok(
  not has_function_privilege('anon', 'public.report_edge_error(text,text,text,text,text,jsonb)', 'execute'),
  'anon cannot claim to be an Edge Function'
);

-- Reachable without a session on purpose: an error that stops someone logging
-- in is exactly the kind worth catching.
select ok(
  has_function_privilege('anon', 'public.report_error(text,text,text,text,text,jsonb)', 'execute'),
  'anon can report a frontend error'
);

-- ---------------------------------------------------------------------------
-- Triage moves a status and leaves a note. It does not rewrite the evidence:
-- Supabase grants UPDATE on every column of a new public table to
-- `authenticated`, and a stolen admin session should not be able to edit the
-- counter or the captured samples.
-- ---------------------------------------------------------------------------

select ok(
  has_column_privilege('authenticated', 'public.error_issues', 'status', 'update'),
  'a platform admin can change an issue status'
);

select ok(
  not has_column_privilege('authenticated', 'public.error_issues', 'events', 'update'),
  'but not the occurrence counter'
);

select ok(
  not has_column_privilege('authenticated', 'public.error_issues', 'last_sample', 'update'),
  'nor the captured sample'
);

select * from finish();
rollback;
