-- F17 — billing.
--
-- Failure scenarios:
--   * check_limit(ai_credits, 0) lets the last call through at any balance
--     above the floor, and the balance goes negative by that call's cost.
--   * nothing makes a ledger entry unique: an insert retried after a
--     timeout charges the organization twice.
--   * usage counts inbound and outbound messages, the cap only outbound: the
--     plan's quota is consumed by contacts and enforced on the account.
begin;
select plan(10);

-- ---------------------------------------------------------------------------
-- Reservation: check the estimated cost, not zero.
-- ---------------------------------------------------------------------------

-- Org A's lifetime balance: $1 granted by the free plan. Spend it down to 2¢.
insert into billing.ledger (organization_id, product_id, type, quantity)
values (tests.id('org_a'), 'ai_credits', 'consumption', -0.98);

select lives_ok(
  $$ select billing.check_limit(tests.id('org_a'), 'ai_credits', 0.01) $$,
  'a call estimated under the balance is allowed'
);

select throws_ok(
  $$ select billing.check_limit(tests.id('org_a'), 'ai_credits', 0.05) $$,
  'PT402', null,
  'a call estimated over the balance is refused before it is made'
);

select is(
  billing.estimate_ai_cost('{"input": 3.00, "output": 15.00}', 1000000, 4000, 1000),
  round((4000 * 3.00 + 1000 * 15.00) / 1000000.0, 8),
  'estimate_ai_cost prices input and max output tokens'
);

select is(
  billing.estimate_ai_cost('{"input": 3.00}', 1000000, 1000, 1000),
  round((1000 * 3.00 + 1000 * 3.00) / 1000000.0, 8),
  'a missing output price falls back to the input price'
);

-- ---------------------------------------------------------------------------
-- Idempotent ledger.
-- ---------------------------------------------------------------------------

create temp table before_usage on commit drop as
select quantity from billing.usage
where organization_id = tests.id('org_a') and product_id = 'ai_credits'
  and interval = 'lifetime';

insert into billing.ledger (organization_id, product_id, type, quantity, provider, model, external_id, message_id)
values (tests.id('org_a'), 'ai_credits', 'consumption', -0.001, 'groq', 'openai/gpt-oss-20b',
        'chatcmpl-test-1', tests.id('msg_a1_in'))
on conflict (provider, external_id) do nothing;

insert into billing.ledger (organization_id, product_id, type, quantity, provider, model, external_id, message_id)
values (tests.id('org_a'), 'ai_credits', 'consumption', -0.001, 'groq', 'openai/gpt-oss-20b',
        'chatcmpl-test-1', tests.id('msg_a1_in'))
on conflict (provider, external_id) do nothing;

select is(
  (select count(*) from billing.ledger where external_id = 'chatcmpl-test-1'),
  1::bigint,
  'the same provider response is recorded once'
);

select is(
  (select quantity from billing.usage
   where organization_id = tests.id('org_a') and product_id = 'ai_credits' and interval = 'lifetime'),
  (select quantity - 0.001 from before_usage),
  'and charged once'
);

select throws_ok(
  $$ insert into billing.ledger (organization_id, product_id, type, quantity, provider, model, external_id)
     values (tests.id('org_a'), 'ai_credits', 'consumption', -0.001, 'groq', 'x', 'chatcmpl-test-1') $$,
  '23505', null,
  'a plain duplicate insert is a unique violation'
);

-- ---------------------------------------------------------------------------
-- What the message quota counts: what the cap caps.
-- ---------------------------------------------------------------------------

create temp table m0 on commit drop as
select
  coalesce((select quantity from billing.usage where organization_id = tests.id('org_a')
            and product_id = 'messages' and interval = 'month'
            and period = date_trunc('month', current_date)::date), 0) as outbound,
  coalesce((select quantity from billing.usage where organization_id = tests.id('org_a')
            and product_id = 'messages_inbound' and interval = 'month'
            and period = date_trunc('month', current_date)::date), 0) as inbound;

-- A contact writes (the webhook, service role).
insert into public.messages (organization_id, service, organization_address, conversation_address,
  sender_address, external_id, content)
values (tests.id('org_a'), 'whatsapp', tests.val('wa_a'), tests.val('contact_a1'),
  tests.val('contact_a1'), 'wamid.QUOTA.IN',
  '{"version": "1", "type": "text", "kind": "text", "text": "hola"}');

-- The account writes.
insert into public.messages (organization_id, service, organization_address, conversation_address,
  sender_address, agent_id, content)
values (tests.id('org_a'), 'whatsapp', tests.val('wa_a'), tests.val('contact_a1'),
  null, tests.id('agent_alice'),
  '{"version": "1", "type": "text", "kind": "text", "text": "respuesta"}');

select is(
  (select quantity from billing.usage where organization_id = tests.id('org_a')
   and product_id = 'messages' and interval = 'month'
   and period = date_trunc('month', current_date)::date) - (select outbound from m0),
  1::numeric,
  'the plan quota counts the account''s message only'
);

select is(
  (select quantity from billing.usage where organization_id = tests.id('org_a')
   and product_id = 'messages_inbound' and interval = 'month'
   and period = date_trunc('month', current_date)::date) - (select inbound from m0),
  1::numeric,
  'the contact''s message is metered as messages_inbound'
);

select is(
  (select count(*) from billing.tiers_products where product_id = 'messages_inbound'),
  0::bigint,
  'messages_inbound has no cap in any tier'
);

select * from finish();
rollback;
