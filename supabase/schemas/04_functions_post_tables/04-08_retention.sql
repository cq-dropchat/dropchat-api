-- F15. Retention for tables nothing else trims, run hourly by the
-- `purge-expired-rows` pg_cron job, at most `_batch` rows per table per run
-- (one short transaction; the next run continues).
--
--   supabase_functions.hooks  everything: no trigger writes it any more (see
--                             02-02_edge_functions.sql), what is left is the
--                             backlog from before, oldest first by its PK.
--   public.logs               older than 90 days (idx_logs_created_at). Logs
--                             are what members read on account errors; a
--                             quarter covers any billing or support question.
--   public.onboarding_tokens  expired more than 30 days ago, used or not.
--   public.error_issues       E1: settled issues that have gone quiet —
--                             'resolved' after 90 days without a new
--                             occurrence, 'preexisting' after 180. An open
--                             issue is never purged however old it is: age is
--                             not a reason to stop showing an unfixed bug.
--                             'ignored' is never purged either, or the panel
--                             would keep re-reporting what was dismissed.
--
-- cron.job_run_details already has its own 7-day job; net._http_response has
-- pg_net's TTL.

create function public.purge_expired_rows(_batch integer default 10000)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  _hooks integer;
  _logs integer;
  _tokens integer;
  _exports integer;
  _errors integer;
begin
  delete from supabase_functions.hooks
  where id in (
    select h.id from supabase_functions.hooks h order by h.id limit _batch
  );
  get diagnostics _hooks = row_count;

  delete from public.logs
  where id in (
    select l.id from public.logs l
    where l.created_at < now() - interval '90 days'
    order by l.created_at
    limit _batch
  );
  get diagnostics _logs = row_count;

  delete from public.onboarding_tokens
  where id in (
    select t.id from public.onboarding_tokens t
    where t.expires_at < now() - interval '30 days'
    limit _batch
  );
  get diagnostics _tokens = row_count;

  -- F18: exports whose file is gone (expired) or that failed, a week after
  -- they finished.
  delete from public.organization_exports
  where id in (
    select e.id from public.organization_exports e
    where e.status in ('expired', 'failed')
      and coalesce(e.completed_at, e.requested_at) < now() - interval '7 days'
    limit _batch
  );
  get diagnostics _exports = row_count;

  -- E1. Deleting a settled issue also forgets its fingerprint, so if the bug
  -- ever comes back it is reported as new rather than reviving a row from last
  -- year — which is the right answer: after 90 days without a sighting, a
  -- recurrence is news.
  delete from public.error_issues
  where id in (
    select i.id from public.error_issues i
    where (i.status = 'resolved' and i.last_seen < now() - interval '90 days')
       or (i.status = 'preexisting' and i.last_seen < now() - interval '180 days')
    limit _batch
  );
  get diagnostics _errors = row_count;

  return jsonb_build_object(
    'hooks', _hooks,
    'logs', _logs,
    'onboarding_tokens', _tokens,
    'organization_exports', _exports,
    'error_issues', _errors
  );
end;
$$;

revoke execute on function public.purge_expired_rows(integer) from public, anon, authenticated;
