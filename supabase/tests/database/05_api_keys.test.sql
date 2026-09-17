-- F14 — API keys stored in the clear, without expiry or last use.
--
-- Failure scenario: a leak of the api_keys table is a leak of every key;
-- `select key` as an owner returns the secrets; a key never expires and
-- nobody can tell whether it is still in use.
--
-- P8 closes the migration F14 opened: the `key` write slot and the plaintext
-- comparison it allowed are gone, ahead of the announced 2026-11-01 cutover
-- (there is no deployment holding such a row). A key exists in the clear
-- exactly once, in the reply from create_api_key.
begin;
select plan(15);

-- ---------------------------------------------------------------------------
-- Nothing stored in the clear — there is nowhere left to store it.
-- ---------------------------------------------------------------------------

select hasnt_column(
  'public', 'api_keys', 'key',
  'the plaintext column is gone'
);

select hasnt_function(
  'public', 'api_key_plaintext_cutover', array[]::text[],
  'and so is the cutover it was honoured until'
);

-- Writing one is a column that does not exist, not a value that is ignored.
select throws_ok(
  $$
    insert into public.api_keys (organization_id, key, role, name)
    values (tests.id('org_a'), 'sk_plaintext', 'member', 'Nope')
  $$,
  '42703', null,
  'a client cannot hand the database a key any more'
);

select tests.authenticate_as('alice@test.local');

select is(
  (select key_prefix from public.api_keys where name = 'A member key'),
  left(tests.val('key_a_member'), 8),
  'owner: the prefix is visible'
);

-- ---------------------------------------------------------------------------
-- Authentication compares the hash.
-- ---------------------------------------------------------------------------

select tests.clear_authentication();
select tests.authenticate_with_api_key(tests.val('key_a_member'));

select is(
  (select count(*) from public.messages where organization_id = tests.id('org_a')),
  4::bigint,
  'a key authenticates by hash and reads its org'
);

select is(
  (select count(*) from public.api_keys),
  1::bigint,
  'a member key sees exactly its own row'
);

select is(
  (select last_used_at is not null from public.api_keys),
  true,
  'use stamps last_used_at'
);

-- ---------------------------------------------------------------------------
-- Expiry.
-- ---------------------------------------------------------------------------

select tests.clear_authentication();

insert into public.api_keys (organization_id, key_hash, key_prefix, role, name, expires_at)
values (
  tests.id('org_a'),
  extensions.digest('test-key-expired-0000000000000000000', 'sha256'),
  'test-key', 'member', 'Expired', now() - interval '1 hour'
);

select tests.authenticate_with_api_key('test-key-expired-0000000000000000000');

select is(
  (select count(*) from public.messages),
  0::bigint,
  'an expired key reads nothing'
);

select tests.clear_authentication();

-- A row with no hash at all — what the cutover used to let through — is now
-- a row that authenticates nothing, whatever is presented.
insert into public.api_keys (organization_id, key_prefix, role, name)
values (tests.id('org_a'), 'test-key', 'member', 'Hashless');

select tests.authenticate_with_api_key('test-key-legacy-00000000000000000000');

select is(
  (select count(*) from public.organizations),
  0::bigint,
  'a row without a hash authenticates nothing'
);

select tests.clear_authentication();

-- ---------------------------------------------------------------------------
-- create_api_key: the secret is returned once, to owners.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('alice@test.local');

create temp table minted on commit drop as
select * from public.create_api_key(tests.id('org_a'), 'Minted', 'admin', null);

select is((select count(*) from minted), 1::bigint, 'owner: create_api_key mints one key');

select matches(
  (select key from minted),
  '^sk_[0-9a-f]{48}$',
  'the returned key is sk_ + 48 hex chars'
);

select is(
  (select key_prefix from minted),
  (select left(key, 8) from minted),
  'the returned prefix is the first 8 characters'
);

select is(
  (select key_hash from public.api_keys where id = (select id from minted)),
  (select extensions.digest(key, 'sha256') from minted),
  'the minted row stores sha256(key)'
);

select tests.clear_authentication();
select tests.authenticate_as('amber@test.local');

select throws_ok(
  $$ select * from public.create_api_key(tests.id('org_a'), 'Nope', 'member', null) $$,
  '42501',
  null,
  'member: create_api_key is refused'
);

select tests.clear_authentication();

-- The minted key authenticates with the role it was given.
select tests.authenticate_with_api_key((select key from minted));

select is(
  (select count(*) from public.organizations),
  1::bigint,
  'the minted key authenticates'
);

select * from finish();
rollback;
