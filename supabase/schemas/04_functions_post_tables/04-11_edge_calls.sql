-- The edge call worker (F12). See 03-20_edge_calls.sql for the model.

-- enqueue_edge_call (the trigger) lives in 02-02: triggers on messages need it
-- before the table is created.

-- Backoff after the n-th failed attempt: 5 s, 30 s, 2 min, 10 min.
create function public.edge_call_retry_delay(attempt integer) returns interval
language sql
immutable
as $$
  select case attempt
    when 1 then interval '5 seconds'
    when 2 then interval '30 seconds'
    when 3 then interval '2 minutes'
    else interval '10 minutes'
  end;
$$;

create function public.edge_call_max_attempts() returns integer
language sql
immutable
as $$
  select 5;
$$;

-- An attempt with no response after this is retried.
create function public.edge_call_lease() returns interval
language sql
immutable
as $$
  select interval '2 minutes';
$$;

-- The outcome of one attempt:
--   2xx                  done
--   pg_net timed out     done: the request reached the function, which keeps
--                        running after pg_net stops waiting (agent-client
--                        takes 5–40 s); retrying would run it twice
--   401, 403, 404, other 4xx except 408/429
--                        failed: configuration, a retry cannot help
--   5xx, 408, 429, a connection error, no response
--                        retried with backoff; failed after the fifth attempt
create function public.record_edge_call_result(
  _id uuid,
  _status_code integer,
  _timed_out boolean,
  _error text
) returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  _attempts integer;
begin
  select c.attempts into _attempts from public.edge_calls c where c.id = _id;

  if _attempts is null then
    return;
  end if;

  if _status_code between 200 and 299 or coalesce(_timed_out, false) then
    update public.edge_calls
    set status = 'done',
        last_status_code = _status_code,
        last_error = case when _timed_out then 'timed out waiting for the response; the function kept running' end,
        request_id = null,
        locked_until = null
    where id = _id;
  elsif _status_code between 400 and 499 and _status_code not in (408, 429) then
    update public.edge_calls
    set status = 'failed',
        last_status_code = _status_code,
        last_error = coalesce(_error, 'HTTP ' || _status_code::text),
        request_id = null,
        locked_until = null
    where id = _id;
  elsif _attempts >= public.edge_call_max_attempts() then
    update public.edge_calls
    set status = 'failed',
        last_status_code = _status_code,
        last_error = coalesce(_error, 'HTTP ' || _status_code::text),
        request_id = null,
        locked_until = null
    where id = _id;
  else
    update public.edge_calls
    set status = 'pending',
        next_attempt_at = now() + public.edge_call_retry_delay(_attempts),
        last_status_code = _status_code,
        last_error = coalesce(_error, 'HTTP ' || _status_code::text),
        request_id = null,
        locked_until = null
    where id = _id;
  end if;
end;
$$;

-- Settles the attempts in flight from pg_net's response table; an attempt
-- whose lease ran out with no response counts as failed (retried).
create function public.settle_edge_calls() returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  _row record;
  _settled integer := 0;
begin
  for _row in
    select c.id, c.locked_until, r.id as response_id, r.status_code, r.timed_out, r.error_msg
    from public.edge_calls c
    left join net._http_response r on r.id = c.request_id
    where c.status = 'sending'
    for update of c skip locked
  loop
    if _row.response_id is not null then
      perform public.record_edge_call_result(
        _row.id, _row.status_code, _row.timed_out, _row.error_msg
      );
      _settled := _settled + 1;
    elsif _row.locked_until < now() then
      perform public.record_edge_call_result(_row.id, null, false, 'no response');
      _settled := _settled + 1;
    end if;
  end loop;

  return _settled;
end;
$$;

-- Sends what is due: at most _per_org calls per organization and _batch in
-- total per tick, oldest first within an organization and round-robin across
-- organizations (every organization's first call before anyone's second), so
-- a burst of one tenant cannot hold back the others' calls. The defaults
-- (1,000 per 5 s tick, 250 per organization) are capacity: fairness comes
-- from the order; the per-organization cap only bounds one tenant's share
-- of a saturated tick.
create function public.dispatch_edge_calls(_batch integer default 1000, _per_org integer default 250)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  _base_url text;
  _token text;
  _row record;
  _request_id bigint;
  _sent integer := 0;
begin
  select * into _base_url, _token from public.edge_functions_config();

  for _row in
    select c.id, c.function, c.payload, c.forward_headers
    from (
      select p.id,
        row_number() over (partition by p.organization_id order by p.next_attempt_at, p.id) as rank,
        p.next_attempt_at
      from public.edge_calls p
      where p.status = 'pending'
        and p.next_attempt_at <= now()
    ) ranked
    join public.edge_calls c on c.id = ranked.id
    where ranked.rank <= _per_org
    order by ranked.rank, ranked.next_attempt_at
    limit _batch
    for update of c skip locked
  loop
    select net.http_post(
      url := _base_url || '/' || _row.function,
      body := _row.payload,
      headers := jsonb_build_object(
        'content-type', 'application/json',
        'authorization', 'Bearer ' || _token
      ) || _row.forward_headers,
      timeout_milliseconds := 10000
    ) into _request_id;

    update public.edge_calls
    set status = 'sending',
        attempts = attempts + 1,
        request_id = _request_id,
        locked_until = now() + public.edge_call_lease()
    where id = _row.id;

    _sent := _sent + 1;
  end loop;

  return _sent;
end;
$$;

-- The cron entry point: settle, then send.
create function public.deliver_edge_calls() returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  _settled integer;
  _sent integer;
begin
  _settled := public.settle_edge_calls();
  _sent := public.dispatch_edge_calls();
  return jsonb_build_object('settled', _settled, 'sent', _sent);
end;
$$;

-- The backlog, per function and organization. Alert when `pending` stays
-- high or `oldest_pending_at` falls behind (see CLAUDE.md).
create view public.edge_calls_health
with (security_invoker = true)
as
select
  c.function,
  c.organization_id,
  count(*) filter (where c.status = 'pending') as pending,
  count(*) filter (where c.status = 'sending') as sending,
  count(*) filter (where c.status = 'failed') as failed,
  min(c.created_at) filter (where c.status = 'pending') as oldest_pending_at,
  max(c.updated_at) filter (where c.status = 'done') as last_done_at
from public.edge_calls c
group by c.function, c.organization_id;

revoke all on public.edge_calls_health from anon, authenticated;

revoke execute on function public.record_edge_call_result(uuid, integer, boolean, text) from public, anon, authenticated;
revoke execute on function public.settle_edge_calls() from public, anon, authenticated;
revoke execute on function public.dispatch_edge_calls(integer, integer) from public, anon, authenticated;
revoke execute on function public.deliver_edge_calls() from public, anon, authenticated;
