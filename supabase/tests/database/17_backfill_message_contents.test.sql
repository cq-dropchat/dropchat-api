-- §5.2 — backfill of v0 message content.
--
-- The conversion runs in Deno (functions/_shared/messages_v0.ts, checked
-- against the UI's toV1). This function only writes what it is given, and a
-- plain UPDATE could not: set_message merge-patches content (the v0 keys
-- would survive next to the v1 ones), set_updated_at would move every old
-- row to "just changed", and notify_webhook would tell every subscriber
-- about tens of thousands of rows. So it replaces content wholesale with the
-- table's user triggers off, for the length of its own transaction.
begin;
select plan(16);

select has_function(
  'public', 'backfill_message_contents', array['jsonb'],
  'backfill_message_contents exists'
);

-- Two v0 rows: the check constraint is NOT VALID in production for exactly
-- these rows, and new ones cannot be inserted with it in place.
alter table public.messages drop constraint messages_content_schema;

insert into public.messages (
  id, organization_id, service, organization_address, conversation_address,
  sender_address, content, status, timestamp, created_at, updated_at
) values
  ('aaaaaaaa-0000-4000-8000-00000000b501', tests.id('org_a'), 'whatsapp',
   tests.val('wa_a'), tests.val('contact_a1'), tests.val('contact_a1'),
   '{"type": "text", "content": "hola vieja", "re_message_id": "wamid.X"}',
   '{"delivered": "2025-01-01T00:00:00Z"}',
   '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z'),
  ('aaaaaaaa-0000-4000-8000-00000000b502', tests.id('org_a'), 'whatsapp',
   tests.val('wa_a'), tests.val('contact_a1'), tests.val('contact_a1'),
   '{"type": "location", "location": {"name": "Casa"}}',
   '{"delivered": "2025-01-01T00:00:00Z"}',
   '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z');

alter table public.messages add constraint messages_content_schema check (
  content = '{}'::jsonb
  or (
    content->>'version' is not null
    and content->>'type' in ('text', 'file', 'data')
    and content->>'kind' is not null
  )
) not valid;

-- ALTER TABLE cannot run while the calling statement itself reads messages,
-- so the ids a call needs are read beforehand.
create temp table v1_row as
select id from public.messages where content->>'version' = '1' limit 1;

create temp table marks as
select
  (select count(*) from public.webhook_deliveries) as deliveries,
  (select coalesce(max(id), 0) from net.http_request_queue) as queue_id;

select is(
  public.backfill_message_contents(jsonb_build_array(
    jsonb_build_object(
      'id', 'aaaaaaaa-0000-4000-8000-00000000b501',
      'content', '{"version": "1", "re_message_id": "wamid.X", "type": "text", "kind": "text", "text": "hola vieja"}'::jsonb
    ),
    -- Already v1 (a row converted in between): left alone.
    jsonb_build_object(
      'id', (select id from v1_row),
      'content', '{"version": "1", "type": "text", "kind": "text", "text": "overwritten"}'::jsonb
    )
  )),
  1,
  'it writes the v0 row and skips the one that is already v1'
);

select is(
  (select content from public.messages where id = 'aaaaaaaa-0000-4000-8000-00000000b501'),
  '{"version": "1", "re_message_id": "wamid.X", "type": "text", "kind": "text", "text": "hola vieja"}'::jsonb,
  'content is replaced whole, not merged: no v0 key survives'
);

select is(
  (select count(*)::int from public.messages where content->>'text' = 'overwritten'),
  0,
  'a v1 row is never overwritten'
);

select is(
  (select updated_at from public.messages where id = 'aaaaaaaa-0000-4000-8000-00000000b501'),
  '2025-01-01T00:00:00Z'::timestamptz,
  'updated_at does not move (no set_updated_at)'
);

select is(
  (select status from public.messages where id = 'aaaaaaaa-0000-4000-8000-00000000b501'),
  '{"delivered": "2025-01-01T00:00:00Z"}'::jsonb,
  'status is untouched'
);

select is(
  (select count(*) from public.webhook_deliveries) - (select deliveries from marks),
  0::bigint,
  'no webhook delivery is queued'
);

select is(
  (select count(*)::int from net.http_request_queue where id > (select queue_id from marks)),
  0,
  'no Edge Function request is queued'
);

select is(
  (select count(*)::int from pg_trigger
   where tgrelid = 'public.messages'::regclass and not tgisinternal and tgenabled <> 'O'),
  0,
  'the triggers are enabled again afterwards'
);

select throws_ok(
  $$ select public.backfill_message_contents(jsonb_build_array(jsonb_build_object(
       'id', 'aaaaaaaa-0000-4000-8000-00000000b502',
       'content', '{"type": "data"}'::jsonb))) $$,
  '23514', null,
  'a content without the v1 shape is refused by the check constraint'
);

select throws_ok(
  $$ select public.backfill_message_contents(
       (select jsonb_agg(jsonb_build_object('id', gen_random_uuid(), 'content', '{}'::jsonb))
        from generate_series(1, 1001))) $$,
  '22023', null,
  'a batch over 1,000 rows is refused'
);

-- ---------------------------------------------------------------------------
-- Service role only.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('alice@test.local');
select throws_ok($$ select public.backfill_message_contents('[]') $$, '42501', null, 'owner A cannot run it');
select tests.clear_authentication();

select tests.authenticate_as('bob@test.local');
select throws_ok($$ select public.backfill_message_contents('[]') $$, '42501', null, 'user B cannot run it');
select tests.clear_authentication();

select tests.authenticate_with_api_key('test-key-b-member-000000000000000000');
select throws_ok($$ select public.backfill_message_contents('[]') $$, '42501', null, 'API key B cannot run it');
select tests.clear_authentication();

select tests.authenticate_with_api_key('test-key-a-owner-0000000000000000000');
select throws_ok($$ select public.backfill_message_contents('[]') $$, '42501', null, 'API key A cannot run it');
select tests.clear_authentication();

select tests.authenticate_as_anon();
select throws_ok($$ select public.backfill_message_contents('[]') $$, '42501', null, 'anon cannot run it');
select tests.clear_authentication();

select * from finish();
rollback;
