-- F18 — the media of an account-scoped deletion.
--
-- Failure scenario: Meta's data-deletion callback for one account files a
-- request that sweep_deletions carries out row by row, but the organization
-- stays, so storage-gc (which removes the folders of organizations that no
-- longer exist) never touched that account's files: every attachment of the
-- deleted account stayed in Storage.
--
-- Objects are content-addressed (organizations/<org>/attachments/<sha256>):
-- the same object can back messages of other accounts of the organization,
-- so it cannot be deleted just because a deleted message referenced it.
--
-- Now: while deleting an account's messages, the sweep records the internal
-- objects they referenced under that organization's path
-- (public.deletion_media). storage-gc asks pending_deletion_media which of
-- them no message still references, removes those through the Storage API,
-- and forgets every row it handled (forget_deletion_media).
begin;
select plan(17);

select has_table('public', 'deletion_media', 'deletion_media exists');

create temp table f18 (name text primary key, value text);
insert into f18 values
  ('ig', '17840000000000077'),
  ('exclusive', 'organizations/aaaaaaaa-0000-4000-8000-000000000001/attachments/f18-exclusive'),
  ('shared', 'organizations/aaaaaaaa-0000-4000-8000-000000000001/attachments/f18-shared'),
  ('foreign', 'organizations/bbbbbbbb-0000-4000-8000-000000000001/attachments/f18-foreign');

create function pg_temp.v(_name text) returns text language sql stable as $$
  select value from f18 where name = _name
$$;

create function pg_temp.file(_uri text) returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'version', '1', 'type', 'file', 'kind', 'image',
    'file', jsonb_build_object('uri', _uri, 'mime_type', 'image/jpeg', 'size', 10)
  )
$$;

-- A second account in org A: an Instagram account about to be deleted.
insert into public.organizations_addresses (organization_id, service, address, status)
values (tests.id('org_a'), 'instagram', pg_temp.v('ig'), 'connected');

insert into public.messages (organization_id, service, organization_address, conversation_address, sender_address, content, status)
values
  -- On the Instagram account: an object only it uses, one the WhatsApp
  -- account uses too, an external URL, and a URI naming another
  -- organization's path.
  (tests.id('org_a'), 'instagram', pg_temp.v('ig'), '9990000000077', '9990000000077',
   pg_temp.file('internal://media/' || pg_temp.v('exclusive')), '{"delivered": "2026-09-10T10:00:00Z"}'),
  (tests.id('org_a'), 'instagram', pg_temp.v('ig'), '9990000000077', '9990000000077',
   pg_temp.file('internal://media/' || pg_temp.v('shared')), '{"delivered": "2026-09-10T10:00:00Z"}'),
  (tests.id('org_a'), 'instagram', pg_temp.v('ig'), '9990000000077', '9990000000077',
   pg_temp.file('https://cdn.example.com/f18.jpg'), '{"delivered": "2026-09-10T10:00:00Z"}'),
  (tests.id('org_a'), 'instagram', pg_temp.v('ig'), '9990000000077', '9990000000077',
   pg_temp.file('internal://media/' || pg_temp.v('foreign')), '{"delivered": "2026-09-10T10:00:00Z"}'),
  -- On the WhatsApp account, which stays.
  (tests.id('org_a'), 'whatsapp', tests.val('wa_a'), tests.val('contact_a1'), tests.val('contact_a1'),
   pg_temp.file('internal://media/' || pg_temp.v('shared')), '{"delivered": "2026-09-10T10:00:00Z"}');

create temp table req as
select public.request_address_deletion(tests.id('org_a'), 'instagram', pg_temp.v('ig'), 'meta_data_deletion') as id;

-- Swept to completion.
do $$
begin
  for i in 1..20 loop
    exit when (public.sweep_deletions(5000) ->> 'request') is null;
  end loop;
end;
$$;

select is(
  (select count(*)::int from public.messages
   where organization_id = tests.id('org_a') and organization_address = '17840000000000077'),
  0,
  'the account''s messages are gone'
);

-- ---------------------------------------------------------------------------
-- What the sweep recorded.
-- ---------------------------------------------------------------------------

select set_eq(
  $$ select object_name from public.deletion_media where request_id = (select id from req) $$,
  $$ select value from f18 where name in ('exclusive', 'shared') $$,
  'the deleted messages'' internal objects under the organization are recorded'
);

select is(
  (select count(*)::int from public.deletion_media where object_name like '%f18.jpg'),
  0,
  'an external URL is not'
);

select is(
  (select count(*)::int from public.deletion_media where object_name = pg_temp.v('foreign')),
  0,
  'a URI naming another organization''s path is not'
);

select is(
  (select bool_and(organization_id = tests.id('org_a')) from public.deletion_media where request_id = (select id from req)),
  true,
  'each row names the organization'
);

-- ---------------------------------------------------------------------------
-- Which ones storage-gc may remove.
-- ---------------------------------------------------------------------------

select is(
  (select referenced from public.pending_deletion_media(100) where object_name = pg_temp.v('exclusive')),
  false,
  'an object no remaining message references can be removed'
);

select is(
  (select referenced from public.pending_deletion_media(100) where object_name = pg_temp.v('shared')),
  true,
  'an object another account of the organization still uses is kept'
);

select is(
  (select count(*)::int from public.pending_deletion_media(100) where organization_id <> tests.id('org_a')),
  0,
  'nothing of another organization is offered'
);

select is(
  (select count(*)::int from public.pending_deletion_media(1)),
  1,
  'the batch is bounded'
);

select is(
  public.forget_deletion_media(tests.id('org_a'), array[pg_temp.v('exclusive'), pg_temp.v('shared')]),
  2,
  'forget_deletion_media drops the handled rows'
);

select is(
  (select count(*)::int from public.pending_deletion_media(100)
   where object_name in (pg_temp.v('exclusive'), pg_temp.v('shared'))),
  0,
  'and they are not offered again'
);

-- ---------------------------------------------------------------------------
-- Service role only.
-- ---------------------------------------------------------------------------

create function pg_temp.refused(_who text) returns setof text language plpgsql as $$
begin
  return next throws_ok(
    $q$ select * from public.pending_deletion_media(10) $q$,
    '42501', null, _who || ' cannot list pending media'
  );
end;
$$;

select tests.authenticate_as('alice@test.local');
select pg_temp.refused('user A');
select tests.clear_authentication();

select tests.authenticate_as('bob@test.local');
select pg_temp.refused('user B');
select tests.clear_authentication();

select tests.authenticate_with_api_key('test-key-a-owner-0000000000000000000');
select pg_temp.refused('API key A');
select tests.clear_authentication();

select tests.authenticate_with_api_key('test-key-b-member-000000000000000000');
select pg_temp.refused('API key B');
select tests.clear_authentication();

select tests.authenticate_as_anon();
select pg_temp.refused('anon');
select tests.clear_authentication();

select * from finish();
rollback;
