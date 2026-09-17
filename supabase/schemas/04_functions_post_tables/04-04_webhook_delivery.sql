-- Webhook delivery (F06/F12). See 03-08_webhook_deliveries.sql for the
-- model; this file is the worker.

-- Backoff for a failed attempt: 1 s, 5 s, 30 s, 5 min, 1 h — and after
-- the fifth failure the row is a dead letter.
create function public.webhook_retry_delay(attempt integer) returns interval
language sql
immutable
as $$
  select case attempt
    when 1 then interval '1 second'
    when 2 then interval '5 seconds'
    when 3 then interval '30 seconds'
    when 4 then interval '5 minutes'
    else interval '1 hour'
  end;
$$;

create function public.webhook_max_attempts() returns integer
language sql
immutable
as $$
  select 5;
$$;

-- Records the outcome of one attempt. 2xx settles the delivery; anything
-- else schedules the next attempt with backoff, or dead-letters after
-- webhook_max_attempts(). Called by settle_webhook_deliveries() below and
-- directly by the tests.
create function public.record_webhook_result(
  p_delivery_id uuid,
  p_status_code integer,
  p_error text default null
) returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  _attempts integer;
begin
  select attempts into _attempts
  from public.webhook_deliveries
  where id = p_delivery_id;

  if _attempts is null then
    return;
  end if;

  if p_status_code between 200 and 299 then
    update public.webhook_deliveries
    set status = 'delivered',
        delivered_at = now(),
        last_status_code = p_status_code,
        last_error = null,
        request_id = null
    where id = p_delivery_id;
  elsif _attempts >= public.webhook_max_attempts() then
    update public.webhook_deliveries
    set status = 'failed',
        last_status_code = p_status_code,
        last_error = coalesce(p_error, 'HTTP ' || p_status_code::text),
        request_id = null
    where id = p_delivery_id;
  else
    update public.webhook_deliveries
    set status = 'pending',
        next_at = now() + public.webhook_retry_delay(_attempts),
        last_status_code = p_status_code,
        last_error = coalesce(p_error, 'HTTP ' || p_status_code::text),
        request_id = null
    where id = p_delivery_id;
  end if;
end;
$$;

-- Settles every attempt in flight from pg_net's response table. A response
-- older than the request settles it; no response after two minutes (pg_net
-- gave up, or its 6 h TTL swept the row) counts as a failed attempt.
create function public.settle_webhook_deliveries() returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  _row record;
  _settled integer := 0;
begin
  for _row in
    select d.id, d.updated_at, r.status_code, r.timed_out, r.error_msg
    from public.webhook_deliveries d
    left join net._http_response r on r.id = d.request_id
    where d.status = 'delivering'
      and d.request_id is not null
  loop
    if _row.status_code is not null or _row.timed_out or _row.error_msg is not null then
      perform public.record_webhook_result(
        _row.id,
        coalesce(_row.status_code, 0),
        case
          when _row.timed_out then 'timed out'
          else _row.error_msg
        end
      );
      _settled := _settled + 1;
    elsif _row.updated_at < now() - interval '2 minutes' then
      perform public.record_webhook_result(_row.id, 0, 'no response');
      _settled := _settled + 1;
    end if;
  end loop;

  return _settled;
end;
$$;

-- Sends what is due. Each row is claimed under SKIP LOCKED, so several
-- ticks (or a manual run next to the cron) never send the same delivery
-- twice; the claim and the pg_net enqueue commit together.
--
-- Headers, per delivery:
--   authorization           Bearer <webhooks.token>, as before
--   x-openbsp-signature     sha256=<hex HMAC-SHA256(token, body)>, when a
--                           token is set — the receiver's proof that the
--                           body is ours (functions/_shared/webhook_signature.ts)
--   x-openbsp-delivery-id   this row's id, for idempotent receivers
--   x-openbsp-event         'messages.insert' etc.
--
-- The body is the payload's canonical jsonb text; pg_net sends exactly that
-- text, so the receiver signs the raw bytes it got.
create function public.dispatch_webhook_deliveries(p_batch integer default 200)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  _row record;
  _body text;
  _headers jsonb;
  _request_id bigint;
  _sent integer := 0;
begin
  for _row in
    select d.id, d.event, d.payload, w.url, w.token
    from public.webhook_deliveries d
    join public.webhooks w on w.id = d.webhook_id
    where d.status = 'pending'
      and d.next_at <= now()
    order by d.next_at
    limit p_batch
    for update of d skip locked
  loop
    -- A webhook whose URL would not be accepted today is not delivered to:
    -- rows that predate the allowlist keep their subscription, not the hole.
    if not public.is_public_https_url(_row.url) then
      update public.webhook_deliveries
      set status = 'failed',
          attempts = attempts + 1,
          last_error = 'webhook url is not a public https url'
      where id = _row.id;
      continue;
    end if;

    _body := _row.payload::text;

    _headers := jsonb_build_object(
      'content-type', 'application/json',
      'x-openbsp-delivery-id', _row.id::text,
      'x-openbsp-event', _row.event
    );

    if _row.token is not null then
      _headers := _headers
        || jsonb_build_object('authorization', 'Bearer ' || _row.token)
        || jsonb_build_object(
          'x-openbsp-signature',
          'sha256=' || encode(extensions.hmac(_body, _row.token, 'sha256'), 'hex')
        );
    end if;

    select net.http_post(
      url := _row.url,
      body := _row.payload,
      headers := _headers,
      timeout_milliseconds := 5000
    ) into _request_id;

    update public.webhook_deliveries
    set status = 'delivering',
        attempts = attempts + 1,
        request_id = _request_id
    where id = _row.id;

    _sent := _sent + 1;
  end loop;

  return _sent;
end;
$$;

-- The cron entry point: settle the previous tick, then send what is due.
create function public.deliver_webhooks() returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  _settled integer;
  _sent integer;
begin
  _settled := public.settle_webhook_deliveries();
  _sent := public.dispatch_webhook_deliveries();

  return jsonb_build_object('settled', _settled, 'sent', _sent);
end;
$$;

-- None of these is an API: the worker runs as postgres from pg_cron.
revoke execute on function public.webhook_retry_delay(integer) from public, anon, authenticated;
revoke execute on function public.webhook_max_attempts() from public, anon, authenticated;
revoke execute on function public.record_webhook_result(uuid, integer, text) from public, anon, authenticated;
revoke execute on function public.settle_webhook_deliveries() from public, anon, authenticated;
revoke execute on function public.dispatch_webhook_deliveries(integer) from public, anon, authenticated;
revoke execute on function public.deliver_webhooks() from public, anon, authenticated;
