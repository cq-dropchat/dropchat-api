-- Regressions: ineligible heads must never monopolize a cron batch.
begin;
select plan(17);

select has_index('public', 'messages', 'messages_org_updated_cursor_idx', 'tenant catch-up is indexed');
select has_index('public', 'conversations', 'conversations_org_updated_cursor_idx', 'conversation catch-up is indexed');
select has_index('public', 'messages', 'messages_org_conv_created_cursor_idx', 'agent arrival lookup is indexed');
select has_index('public', 'messages', 'messages_media_pending_cursor_idx', 'media sweep has an exact partial index');
select has_index('public', 'messages', 'messages_org_conv_history_cursor_idx', 'history timestamp ties are indexed');

update public.organizations set extra = '{"attention":{"human_assignment_ttl_hours":0}}' where id = tests.id('org_b');
insert into public.conversations (organization_id, service, organization_address, address, assigned_agent_id, assigned_at)
select tests.id('org_b'), 'whatsapp', tests.val('wa_b'), 'perf-disabled-' || i, tests.id('agent_bob'), now() - interval '20 days'
from generate_series(1, 501) i;
insert into public.conversations (organization_id, service, organization_address, address, assigned_agent_id, assigned_at)
values (tests.id('org_a'), 'whatsapp', tests.val('wa_a'), 'perf-expired', tests.id('agent_alice'), now() - interval '10 days');
select is(public.expire_human_assignments(1), 1, 'TTL-disabled tenants before the limit cannot starve an expired assignment');
select is((select assigned_agent_id from public.conversations where address = 'perf-expired'), null::uuid, 'eligible assignment expired');
select is((select count(*)::int from public.conversations where address like 'perf-disabled-%' and assigned_agent_id is not null), 501, 'disabled TTL assignments remain assigned');

insert into public.conversations (organization_id, service, organization_address, address, awaiting_human_since, extra)
select tests.id('org_a'), 'whatsapp', tests.val('wa_a'), 'perf-notified-' || i, now() - interval '20 days', '{"human_wait_notified_at":"2026-01-01T00:00:00Z"}'::jsonb
from generate_series(1, 501) i;
update public.organizations set extra = '{"attention":{"on_human_wait_timeout":"return_to_ai"}}' where id = tests.id('org_b');
insert into public.conversations (organization_id, service, organization_address, address, awaiting_human_since)
values (tests.id('org_b'), 'whatsapp', tests.val('wa_b'), 'perf-waiting', now() - interval '10 days');
select is(public.sweep_awaiting_human(1), 1, '501 already-notified waits cannot starve another eligible tenant');
select is((select awaiting_human_since from public.conversations where address = 'perf-waiting'), null::timestamptz, 'eligible wait is cleared');

-- Retention is opt-in and terminal states only, even for very old work.
insert into public.edge_calls (organization_id, function, record_id, payload, status, updated_at)
select tests.id('org_a'), 'agent-client', gen_random_uuid(), '{}', status, now() - interval '100 days'
from unnest(array['done','failed','pending','sending']) status;
select is((public.purge_expired_rows(1000)->>'edge_calls')::int, 0, 'default retention preserves every queue row');
update public.organizations set extra = '{"queue_retention":{"success_days":7,"failure_days":90}}' where id = tests.id('org_a');
select is((public.purge_expired_rows(1)->>'edge_calls')::int, 1, 'terminal retention respects its batch limit');
select is((public.purge_expired_rows(1)->>'edge_calls')::int, 1, 'another tick purges the remaining eligible terminal row');
select is((select count(*)::int from public.edge_calls where organization_id = tests.id('org_a') and updated_at < now() - interval '99 days'), 2, 'old pending and sending work survive retention');

-- Concentrated history: top-N per-conversation remains exact, with ties.
insert into public.messages (organization_id, service, organization_address, conversation_address, sender_address, external_id, content, timestamp)
select tests.id('org_a'), 'whatsapp', tests.val('wa_a'), 'perf-concentrated', 'perf-concentrated', 'perf-message-' || i,
  '{"version":"1","type":"text","kind":"text","text":"performance"}', now() - interval '1 hour'
from generate_series(1, 2000) i;
select results_eq(
  $$ select (m->>'id')::uuid from json_array_elements(public.init_data(tests.id('org_a'), 200, 10)->'messages') m where m->>'conversation_address' = 'perf-concentrated' $$,
  $$ select id from public.messages where organization_id = tests.id('org_a') and conversation_address = 'perf-concentrated' order by timestamp desc, id desc limit 10 $$,
  'a concentrated tied history returns exactly ten newest IDs'
);
-- Counters remain synchronous and all periods receive the same delta.
create temporary table before_billing as select interval, period, quantity from billing.usage where organization_id = tests.id('org_b') and product_id = 'messages';
select billing.update_usage(tests.id('org_b'), 'messages', 2);
select billing.update_usage(tests.id('org_b'), 'messages', -1);
select results_eq($$select u.interval::text, (u.quantity - coalesce(b.quantity, 0))::int from billing.usage u left join before_billing b using (interval, period) where u.organization_id = tests.id('org_b') and u.product_id = 'messages' order by u.interval::text$$, $$values ('day'::text,1), ('lifetime',1), ('month',1)$$, 'single-statement billing applies the exact delta to all three periods');
select lives_ok($$select billing.update_usage(tests.id('org_b'), 'unknown-performance-product', 1)$$, 'unknown products still do not create usage');
select * from finish();
rollback;
