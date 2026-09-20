-- E1. Ingestion and triage for public.error_issues (see 03-22_errors.sql).

-- What turns a stream of messages into a countable bug: strip the parts that
-- change every time. "Failed to load message 9f2c…" and "Failed to load
-- message 4ab1…" are one bug seen twice, and without this they are two rows —
-- which is how a panel becomes a firehose nobody opens.
--
-- Order matters. UUIDs contain digits and hyphens, URLs contain both, and long
-- hex contains digits, so each pattern has to run before the one that would
-- eat its parts. The bare-number rule runs last for that reason.
--
-- Only ever an input to the fingerprint: error_issues.title keeps the message
-- as it arrived. A title with the ids removed is unreadable, and reading it is
-- the point.
create function public.normalize_error_message(_message text) returns text
language sql
immutable
set search_path to ''
as $$
  select left(
    regexp_replace(
      regexp_replace(
        regexp_replace(
          regexp_replace(
            regexp_replace(coalesce(_message, ''),
              '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
              '<uuid>', 'gi'),
            'https?://[^\s"'')]+', '<url>', 'g'),
          '\m(0x)?[0-9a-f]{12,}\M', '<hex>', 'gi'),
        '\m\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2})?)?', '<ts>', 'g'),
      '\m\d+\M', '<n>', 'g'),
    500);
$$;

-- md5, not sha256: this groups occurrences, it does not protect anything, and
-- md5 is in core while digest() needs pgcrypto. A collision would merge two
-- unrelated bugs into one row — at the scale of "distinct bugs in one app",
-- that is not a risk worth an extension for.
create function public.error_fingerprint(
  _source public.error_source,
  _kind text,
  _message text,
  _culprit text
) returns text
language sql
immutable
set search_path to ''
as $$
  select md5(
    _source::text
    || '|' || coalesce(_kind, '')
    || '|' || public.normalize_error_message(_message)
    || '|' || coalesce(left(_culprit, 300), '')
  );
$$;

-- The upsert both entry points funnel into. Revoked from every API role: the
-- `source` argument is exactly what a browser must not get to choose, so the
-- only way to reach this is through one of the two wrappers below, each of
-- which hardcodes it and is granted to the roles allowed to claim it.
create function public.record_error_issue(
  _source public.error_source,
  _kind text,
  _message text,
  _culprit text default null,
  _stack text default null,
  _release text default null,
  _context jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  -- A browser can call report_error in a loop with a varying message and mint
  -- a row per call. The cap bounds the damage to a bad hour: past it, new
  -- fingerprints are dropped silently (an error reporter that errors, or that
  -- tells an attacker where the wall is, is worse than one that loses rows).
  -- Occurrences of a fingerprint already on file are never capped — those are
  -- an UPDATE of two counters, and dropping them would corrupt the count that
  -- makes the panel worth reading.
  _max_new_per_hour constant integer := 200;
  _fingerprint text;
  _baseline_open boolean;
  _sample jsonb;
  _id uuid;
begin
  if _message is null or _message = '' then
    return null;
  end if;

  _kind := coalesce(nullif(left(_kind, 200), ''), 'Error');
  _message := left(_message, 1000);
  _culprit := left(_culprit, 300);
  _release := left(_release, 100);

  _fingerprint := public.error_fingerprint(_source, _kind, _message, _culprit);

  -- Bounded, and bounded honestly: a context too big to keep is kept as the
  -- truncated text of itself rather than dropped, so a fat payload still tells
  -- you what it was.
  _context := coalesce(_context, '{}'::jsonb);
  if length(_context::text) > 8000 then
    _context := jsonb_build_object(
      'truncated', true,
      'raw', left(_context::text, 8000)
    );
  end if;

  -- auth.uid() rather than anything the caller sent: the one identity here
  -- that cannot be forged. Null for an anonymous browser, which is fine — a
  -- crash on the login screen is still worth a row.
  _sample := jsonb_strip_nulls(
    jsonb_build_object(
      'at', now(),
      'stack', left(_stack, 8000),
      'release', _release,
      'user_id', auth.uid(),
      'context', _context
    )
  );

  -- No row leaves _baseline_open NULL, and no row means nobody has closed the
  -- baseline yet — which reads as open. The default falls on the safe side: a
  -- fresh install files everything as preexisting until someone deliberately
  -- says otherwise, rather than opening with a panel full of the past.
  select s.baseline_open into _baseline_open
  from public.error_settings s
  where s.id;

  _baseline_open := coalesce(_baseline_open, true);

  select i.id into _id
  from public.error_issues i
  where i.fingerprint = _fingerprint;

  if _id is null and (
    select count(*) from public.error_issues i
    where i.first_seen > now() - interval '1 hour'
  ) >= _max_new_per_hour then
    return null;
  end if;

  insert into public.error_issues as i (
    fingerprint, source, kind, title, culprit, release, status,
    first_sample, last_sample
  )
  values (
    _fingerprint, _source, _kind, _message, _culprit, _release,
    -- The whole point of the baseline: while it is open, a fingerprint seen
    -- for the first time is filed as something that was already broken.
    case
      when _baseline_open then 'preexisting'::public.error_status
      else 'new'::public.error_status
    end,
    _sample, _sample
  )
  on conflict (fingerprint) do update
  set
    last_seen = now(),
    events = i.events + 1,
    last_sample = excluded.last_sample,
    -- A fixed bug that fires again is news; everything else keeps the triage
    -- decision a person made. 'ignored' stays ignored, and 'preexisting' stays
    -- preexisting however often it repeats — an old bug happening again is
    -- still an old bug, and reopening it would refill the panel with exactly
    -- what the baseline was drawn to keep out.
    status = case
      when i.status = 'resolved' and not _baseline_open
        then 'new'::public.error_status
      else i.status
    end,
    regressed_at = case
      when i.status = 'resolved' and not _baseline_open
        then now()
      else i.regressed_at
    end
  returning i.id into _id;

  return _id;
end;
$$;

revoke execute on function public.record_error_issue(
  public.error_source, text, text, text, text, text, jsonb
) from public, anon, authenticated, service_role;

-- The browser's entry point. Reachable without a session on purpose: the
-- errors worth catching include the ones that stop a person logging in.
create function public.report_error(
  _kind text,
  _message text,
  _culprit text default null,
  _stack text default null,
  _release text default null,
  _context jsonb default '{}'::jsonb
) returns uuid
language sql
security definer
set search_path to ''
as $$
  select public.record_error_issue(
    'frontend'::public.error_source,
    _kind, _message, _culprit, _stack, _release, _context
  );
$$;

revoke execute on function public.report_error(
  text, text, text, text, text, jsonb
) from public;

grant execute on function public.report_error(
  text, text, text, text, text, jsonb
) to anon, authenticated;

-- The Edge Functions' entry point (_shared/error_reporter.ts). Separate from
-- report_error only so that `source` is settled by the grant instead of by
-- sniffing the caller's JWT claims — which differ between the legacy
-- service_role key and the sb_secret ones that replace it.
create function public.report_edge_error(
  _kind text,
  _message text,
  _culprit text default null,
  _stack text default null,
  _release text default null,
  _context jsonb default '{}'::jsonb
) returns uuid
language sql
security definer
set search_path to ''
as $$
  select public.record_error_issue(
    'edge'::public.error_source,
    _kind, _message, _culprit, _stack, _release, _context
  );
$$;

revoke execute on function public.report_edge_error(
  text, text, text, text, text, jsonb
) from public, anon, authenticated;

grant execute on function public.report_edge_error(
  text, text, text, text, text, jsonb
) to service_role;

-- Whether the caller may see the panel. In `rls` (P8) like every other policy
-- helper: SECURITY DEFINER functions that answer about the caller are the
-- machinery of row-level security, not an API, and that schema is the one
-- PostgREST does not serve.
create function rls.is_platform_admin() returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select exists (
    select 1 from public.platform_admins a where a.user_id = auth.uid()
  );
$$;

revoke execute on function rls.is_platform_admin() from public;

grant execute on function rls.is_platform_admin() to anon, authenticated, service_role;

-- Closing the baseline is the deliberate act the whole design hangs on: from
-- here on, a fingerprint nobody has seen before shows up in the panel. It gets
-- a function rather than an UPDATE policy so that who closed it and when are
-- recorded by the database instead of asserted by the client.
create function public.close_error_baseline() returns public.error_settings
language plpgsql
security definer
set search_path to ''
as $$
declare
  _settings public.error_settings;
begin
  if not rls.is_platform_admin() then
    raise exception using
      errcode = '42501',
      message = 'not a platform admin';
  end if;

  -- Upsert, because the settings table ships empty: the first close is what
  -- creates the row.
  insert into public.error_settings (id, baseline_open, baseline_closed_at, baseline_closed_by)
  values (true, false, now(), auth.uid())
  on conflict (id) do update
  set
    baseline_open = false,
    baseline_closed_at = now(),
    baseline_closed_by = auth.uid(),
    updated_at = now()
  returning * into _settings;

  return _settings;
end;
$$;

revoke execute on function public.close_error_baseline() from public, anon;

grant execute on function public.close_error_baseline() to authenticated;

-- The way back, for the case the panel turns out to be noisier than expected
-- after a big release: reopening files everything unseen as preexisting again
-- until it is closed once more. Issues already filed keep whatever status they
-- have — reopening the baseline is not a way to erase triage.
create function public.open_error_baseline() returns public.error_settings
language plpgsql
security definer
set search_path to ''
as $$
declare
  _settings public.error_settings;
begin
  if not rls.is_platform_admin() then
    raise exception using
      errcode = '42501',
      message = 'not a platform admin';
  end if;

  insert into public.error_settings (id, baseline_open)
  values (true, true)
  on conflict (id) do update
  set
    baseline_open = true,
    baseline_closed_at = null,
    baseline_closed_by = null,
    updated_at = now()
  returning * into _settings;

  return _settings;
end;
$$;

revoke execute on function public.open_error_baseline() from public, anon;

grant execute on function public.open_error_baseline() to authenticated;
