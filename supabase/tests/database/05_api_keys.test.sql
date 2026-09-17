-- F14 — API keys stored in the clear, without expiry or last use.
--
-- Failure scenario: a leak of the api_keys table is a leak of every key;
-- `select key` as an owner returns the secrets; a key never expires and
-- nobody can tell whether it is still in use.
begin;
select plan(16);

-- ---------------------------------------------------------------------------
-- Nothing stored in the clear.
-- ---------------------------------------------------------------------------

select is(
  (select count(*) from public.api_keys where key is not null),
  0::bigint,
  'no stored row holds a plain key'
);

select tests.authenticate_as('alice@test.local');

select is(
  (select count(*) from public.api_keys where key is not null),
  0::bigint,
  'owner: select key returns no secret'
);

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

insert into public.api_keys (organization_id, key, role, name, expires_at)
values (tests.id('org_a'), 'test-key-expired-0000000000000000000', 'member',
        'Expired', now() - interval '1 hour');

select tests.authenticate_with_api_key('test-key-expired-0000000000000000000');

select is(
  (select count(*) from public.messages),
  0::bigint,
  'an expired key reads nothing'
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
  (select key from public.api_keys where id = (select id from minted)),
  null,
  'the minted row stores no plain key'
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

-- ---------------------------------------------------------------------------
-- Plaintext double-read ends at the cutover.
-- ---------------------------------------------------------------------------

select tests.clear_authentication();

-- A legacy row: plain key, no hash (the trigger is held back to fake it).
alter table public.api_keys disable trigger a_hash_api_key;
insert into public.api_keys (organization_id, key, role, name)
values (tests.id('org_a'), 'test-key-legacy-00000000000000000000', 'member', 'Legacy');
alter table public.api_keys enable trigger a_hash_api_key;

-- Before the cutover (moved into the future for this transaction).
create or replace function public.api_key_plaintext_cutover() returns timestamp with time zone
language sql immutable as $$ select now() + interval '1 day' $$;

select tests.authenticate_with_api_key('test-key-legacy-00000000000000000000');

select is(
  (select count(*) from public.organizations),
  1::bigint,
  'before the cutover a plaintext-only row still authenticates'
);

select tests.clear_authentication();

-- After the cutover.
create or replace function public.api_key_plaintext_cutover() returns timestamp with time zone
language sql immutable as $$ select now() - interval '1 day' $$;

select tests.authenticate_with_api_key('test-key-legacy-00000000000000000000');

select is(
  (select count(*) from public.organizations),
  0::bigint,
  'after the cutover a plaintext-only row authenticates nothing'
);

select * from finish();
rollback;
