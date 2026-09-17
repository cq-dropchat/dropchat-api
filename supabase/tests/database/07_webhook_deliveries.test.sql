-- F06/F12 — outgoing webhooks: one pg_net shot from the trigger, no retry,
-- no signature, `limit 3` with no order, any URL accepted (the sandbox took
-- http://169.254.169.254/), and the trigger's latency on every insert and
-- status update.
begin;
select plan(27);

-- ---------------------------------------------------------------------------
-- The trigger only enqueues.
-- ---------------------------------------------------------------------------

create temp table q0 on commit drop as select count(*) as n from net.http_request_queue;

insert into public.messages (
  id, organization_id, service, organization_address, conversation_address,
  sender_address, external_id, content
) values (
  'aaaaaaaa-0000-4000-8000-00000000f0a1', tests.id('org_a'), 'whatsapp',
  tests.val('wa_a'), tests.val('contact_a1'), tests.val('contact_a1'),
  'wamid.HOOK.1',
  '{"version": "1", "type": "text", "kind": "text", "text": "hook me"}'
);

select is(
  (select count(*) from public.webhook_deliveries
   where webhook_id = tests.id('webhook_a') and event = 'messages.insert'),
  1::bigint,
  'an insert enqueues one delivery for the matching webhook'
);

select is(
  (select status || '/' || attempts::text from public.webhook_deliveries
   where webhook_id = tests.id('webhook_a') and event = 'messages.insert'),
  'pending/0',
  'the delivery is pending with no attempt yet'
);

select is(
  (select payload->'data'->>'external_id' from public.webhook_deliveries
   where webhook_id = tests.id('webhook_a') and event = 'messages.insert'),
  'wamid.HOOK.1',
  'the payload is {data, entity, action} with the row in data'
);

-- The webhook-side pg_net requests are gone from the trigger path. (The
-- message triggers still enqueue their own edge-function calls.)
select is(
  (select count(*) from net.http_request_queue
   where url = 'https://hooks.example.test/messages'),
  0::bigint,
  'the trigger itself sends nothing through pg_net'
);

update public.messages
set status = '{"read": "2026-09-10T10:00:00Z"}'
where id = 'aaaaaaaa-0000-4000-8000-00000000f0a1';

select is(
  (select count(*) from public.webhook_deliveries
   where webhook_id = tests.id('webhook_a') and event = 'messages.update'),
  1::bigint,
  'an update enqueues a delivery too (operations include update)'
);

-- A webhook on another table, in the same organization.
insert into public.webhooks (id, organization_id, table_name, operations, url, token)
values ('aaaaaaaa-0000-4000-8000-00000000e0a2', tests.id('org_a'),
        'contacts_addresses', array['insert']::public.webhook_operation[],
        'https://hooks.example.test/contacts', null);

insert into public.contacts_addresses (organization_id, organization_address, service, address, extra)
values (tests.id('org_a'), tests.val('wa_a'), 'whatsapp', '5491100000199', '{"name": "Nuevo"}');

select is(
  (select count(*) from public.webhook_deliveries
   where webhook_id = 'aaaaaaaa-0000-4000-8000-00000000e0a2'),
  1::bigint,
  'contacts_addresses inserts reach their own webhook'
);

-- Org B has no webhooks: nothing enqueued for its traffic.
select is(
  (select count(*) from public.webhook_deliveries where organization_id = tests.id('org_b')),
  0::bigint,
  'no webhook, no delivery'
);

-- ---------------------------------------------------------------------------
-- The worker: claim, sign, send through pg_net.
-- ---------------------------------------------------------------------------

select is(
  public.dispatch_webhook_deliveries(),
  3,
  'dispatch sends the three due deliveries'
);

select is(
  (select status || '/' || attempts::text from public.webhook_deliveries
   where webhook_id = tests.id('webhook_a') and event = 'messages.insert'),
  'delivering/1',
  'a sent delivery is delivering with one attempt and a request id'
);

select isnt(
  (select request_id from public.webhook_deliveries
   where webhook_id = tests.id('webhook_a') and event = 'messages.insert'),
  null,
  'the pg_net request id is recorded'
);

-- The request, as pg_net will send it.
create temp table sent on commit drop as
select q.url, q.headers, convert_from(q.body, 'utf8') as body, q.timeout_milliseconds, d.payload, d.id as delivery_id
from public.webhook_deliveries d
join net.http_request_queue q on q.id = d.request_id
where d.webhook_id = tests.id('webhook_a') and d.event = 'messages.insert';

select is((select url from sent), 'https://hooks.example.test/messages', 'sent to the webhook url');
select is((select timeout_milliseconds from sent), 5000, 'with a 5 s timeout');
select is((select headers->>'authorization' from sent), 'Bearer test-webhook-token-a', 'bearer token as before');
select is((select headers->>'x-openbsp-event' from sent), 'messages.insert', 'event header');
select is((select headers->>'x-openbsp-delivery-id' from sent), (select delivery_id::text from sent), 'delivery id header');

-- The signature verifies against the RAW body bytes with the token: exactly
-- what the receiver computes (functions/_shared/webhook_signature.ts).
select is(
  (select headers->>'x-openbsp-signature' from sent),
  (select 'sha256=' || encode(extensions.hmac(body, 'test-webhook-token-a', 'sha256'), 'hex') from sent),
  'x-openbsp-signature is HMAC-SHA256(token, body) over the bytes sent'
);

select is(
  (select body::jsonb from sent),
  (select payload from sent),
  'the body is the payload'
);

-- A second dispatch finds nothing due (claimed rows are not pending).
select is(public.dispatch_webhook_deliveries(), 0, 'nothing is sent twice');

-- ---------------------------------------------------------------------------
-- Settling: success, backoff, dead letter.
-- ---------------------------------------------------------------------------

create temp table dlv on commit drop as
select id from public.webhook_deliveries
where webhook_id = tests.id('webhook_a') and event = 'messages.insert';

-- attempt 1 failed with a 503 → pending again, 1 s later
select public.record_webhook_result((select id from dlv), 503, null);

select is(
  (select status || '/' || attempts::text || '/' || (next_at - now() between interval '0.5 second' and interval '1.5 second')::text
   from public.webhook_deliveries where id = (select id from dlv)),
  'pending/1/true',
  'a failed attempt is retried after 1 s'
);

-- attempts 2..5 fail → dead letter after the fifth
update public.webhook_deliveries set attempts = 4 where id = (select id from dlv);
select public.record_webhook_result((select id from dlv), 500, 'boom');
select is(
  (select status from public.webhook_deliveries where id = (select id from dlv)),
  'pending',
  'the fourth failure still retries'
);
select is(
  (select next_at - now() > interval '4 minutes' from public.webhook_deliveries where id = (select id from dlv)),
  true,
  'with the 5 min backoff'
);

update public.webhook_deliveries set attempts = 5 where id = (select id from dlv);
select public.record_webhook_result((select id from dlv), 500, 'boom');
select is(
  (select status || '/' || last_error from public.webhook_deliveries where id = (select id from dlv)),
  'failed/boom',
  'the fifth failure is the dead letter'
);

-- settle: the contacts delivery is in flight; pg_net answered 204.
create temp table inflight on commit drop as
select id, request_id from public.webhook_deliveries
where webhook_id = 'aaaaaaaa-0000-4000-8000-00000000e0a2';

insert into net._http_response (id, status_code, timed_out, created)
values ((select request_id from inflight), 204, false, now());

-- messages.update is also in flight but has no response yet: not settled.
select is(public.settle_webhook_deliveries(), 1, 'settle settles only the attempts pg_net has answered');

select is(
  (select status from public.webhook_deliveries where id = (select id from inflight)),
  'delivered',
  'a 2xx response settles the delivery as delivered'
);

-- ---------------------------------------------------------------------------
-- URL allowlist.
-- ---------------------------------------------------------------------------

select throws_ok(
  $$ insert into public.webhooks (organization_id, table_name, operations, url)
     values (tests.id('org_a'), 'messages', array['insert']::public.webhook_operation[],
             'http://169.254.169.254/latest/meta-data/') $$,
  '23514', null,
  'a plain http url is refused'
);

select is(
  (select bool_and(public.is_public_https_url(u)) from unnest(array[
    'https://hooks.example.test/messages',
    'https://api.example.com:8443/v1/hook?x=1'
  ]) u),
  true,
  'public https hostnames are accepted'
);

select is(
  (select bool_or(public.is_public_https_url(u)) from unnest(array[
    'https://169.254.169.254/latest/meta-data/',
    'https://10.0.0.5/hook',
    'https://127.0.0.1:9/hook',
    'https://localhost/hook',
    'https://db.supabase.internal/hook',
    'https://kong.local/hook',
    'https://user:pass@hooks.example.test/hook',
    'https://[::1]/hook',
    'ftp://hooks.example.test/x'
  ]) u),
  false,
  'ip literals, loopback, link-local, private names, userinfo and non-https are refused'
);

select * from finish();
rollback;
