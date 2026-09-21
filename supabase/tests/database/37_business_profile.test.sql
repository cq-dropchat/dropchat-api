-- T1 — the business profile: who may write it, and what a write actually does.
--
-- Two separate subjects, and the second is the one that bites.
--
-- WHO. `organizations.extra` has one UPDATE policy and it is admin's. The
-- profile is not a new permission, it is new CONTENT in a column that already
-- had one — which is exactly the case worth pinning, because a screen that
-- shows a member seven friendly fields and then saves nothing is a bug report,
-- and a member who CAN save them is a different product.
--
-- WHAT. `extra` is written as a JSON merge patch (merge_update, §3.6), and the
-- profile is the first nested object in it with a LIST inside. The rule there
-- is not the rule for the object: the object merges key by key, the list is
-- replaced whole. A screen that sends only the method the merchant just ticked
-- deletes the other four, silently, and the agent stops offering them. The
-- three assertions at the end are what the UI is built against.
begin;
select plan(14);

-- The starting profile, seeded as the session user: what the organization had
-- before anybody tried to change it.
update public.organizations
set extra = '{
  "business_profile": {
    "industry": "Zapatillas urbanas",
    "payment_methods": ["Webpay", "Transferencia"]
  }
}'::jsonb
where id = tests.id('org_a');

-- ---------------------------------------------------------------------------
-- Who.
-- ---------------------------------------------------------------------------

-- Amber is a member of A. «admins can update their orgs» does not match her,
-- and with no matching policy an UPDATE is a silent no-op: it touches zero
-- rows and reports success, so the only way to see it is to read back.
select tests.authenticate_as('amber@test.local');

update public.organizations
set extra = '{"business_profile": {"industry": "Casino"}}'::jsonb
where id = tests.id('org_a');

select tests.clear_authentication();
select is(
  (select extra #>> '{business_profile,industry}' from public.organizations
   where id = tests.id('org_a')),
  'Zapatillas urbanas',
  'a member does not write the business profile'
);

-- The positive control for reading. The screen shows the profile to everybody
-- in the organization and only lets an admin save it, so a member who cannot
-- READ it would be looking at an empty form with no way to know why.
select tests.authenticate_as('amber@test.local');
select is(
  (select extra #>> '{business_profile,industry}' from public.organizations
   where id = tests.id('org_a')),
  'Zapatillas urbanas',
  'a member reads the business profile'
);
select tests.clear_authentication();

select tests.authenticate_as('alice@test.local');

update public.organizations
set extra = '{"business_profile": {"industry": "Zapatillas y outdoor"}}'::jsonb
where id = tests.id('org_a');

select tests.clear_authentication();
select is(
  (select extra #>> '{business_profile,industry}' from public.organizations
   where id = tests.id('org_a')),
  'Zapatillas y outdoor',
  'the owner writes it'
);

-- Bob owns B. `get_authorized_orgs` never crosses tenants, so for him org A
-- neither exists to write nor to read.
select tests.authenticate_as('bob@test.local');

update public.organizations
set extra = '{"business_profile": {"industry": "Casino"}}'::jsonb
where id = tests.id('org_a');

select is(
  (select count(*)::int from public.organizations
   where id = tests.id('org_a')),
  0,
  'the owner of another organization does not read this profile'
);
select tests.clear_authentication();
select is(
  (select extra #>> '{business_profile,industry}' from public.organizations
   where id = tests.id('org_a')),
  'Zapatillas y outdoor',
  'and does not write it either'
);

-- An API key runs as `anon` with the header; the policy is
-- `to authenticated, anon`, so what decides is the key's role, not the role it
-- connects as.
select tests.authenticate_with_api_key(tests.val('key_a_member'));

update public.organizations
set extra = '{"business_profile": {"industry": "Casino"}}'::jsonb
where id = tests.id('org_a');

select tests.clear_authentication();
select is(
  (select extra #>> '{business_profile,industry}' from public.organizations
   where id = tests.id('org_a')),
  'Zapatillas y outdoor',
  'a member API key does not write it'
);

select tests.authenticate_with_api_key(tests.val('key_a_owner'));

update public.organizations
set extra = '{"business_profile": {"shipping_times": "24 a 48 horas en RM"}}'::jsonb
where id = tests.id('org_a');

select tests.clear_authentication();
select is(
  (select extra #>> '{business_profile,shipping_times}' from public.organizations
   where id = tests.id('org_a')),
  '24 a 48 horas en RM',
  'an owner API key writes it — this is the path that skips the screen'
);

select tests.authenticate_with_api_key(tests.val('key_b_member'));

update public.organizations
set extra = '{"business_profile": {"industry": "Casino"}}'::jsonb
where id = tests.id('org_a');

select tests.clear_authentication();
select is(
  (select extra #>> '{business_profile,industry}' from public.organizations
   where id = tests.id('org_a')),
  'Zapatillas y outdoor',
  'the other organization''s API key does not write it'
);

-- Nobody at all fails differently from everybody else here, and that is worth
-- writing down: the policies of `organizations` go through
-- `rls.get_authorized_orgs`, which RAISES 42501 for a caller with neither a
-- JWT nor an api-key header instead of resolving to an empty set. So for anon
-- the table does not read as empty — it does not read.
select tests.authenticate_as_anon();

select throws_ok(
  $$select extra from public.organizations where id = tests.id('org_a')$$,
  '42501',
  'authentication required',
  'anon does not read the organization at all'
);

select throws_ok(
  $$update public.organizations
    set extra = '{"business_profile": {"industry": "Casino"}}'::jsonb
    where id = tests.id('org_a')$$,
  '42501',
  'authentication required',
  'and cannot write the profile'
);

select tests.clear_authentication();
select is(
  (select extra #>> '{business_profile,industry}' from public.organizations
   where id = tests.id('org_a')),
  'Zapatillas y outdoor',
  'which leaves the profile as the owner left it'
);

-- ---------------------------------------------------------------------------
-- What a write does. This is the part the screen has to be built against.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('alice@test.local');

-- Writing one field of the profile merges into the object: the rest survives.
update public.organizations
set extra = '{"business_profile": {"returns_policy": "Cambio por talla en 30 días"}}'::jsonb
where id = tests.id('org_a');

select tests.clear_authentication();
select is(
  (select extra #> '{business_profile,payment_methods}' from public.organizations
   where id = tests.id('org_a')),
  '["Webpay", "Transferencia"]'::jsonb,
  'a nested object merges key by key: the list written earlier survives'
);

-- And the trap: the list does NOT merge. Sending one method is not "add this
-- one", it is "these are all of them now".
select tests.authenticate_as('alice@test.local');

update public.organizations
set extra = '{"business_profile": {"payment_methods": ["Efectivo contra entrega"]}}'::jsonb
where id = tests.id('org_a');

select tests.clear_authentication();
select is(
  (select extra #> '{business_profile,payment_methods}' from public.organizations
   where id = tests.id('org_a')),
  '["Efectivo contra entrega"]'::jsonb,
  'a list is replaced whole: the screen sends every method or deletes the rest'
);

-- The other half of merge-patch semantics, and the only way to clear a field:
-- null removes the key. Worth pinning because the obvious alternative — the
-- empty string — would store a blank that reads as "they answered this".
select tests.authenticate_as('alice@test.local');

update public.organizations
set extra = '{"business_profile": {"industry": null}}'::jsonb
where id = tests.id('org_a');

select tests.clear_authentication();
select is(
  (select extra #> '{business_profile}' ? 'industry' from public.organizations
   where id = tests.id('org_a')),
  false,
  'null deletes the field instead of blanking it'
);

select * from finish();
rollback;
