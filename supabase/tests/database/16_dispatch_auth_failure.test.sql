-- F28 — an expired Meta token failed every outgoing message on its own.
--
-- The dispatcher now marks the account with `extra.dispatch_auth_failure`
-- ({code, message, at}) on the first 190 and fails later messages without
-- calling Meta. This file covers the database half: storing a NEW token
-- (re-onboarding, a refresh, a manual fix) clears the mark in the same write,
-- in extract_secrets; writing the mask back or touching other keys does not;
-- and no API role can set or clear the mark itself.
begin;
select plan(10);

create temp table addr as
select organization_id, service, address
from public.organizations_addresses
where organization_id = tests.id('org_a') and service = 'whatsapp' and address = tests.val('wa_a');

grant select on addr to authenticated, anon;

create or replace function pg_temp.mark() returns jsonb language sql as $$
  select oa.extra -> 'dispatch_auth_failure'
  from public.organizations_addresses oa join addr using (organization_id, service, address)
$$;

create or replace function pg_temp.set_mark() returns void language sql as $$
  update public.organizations_addresses oa
  set extra = '{"dispatch_auth_failure": {"code": 190, "message": "Session has expired", "at": "2026-09-17T00:00:00Z"}}'
  from addr where oa.organization_id = addr.organization_id and oa.service = addr.service and oa.address = addr.address
$$;

create or replace function pg_temp.write_extra(_extra jsonb) returns void language sql as $$
  update public.organizations_addresses oa
  set extra = _extra
  from addr where oa.organization_id = addr.organization_id and oa.service = addr.service and oa.address = addr.address
$$;

select pg_temp.set_mark();
select is((pg_temp.mark() ->> 'code')::int, 190, 'the service role marks the account');

select pg_temp.write_extra('{"access_token": "********"}');
select isnt(pg_temp.mark(), null, 'writing the mask back (a form save) keeps the mark');

select pg_temp.write_extra('{"verified_name": "Alpha Shop"}');
select isnt(pg_temp.mark(), null, 'changing another key keeps the mark');

select pg_temp.write_extra('{"access_token": "EAAG-test-secret-a-renewed"}');
select is(pg_temp.mark(), null, 'a new token clears the mark');
select is(
  (select s.value ->> 'access_token' from public.secrets s
   join addr on s.organization_id = addr.organization_id
   and s.ref = 'whatsapp:' || addr.address and s.scope = 'address'),
  'EAAG-test-secret-a-renewed',
  'and the new token is stored as a secret, as before'
);

-- ---------------------------------------------------------------------------
-- API roles can read the mark (members see why sends fail) but not write it.
-- ---------------------------------------------------------------------------

select pg_temp.set_mark();

select tests.authenticate_as('alice@test.local');
select pg_temp.write_extra('{"dispatch_auth_failure": null}');
select tests.clear_authentication();
select isnt(pg_temp.mark(), null, 'owner A cannot clear the mark (no update on accounts)');

select tests.authenticate_with_api_key('test-key-a-owner-0000000000000000000');
select pg_temp.write_extra('{"dispatch_auth_failure": null}');
select tests.clear_authentication();
select isnt(pg_temp.mark(), null, 'API key A cannot clear the mark');

select tests.authenticate_as('bob@test.local');
select is(
  (select count(*)::int from public.organizations_addresses oa join addr using (organization_id, service, address)),
  0,
  'user B does not see account A (nor its mark)'
);
select tests.clear_authentication();

select tests.authenticate_with_api_key('test-key-b-member-000000000000000000');
select is(
  (select count(*)::int from public.organizations_addresses oa join addr using (organization_id, service, address)),
  0,
  'API key B does not see account A'
);
select tests.clear_authentication();

select tests.authenticate_as_anon();
select throws_ok(
  $$ select count(*) from public.organizations_addresses $$,
  null, null, 'anon reads no account'
);
select tests.clear_authentication();

select * from finish();
rollback;
