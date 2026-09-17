-- §5.2 (P3) — `messages_content_schema` is VALIDATED.
--
-- The constraint shipped NOT VALID because the deployed database held legacy
-- rows whose content predates the v1 schema (no version, no kind): it checked
-- every new row but could say nothing about the old ones, so no reader could
-- assume the shape. The backfill that converts them
-- (functions/_scripts/backfill_messages_v1.ts, with the writer
-- public.backfill_message_contents) has run and reported nothing left to
-- write, so the constraint is now validated and both are gone.
--
-- What this file fixes is the guarantee: every row in the table satisfies the
-- shape, not merely every row written from here on.
begin;
select plan(7);

select is(
  (
    select convalidated
    from pg_constraint
    where conrelid = 'public.messages'::regclass
      and conname = 'messages_content_schema'
  ),
  true,
  'messages_content_schema is validated, so it holds for every existing row'
);

select hasnt_function(
  'public', 'backfill_message_contents', array['jsonb'],
  'the backfill writer is gone'
);

-- ---------------------------------------------------------------------------
-- What the constraint refuses, from the role that bypasses RLS
-- ---------------------------------------------------------------------------

select throws_ok(
  $$
    insert into public.messages (
      organization_id, service, organization_address, conversation_address,
      sender_address, content, status
    ) values (
      tests.id('org_a'), 'whatsapp', tests.val('wa_a'), tests.val('contact_a1'),
      tests.val('contact_a1'),
      '{"type": "text", "content": "hola vieja", "re_message_id": "wamid.X"}',
      '{"delivered": "2025-01-01T00:00:00Z"}'
    )
  $$,
  '23514', null,
  'a v0 content (no version, no kind) violates the constraint'
);

select throws_ok(
  $$
    insert into public.messages (
      organization_id, service, organization_address, conversation_address,
      sender_address, content, status
    ) values (
      tests.id('org_a'), 'whatsapp', tests.val('wa_a'), tests.val('contact_a1'),
      tests.val('contact_a1'),
      '{"version": "1", "type": "text", "text": "sin kind"}',
      '{"delivered": "2025-01-01T00:00:00Z"}'
    )
  $$,
  '23514', null,
  'a v1 content without kind violates it too'
);

-- ---------------------------------------------------------------------------
-- What it still allows
-- ---------------------------------------------------------------------------

-- A status-only upsert: the content is merged in by a later write.
select lives_ok(
  $$
    insert into public.messages (
      organization_id, service, organization_address, conversation_address,
      sender_address, content, status
    ) values (
      tests.id('org_a'), 'whatsapp', tests.val('wa_a'), tests.val('contact_a1'),
      tests.val('contact_a1'), '{}',
      '{"delivered": "2025-01-01T00:00:00Z"}'
    )
  $$,
  'an empty content is still allowed (status-only upsert)'
);

select lives_ok(
  $$
    insert into public.messages (
      organization_id, service, organization_address, conversation_address,
      sender_address, content, status
    ) values (
      tests.id('org_a'), 'whatsapp', tests.val('wa_a'), tests.val('contact_a1'),
      tests.val('contact_a1'),
      '{"version": "1", "type": "text", "kind": "text", "text": "hola"}',
      '{"delivered": "2025-01-01T00:00:00Z"}'
    )
  $$,
  'a v1 content is allowed'
);

-- And the table it guards holds no v0 row at all: what the backfill was for.
select is(
  (
    select count(*)
    from public.messages
    where content <> '{}'::jsonb and content->>'version' is null
  ),
  0::bigint,
  'no message predates the v1 content schema'
);

select * from finish();
rollback;
