-- Trace (b) (IMPLEMENTATION_PROMPT §5): a member uploads an attachment →
-- storage.objects under their organization's path → is_media_visible lets a
-- member download it and refuses another organization → the storage cap
-- refuses an upload over the plan.
--
-- Path convention: organizations/<org_id>/attachments/<file_id>.
begin;
select plan(17);

create temp table trace_b (name text primary key, value text);
insert into trace_b values
  ('own', 'organizations/aaaaaaaa-0000-4000-8000-000000000001/attachments/trace-b-own'),
  ('foreign', 'organizations/bbbbbbbb-0000-4000-8000-000000000001/attachments/trace-b-foreign'),
  ('huge', 'organizations/aaaaaaaa-0000-4000-8000-000000000001/attachments/trace-b-huge');
grant select on trace_b to anon, authenticated;

create function pg_temp.path(_name text) returns text language sql stable as $$
  select value from trace_b where name = _name
$$;

create temp table usage_before as
select quantity from billing.usage
where organization_id = tests.id('org_a') and product_id = 'storage' and interval = 'lifetime';

-- ---------------------------------------------------------------------------
-- Upload.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('amber@test.local');

select lives_ok(
  $$ insert into storage.objects (bucket_id, name, metadata)
     values ('media', pg_temp.path('own'), '{"size": 1000000, "mimetype": "image/jpeg"}') $$,
  'a member uploads under their organization''s path'
);

select throws_ok(
  $$ insert into storage.objects (bucket_id, name, metadata)
     values ('media', pg_temp.path('foreign'), '{"size": 10, "mimetype": "image/jpeg"}') $$,
  '42501', null,
  'a member cannot upload under another organization''s path'
);

select tests.clear_authentication();

select is(
  (select count(*)::int from storage.objects where bucket_id = 'media' and name = pg_temp.path('own')),
  1,
  'the object exists at the organization''s path'
);

select ok(
  (select quantity from billing.usage
   where organization_id = tests.id('org_a') and product_id = 'storage' and interval = 'lifetime')
  - (select quantity from usage_before) = 0.001,
  'the upload counts 1 MB of storage usage'
);

-- The message that carries it (as the composer sends it).
insert into public.messages (
  organization_id, service, organization_address, conversation_address,
  sender_address, agent_id, content, status, timestamp
) values (
  tests.id('org_a'), 'whatsapp', tests.val('wa_a'), tests.val('contact_a1'),
  null, tests.id('agent_amber'),
  jsonb_build_object(
    'version', '1', 'type', 'file', 'kind', 'image',
    'file', jsonb_build_object('uri', 'internal://media/' || pg_temp.path('own'),
                               'mime_type', 'image/jpeg', 'size', 1000000)
  ),
  '{"delivered": "2026-09-10T10:00:00Z"}',
  now() - interval '1 minute'
);

select is(
  (select count(*)::int from public.messages
   where content->'file'->>'uri' = 'internal://media/' || pg_temp.path('own')),
  1,
  'a message references the object (what is_media_visible resolves)'
);

-- ---------------------------------------------------------------------------
-- Download, per caller.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('alice@test.local');
select is(
  (select count(*)::int from storage.objects where name = pg_temp.path('own')),
  1, 'user A (owner) downloads it'
);
select tests.clear_authentication();

select tests.authenticate_as('amber@test.local');
select is(
  (select count(*)::int from storage.objects where name = pg_temp.path('own')),
  1, 'user A (the member who sent it) downloads it'
);
select tests.clear_authentication();

select tests.authenticate_as('bob@test.local');
select is(
  (select count(*)::int from storage.objects where name = pg_temp.path('own')),
  0, 'user B (another organization) does not'
);
select is(
  (select count(*)::int from storage.objects where name like 'organizations/aaaaaaaa-%'),
  0, 'nor any of organization A''s objects'
);
select tests.clear_authentication();

select tests.authenticate_with_api_key('test-key-a-member-000000000000000000');
select is(
  (select count(*)::int from storage.objects where name = pg_temp.path('own')),
  1, 'API key A downloads it'
);
select tests.clear_authentication();

select tests.authenticate_with_api_key('test-key-b-member-000000000000000000');
select is(
  (select count(*)::int from storage.objects where name = pg_temp.path('own')),
  0, 'API key B does not'
);
select throws_ok(
  $$ insert into storage.objects (bucket_id, name, metadata)
     values ('media', pg_temp.path('own') || '-b', '{"size": 10}') $$,
  '42501', null,
  'API key B cannot upload into organization A'
);
select tests.clear_authentication();

select tests.authenticate_as_anon();
select throws_ok(
  $$ select count(*) from storage.objects where name = pg_temp.path('own') $$,
  '42501', null, 'anon (no key) is refused outright'
);
select tests.clear_authentication();

-- ---------------------------------------------------------------------------
-- Storage cap: the free plan holds 1 GB for the organization's lifetime.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('amber@test.local');

select throws_ok(
  $$ insert into storage.objects (bucket_id, name, metadata)
     values ('media', pg_temp.path('huge'), '{"size": 2000000000, "mimetype": "video/mp4"}') $$,
  'PT402', null,
  'an upload over the plan''s storage cap is refused'
);

select tests.clear_authentication();

select is(
  (select count(*)::int from storage.objects where name = pg_temp.path('huge')),
  0, 'and nothing is stored'
);
select ok(
  (select quantity from billing.usage
   where organization_id = tests.id('org_a') and product_id = 'storage' and interval = 'lifetime')
  - (select quantity from usage_before) = 0.001,
  'nor counted'
);

-- Organization B is not affected by A's usage.
select tests.authenticate_as('bob@test.local');
select lives_ok(
  $$ insert into storage.objects (bucket_id, name, metadata)
     values ('media', pg_temp.path('foreign'), '{"size": 10, "mimetype": "image/jpeg"}') $$,
  'organization B uploads under its own path'
);
select tests.clear_authentication();

select * from finish();
rollback;
