-- F09 — quotas and noisy neighbours through an API key.
--
-- Failure scenario: the message cap only looks at rows with sender_address
-- null. A member API key inserts rows SHAPED like inbound (sender_address
-- set, status.pending) without limit: each one skips the cap, wakes
-- agent-client (an LLM call) and lands in the shared pg_net queue. Nothing
-- rate-limits an organization at all.
begin;
select plan(9);

-- ---------------------------------------------------------------------------
-- Cap: an API key is capped whatever the shape of the row it inserts.
-- ---------------------------------------------------------------------------

-- Org A is one message below its monthly cap (free tier: 5000).
insert into billing.usage (organization_id, product_id, interval, period, quantity)
values (tests.id('org_a'), 'messages', 'month', date_trunc('month', current_date)::date, 4999)
on conflict (organization_id, product_id, interval, period)
do update set quantity = 4999;

select tests.authenticate_with_api_key(tests.val('key_a_member'));

select lives_ok(
  $$
  insert into public.messages (
    organization_id, service, organization_address, conversation_address,
    sender_address, content
  ) values (
    tests.id('org_a'), 'whatsapp', tests.val('wa_a'), tests.val('contact_a1'),
    tests.val('contact_a1'),
    '{"version": "1", "type": "text", "kind": "text", "text": "inbound-shaped 5000"}'
  )
  $$,
  'member key: the 5000th message of the month goes through'
);

select throws_ok(
  $$
  insert into public.messages (
    organization_id, service, organization_address, conversation_address,
    sender_address, content
  ) values (
    tests.id('org_a'), 'whatsapp', tests.val('wa_a'), tests.val('contact_a1'),
    tests.val('contact_a1'),
    '{"version": "1", "type": "text", "kind": "text", "text": "inbound-shaped 5001"}'
  )
  $$,
  'PT402',
  null,
  'member key: an inbound-shaped row over the cap is refused (PT402)'
);

select throws_ok(
  $$
  insert into public.messages (
    organization_id, service, organization_address, conversation_address,
    sender_address, content
  ) values (
    tests.id('org_a'), 'whatsapp', tests.val('wa_a'), tests.val('contact_a1'),
    null,
    '{"version": "1", "type": "text", "kind": "text", "text": "outbound 5001"}'
  )
  $$,
  'PT402',
  null,
  'member key: an outbound row over the cap is refused too'
);

-- A real inbound message (the webhook, service role) is never capped: losing
-- what a contact said is worse than exceeding a plan.
select tests.clear_authentication();

select lives_ok(
  $$
  insert into public.messages (
    organization_id, service, organization_address, conversation_address,
    sender_address, external_id, content
  ) values (
    tests.id('org_a'), 'whatsapp', tests.val('wa_a'), tests.val('contact_a1'),
    tests.val('contact_a1'), 'wamid.CAP.INBOUND',
    '{"version": "1", "type": "text", "kind": "text", "text": "real inbound"}'
  )
  $$,
  'service role: a real inbound message goes through over the cap'
);

-- ---------------------------------------------------------------------------
-- Rate limit: per organization, per minute, API roles only.
-- ---------------------------------------------------------------------------

update billing.usage set quantity = 0
where organization_id = tests.id('org_a') and product_id = 'messages';

-- The cap tests above already spent one slot of this minute's window.
delete from public.rate_limits where organization_id = tests.id('org_a');

select tests.authenticate_with_api_key(tests.val('key_a_member'));

-- The limit is public.message_rate_limit_per_minute(); the test reads it so
-- a tuning change does not rewrite the test.
select ok(
  public.message_rate_limit_per_minute() between 10 and 10000,
  'the per-minute limit is a sane number'
);

select lives_ok(
  format($$
    insert into public.messages (
      organization_id, service, organization_address, conversation_address,
      sender_address, content
    )
    select
      tests.id('org_a'), 'whatsapp', tests.val('wa_a'), tests.val('contact_a1'),
      tests.val('contact_a1'),
      jsonb_build_object('version', '1', 'type', 'text', 'kind', 'text', 'text', 'burst ' || i)
    from generate_series(1, %s) i
  $$, public.message_rate_limit_per_minute()),
  'member key: a burst up to the limit goes through'
);

select throws_ok(
  $$
  insert into public.messages (
    organization_id, service, organization_address, conversation_address,
    sender_address, content
  ) values (
    tests.id('org_a'), 'whatsapp', tests.val('wa_a'), tests.val('contact_a1'),
    tests.val('contact_a1'),
    '{"version": "1", "type": "text", "kind": "text", "text": "one too many"}'
  )
  $$,
  'PT429',
  null,
  'member key: the next insert in the same minute is refused (PT429)'
);

-- Another tenant is not affected by A's burst.
select tests.clear_authentication();
select tests.authenticate_with_api_key(tests.val('key_b_member'));

select lives_ok(
  $$
  insert into public.messages (
    organization_id, service, organization_address, conversation_address,
    sender_address, content
  ) values (
    tests.id('org_b'), 'whatsapp', tests.val('wa_b'), tests.val('contact_b1'),
    tests.val('contact_b1'),
    '{"version": "1", "type": "text", "kind": "text", "text": "B is fine"}'
  )
  $$,
  'member key of B: unaffected by A''s burst'
);

-- The service role (webhooks, dispatchers, crons) is never rate limited.
select tests.clear_authentication();

select lives_ok(
  format($$
    insert into public.messages (
      organization_id, service, organization_address, conversation_address,
      sender_address, external_id, content
    )
    select
      tests.id('org_a'), 'whatsapp', tests.val('wa_a'), tests.val('contact_a1'),
      tests.val('contact_a1'), 'wamid.BURST.' || i,
      jsonb_build_object('version', '1', 'type', 'text', 'kind', 'text', 'text', 'webhook ' || i)
    from generate_series(1, %s) i
  $$, public.message_rate_limit_per_minute() + 10),
  'service role: over the per-minute limit and still accepted'
);

select * from finish();
rollback;
