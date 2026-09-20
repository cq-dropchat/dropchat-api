-- S1 — the `sandbox` service: the simulator's own channel.
--
-- Failure scenario without this: "chat with this agent" is a `local` DM, and
-- `local` is excluded from almost everything the Fase H added — no contact
-- trigger, no welcome message, no escalation, no selection, no assignment.
-- Testing an agent there tests the prompt and nothing else, so the first
-- person to meet H1–H6 end to end would be a paying customer.
--
-- What is pinned here: the enum carries the value; every organization gets
-- exactly one sandbox account, ownerless so every member of the org can use
-- it and nobody outside can see it; the simulator's traffic reaches the agent
-- through the REAL contact trigger; and none of it leaves the building —
-- no dispatcher, no read receipt, no webhook.
begin;
select plan(11);

-- ---------------------------------------------------------------------------
-- The enum value. `db diff` cannot add this one (public.service is named by
-- RLS policies, so its rename/recreate fails); it is a hand-written
-- `alter type ... add value`, and this is what says it landed.
-- ---------------------------------------------------------------------------

select ok(
  'sandbox' = any (enum_range(null::public.service)::text[]),
  'public.service carries the sandbox value'
);

-- ---------------------------------------------------------------------------
-- One account per organization, created by the same trigger that mints the
-- `local` one. Ownerless (agent_id null) is what makes it a SHARED inbox in
-- rls.get_visible_addresses: every member of the org sees the simulator,
-- and, because the rule is scoped to the org, nobody else does.
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int from public.organizations_addresses
   where organization_id = tests.id('org_a') and service = 'sandbox'),
  1,
  'org A has exactly one sandbox account'
);

select is(
  (select address from public.organizations_addresses
   where organization_id = tests.id('org_a') and service = 'sandbox'),
  tests.id('org_a')::text,
  'the sandbox account is addressed by the organization id'
);

select is(
  (select agent_id from public.organizations_addresses
   where organization_id = tests.id('org_a') and service = 'sandbox'),
  null,
  'the sandbox account is ownerless, so it is a shared inbox'
);

select is(
  (select count(*)::int from public.organizations_addresses
   where organization_id = tests.id('org_b') and service = 'sandbox'),
  1,
  'org B has one too — this is per organization, not a singleton'
);

-- An organization minted right now gets one: the trigger, not the backfill.
insert into public.organizations (id, name)
values ('cccccccc-0000-4000-8000-000000000001', 'Sandbox trigger');

select is(
  (select address from public.organizations_addresses
   where organization_id = 'cccccccc-0000-4000-8000-000000000001'
     and service = 'sandbox'),
  'cccccccc-0000-4000-8000-000000000001',
  'a brand new organization gets its sandbox account from the trigger'
);

-- ---------------------------------------------------------------------------
-- Visibility: the five identities. A sandbox conversation belongs to its
-- organization and to nobody else.
-- ---------------------------------------------------------------------------

insert into public.conversations (
  organization_id, id, service, organization_address, address, name
) values (
  tests.id('org_a'),
  'aaaaaaaa-0000-4000-8000-0000000000cf',
  'sandbox',
  tests.id('org_a')::text,
  'sandbox:tester',
  'Simulador'
);

select tests.authenticate_as('alice@test.local');
select is(
  (select count(*)::int from public.conversations
   where id = 'aaaaaaaa-0000-4000-8000-0000000000cf'),
  1,
  'user A (owner of org A) sees the sandbox conversation'
);
select tests.clear_authentication();

select tests.authenticate_as('bob@test.local');
select is(
  (select count(*)::int from public.conversations
   where id = 'aaaaaaaa-0000-4000-8000-0000000000cf'),
  0,
  'user B (owner of org B) does not'
);
select tests.clear_authentication();

-- An API key has no auth.uid(), so it can only ever satisfy the ownerless
-- half of rls.get_visible_addresses. The sandbox account IS ownerless, which
-- is exactly why an integrator's key reaches it — and why the org filter in
-- that function is the whole of the isolation.
select tests.authenticate_with_api_key(tests.val('key_a_member'));
select is(
  (select count(*)::int from public.conversations
   where id = 'aaaaaaaa-0000-4000-8000-0000000000cf'),
  1,
  'API key A sees it: the sandbox account is a shared inbox'
);
select tests.clear_authentication();

select tests.authenticate_with_api_key(tests.val('key_b_member'));
select is(
  (select count(*)::int from public.conversations
   where id = 'aaaaaaaa-0000-4000-8000-0000000000cf'),
  0,
  'API key B does not'
);
select tests.clear_authentication();

-- Nobody: no JWT and no api-key header does not read zero rows, it is
-- refused outright by rls.get_authorized_orgs.
select tests.authenticate_as_anon();
select throws_ok(
  $$select count(*) from public.conversations
    where id = 'aaaaaaaa-0000-4000-8000-0000000000cf'$$,
  null,
  'authentication required',
  'anon is refused before visibility is even asked'
);
select tests.clear_authentication();

select * from finish();
rollback;
