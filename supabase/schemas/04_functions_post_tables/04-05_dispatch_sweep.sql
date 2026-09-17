-- The outgoing-message sweep (F11): what the `dispatch-outgoing-pending-messages`
-- pg_cron job runs every minute, plus the lease and backoff the dispatchers
-- use so the sweep and the insert trigger never send one message twice.
--
-- status keys involved (all merge-patched, like every other status key):
--   pending       the arm bit (set at insert, retracted by the dispatcher)
--   dispatching   lease: an invocation is sending this row right now. Set by
--                 claim_message_dispatch, removed on success, on a permanent
--                 failure and by release_message_dispatch. A lease older than
--                 two minutes belongs to an invocation that died.
--   attempts      transient failures so far
--   retry_at      not before this instant (exponential backoff)

create function public.dispatch_lease_ttl() returns interval
language sql
immutable
as $$
  select interval '2 minutes';
$$;

-- Backoff after the n-th transient failure: 1, 2, 4, 8, 16, 32, then 60
-- minutes. Over the 12-hour sweep window that is ~16 attempts, not 720.
create function public.dispatch_retry_delay(attempt integer) returns interval
language sql
immutable
as $$
  select least(interval '1 minute' * power(2, greatest(attempt - 1, 0)), interval '60 minutes');
$$;

-- Takes the lease on an outgoing row. True for exactly one caller: the
-- UPDATE locks the row, and a second caller re-evaluates the WHERE after the
-- first commits and finds the fresh lease. False also when the row is no
-- longer armed or already has a delivery status — nothing to send.
create function public.claim_message_dispatch(p_message_id uuid) returns boolean
language plpgsql
security definer
set search_path to ''
as $$
declare
  _claimed uuid;
begin
  update public.messages m
  set status = jsonb_build_object('dispatching', now())
  where m.id = p_message_id
    and m.status ->> 'pending' is not null
    and m.status ->> 'accepted' is null
    and m.status ->> 'sent' is null
    and m.status ->> 'delivered' is null
    and m.status ->> 'read' is null
    and m.status ->> 'failed' is null
    and (
      m.status ->> 'dispatching' is null
      or (m.status ->> 'dispatching')::timestamptz < now() - public.dispatch_lease_ttl()
    )
  returning m.id into _claimed;

  return _claimed is not null;
end;
$$;

-- A transient failure: count it, schedule the next attempt, drop the lease,
-- keep the row armed. p_errors replaces status.errors (arrays replace under
-- merge-patch), so the latest failure is what the UI shows.
create function public.release_message_dispatch(
  p_message_id uuid,
  p_errors jsonb default '[]'::jsonb
) returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  _attempts integer;
begin
  select coalesce((m.status ->> 'attempts')::int, 0) + 1
  into _attempts
  from public.messages m
  where m.id = p_message_id;

  if _attempts is null then
    return;
  end if;

  update public.messages m
  set status = jsonb_build_object(
    'dispatching', null,
    'attempts', _attempts,
    'retry_at', now() + public.dispatch_retry_delay(_attempts),
    'errors', coalesce(p_errors, '[]'::jsonb)
  )
  where m.id = p_message_id;
end;
$$;

-- What the sweep re-fires: the questions the insert trigger asks
-- (account-authored, armed, not record-only), in the 12-hour window, not
-- sent yet, not leased, not waiting for its retry. The predicate on
-- sender_address/pending is the one messages_dispatch_pending_idx is
-- declared with, so the planner reads only armed outgoing rows.
create function public.pending_dispatch_candidates()
returns setof public.messages
language sql
stable
security definer
set search_path to ''
as $$
  select m.*
  from public.messages m
  where m.sender_address is null
    and (m.status ->> 'pending') is not null
    and m.content ->> 'internal' is null
    and m.timestamp >= now() - interval '12 hours'
    and m.timestamp <= now() - interval '1 minute'
    and m.status ->> 'held_for_quality_assessment' is null
    and m.status ->> 'accepted' is null
    and m.status ->> 'sent' is null
    and m.status ->> 'delivered' is null
    and m.status ->> 'read' is null
    and m.status ->> 'failed' is null
    and (
      m.status ->> 'dispatching' is null
      or (m.status ->> 'dispatching')::timestamptz < now() - public.dispatch_lease_ttl()
    )
    and (
      m.status ->> 'retry_at' is null
      or (m.status ->> 'retry_at')::timestamptz <= now()
    );
$$;

-- The cron body: one dispatcher request per candidate. The dispatcher claims
-- the lease itself, so a request that races the insert trigger's is a no-op.
create function public.dispatch_pending_messages() returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  _base_url text;
  _token text;
  _count integer := 0;
  _row public.messages;
begin
  select decrypted_secret into _base_url from vault.decrypted_secrets where name = 'edge_functions_url';
  select decrypted_secret into _token from vault.decrypted_secrets where name = 'edge_functions_token';

  for _row in select * from public.pending_dispatch_candidates() loop
    perform net.http_post(
      url := _base_url || '/' || _row.service::text || '-dispatcher',
      headers := jsonb_build_object(
        'content-type', 'application/json',
        'authorization', 'Bearer ' || _token
      ),
      body := jsonb_build_object(
        'old_record', null,
        'record', to_jsonb(_row),
        'type', 'INSERT',
        'table', 'messages',
        'schema', 'public'
      ),
      timeout_milliseconds := 10000
    );
    _count := _count + 1;
  end loop;

  return _count;
end;
$$;

revoke execute on function public.claim_message_dispatch(uuid) from public;
revoke execute on function public.release_message_dispatch(uuid, jsonb) from public;
revoke execute on function public.pending_dispatch_candidates() from public;
revoke execute on function public.dispatch_pending_messages() from public;
grant execute on function public.claim_message_dispatch(uuid) to service_role;
grant execute on function public.release_message_dispatch(uuid, jsonb) to service_role;
