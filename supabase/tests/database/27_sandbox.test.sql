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
select plan(30);

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

-- ---------------------------------------------------------------------------
-- IN: the simulator reaches the agent through the REAL contact trigger.
--
-- handle_incoming_message_to_agent arms on `sender_address is not null and
-- service not in ('local','slack')`, so a sandbox row written as if by a
-- customer arms it with nothing added to the WHEN clause. That is the whole
-- reason B1 chose a service over a flag, and this is what says it is true.
-- ---------------------------------------------------------------------------

-- The database's outbox is shared and a background worker drains it, so
-- everything asserted about pg_net below is scoped to what came after this
-- high-water mark (the pattern of 07_webhook_deliveries).
create temp table marks on commit drop as
select (select coalesce(max(id), 0) from net.http_request_queue) as queue_id;

insert into public.messages (
  id, organization_id, service, organization_address, conversation_address,
  sender_address, content
) values (
  'aaaaaaaa-0000-4000-8000-00000000f0f1', tests.id('org_a'), 'sandbox',
  tests.id('org_a')::text, 'sandbox:tester', 'sandbox:tester',
  '{"version": "1", "type": "text", "kind": "text", "text": "hola"}'
);

select is(
  (select count(*)::int from public.edge_calls
   where record_id = 'aaaaaaaa-0000-4000-8000-00000000f0f1'
     and function = 'agent-client'),
  1,
  'an incoming sandbox message queues agent-client, like any real channel'
);

-- ---------------------------------------------------------------------------
-- OUT: and nothing gets out.
--
-- Three separate paths, all of which a new service falls into by default:
-- the outgoing dispatcher (no service filter at all), the read-receipt
-- dispatcher (excludes only local and slack), and the webhook notifier
-- (does not look at service). Left alone, the simulator would POST to a
-- /sandbox-dispatcher that does not exist and would bill an integrator's
-- webhook endpoint for a drill.
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int from public.webhook_deliveries d
   join public.messages m on m.id = (d.payload -> 'data' ->> 'id')::uuid
   where m.service = 'sandbox'),
  0,
  'an incoming sandbox message fires no webhook, though org A has one on messages'
);

-- The agent's reply: authored by the account (sender null), armed, not
-- record-only — exactly what handle_outgoing_message_to_dispatcher arms on.
insert into public.messages (
  id, organization_id, service, organization_address, conversation_address,
  agent_id, content
) values (
  'aaaaaaaa-0000-4000-8000-00000000f0f2', tests.id('org_a'), 'sandbox',
  tests.id('org_a')::text, 'sandbox:tester', tests.id('agent_robot_a'),
  '{"version": "1", "type": "text", "kind": "text", "text": "hola!"}'
);

select is(
  (select count(*)::int from net.http_request_queue
   where id > (select queue_id from marks)
     and url like '%-dispatcher'),
  0,
  'an outgoing sandbox message posts to no dispatcher'
);

-- Marked delivered in the same breath, the way `local` is: there is no
-- carrier to report back, so a row left pending would sit "sending" for ever
-- and the sweep would keep picking it up.
select is(
  (select (status ? 'delivered') from public.messages
   where id = 'aaaaaaaa-0000-4000-8000-00000000f0f2'),
  true,
  'it is marked delivered instead, since the simulator IS the carrier'
);

select is(
  (select count(*)::int from public.webhook_deliveries d
   where (d.payload -> 'data' ->> 'id') = 'aaaaaaaa-0000-4000-8000-00000000f0f2'),
  0,
  'and the outgoing one fires no webhook either'
);

-- A read receipt: an UPDATE, a different trigger, the same rule.
update public.messages
set status = '{"read": "2026-09-20T10:00:00Z"}'
where id = 'aaaaaaaa-0000-4000-8000-00000000f0f1';

select is(
  (select count(*)::int from net.http_request_queue
   where id > (select queue_id from marks)
     and url like '%-dispatcher'),
  0,
  'reading a sandbox message posts no receipt to any dispatcher'
);

select is(
  (select count(*)::int from public.webhook_deliveries d
   where (d.payload -> 'data' ->> 'id') = 'aaaaaaaa-0000-4000-8000-00000000f0f1'
     and d.event = 'messages.update'),
  0,
  'nor does the update reach the webhook'
);

-- The control. Without it the six assertions above would also pass on a
-- database where webhooks were simply broken.
insert into public.messages (
  id, organization_id, service, organization_address, conversation_address,
  sender_address, external_id, content
) values (
  'aaaaaaaa-0000-4000-8000-00000000f0f3', tests.id('org_a'), 'whatsapp',
  tests.val('wa_a'), tests.val('contact_a1'), tests.val('contact_a1'),
  'wamid.SANDBOX.CONTROL.1',
  '{"version": "1", "type": "text", "kind": "text", "text": "real one"}'
);

select is(
  (select count(*)::int from public.webhook_deliveries d
   where (d.payload -> 'data' ->> 'id') = 'aaaaaaaa-0000-4000-8000-00000000f0f3'),
  1,
  'the same insert on whatsapp DOES fire the webhook: sandbox is the exception'
);

-- ---------------------------------------------------------------------------
-- "Reiniciar": a member throws away THEIR OWN drills.
--
-- Members already held DELETE on their `local` conversations (05-03) and on
-- nothing else, because `local` is the organization's own room: no contact
-- on the other side would notice it vanish. A drill is the same kind of
-- thing, so the policy grew `sandbox` — but not org-wide. A drill belongs to
-- the member who opened it, and its ADDRESS is that member's agent id, so
-- the rule is a relation SQL can check rather than a string convention
-- shared with the UI (rls.get_own_sandbox_addresses).
--
-- Admins keep the org-wide reach. Without it, a drill opened by somebody who
-- has since left the organization would be undeletable by anyone: their
-- agent row is marked deleted, so it is nobody's own any more.
--
-- API keys are nobody in particular — no auth.uid(), so no agent, so no
-- drill of their own. They cannot delete drills at all, which is the same
-- answer rls.get_own_agents already gives everywhere else.
-- ---------------------------------------------------------------------------

-- Amber's drill (a plain member) and Alice's (the owner).
insert into public.conversations (
  organization_id, id, service, organization_address, address
) values
  (
    tests.id('org_a'), 'aaaaaaaa-0000-4000-8000-0000000000cd', 'sandbox',
    tests.id('org_a')::text, tests.id('agent_amber')::text
  ),
  (
    tests.id('org_a'), 'aaaaaaaa-0000-4000-8000-0000000000ce', 'sandbox',
    tests.id('org_a')::text, tests.id('agent_alice')::text
  );

insert into public.messages (
  id, organization_id, conversation_id, sender_address, content
) values (
  'aaaaaaaa-0000-4000-8000-00000000f0fd', tests.id('org_a'),
  'aaaaaaaa-0000-4000-8000-0000000000cd', tests.id('agent_amber')::text,
  '{"version": "1", "type": "text", "kind": "text", "text": "se borra"}'
);

-- Another organization's member: nothing, as before.
select tests.authenticate_as('bob@test.local');
select lives_ok(
  $$delete from public.conversations
    where id = 'aaaaaaaa-0000-4000-8000-0000000000cd'$$,
  'user B deleting org A''s drill raises nothing — RLS filters, it does not throw'
);
select tests.clear_authentication();

select is(
  (select count(*)::int from public.conversations
   where id = 'aaaaaaaa-0000-4000-8000-0000000000cd'),
  1,
  '...and deletes nothing: the row is still there'
);

select tests.authenticate_with_api_key(tests.val('key_b_member'));
delete from public.conversations
where id = 'aaaaaaaa-0000-4000-8000-0000000000cd';
select tests.clear_authentication();

select is(
  (select count(*)::int from public.conversations
   where id = 'aaaaaaaa-0000-4000-8000-0000000000cd'),
  1,
  'nor does API key B'
);

-- An API key OF THIS ORGANIZATION: also nothing. It has no agent, so no
-- drill is its own, and it is not a person the admin arm speaks for.
select tests.authenticate_with_api_key(tests.val('key_a_member'));
delete from public.conversations
where id = 'aaaaaaaa-0000-4000-8000-0000000000cd';
select tests.clear_authentication();

select is(
  (select count(*)::int from public.conversations
   where id = 'aaaaaaaa-0000-4000-8000-0000000000cd'),
  1,
  'nor does API key A, of the very organization the drill belongs to'
);

select tests.authenticate_as_anon();
select throws_ok(
  $$delete from public.conversations
    where id = 'aaaaaaaa-0000-4000-8000-0000000000cd'$$,
  null,
  'authentication required',
  'anon is refused outright'
);
select tests.clear_authentication();

-- THE CASE THIS EXISTS FOR: a plain member cannot reset a colleague's drill.
select tests.authenticate_as('amber@test.local');
delete from public.conversations
where id = 'aaaaaaaa-0000-4000-8000-0000000000ce';
select tests.clear_authentication();

select is(
  (select count(*)::int from public.conversations
   where id = 'aaaaaaaa-0000-4000-8000-0000000000ce'),
  1,
  'a member does not reset a colleague''s drill'
);

-- ...but resets their own. This is the button.
select tests.authenticate_as('amber@test.local');
delete from public.conversations
where id = 'aaaaaaaa-0000-4000-8000-0000000000cd';
select tests.clear_authentication();

select is(
  (select count(*)::int from public.conversations
   where id = 'aaaaaaaa-0000-4000-8000-0000000000cd'),
  0,
  'a member resets their own drill'
);

select is(
  (select count(*)::int from public.messages
   where id = 'aaaaaaaa-0000-4000-8000-00000000f0fd'),
  0,
  'and its messages go with it, by cascade'
);

-- An admin sweeps, which is what keeps a departed member's drills deletable.
select tests.authenticate_as('alice@test.local');
delete from public.conversations
where id = 'aaaaaaaa-0000-4000-8000-0000000000ce';
select tests.clear_authentication();

select is(
  (select count(*)::int from public.conversations
   where id = 'aaaaaaaa-0000-4000-8000-0000000000ce'),
  0,
  'an owner resets anybody''s drill in the organization'
);

-- The control: this widened DELETE for drills, not for conversations. Amber
-- can see the whatsapp conversation and still cannot delete it.
select tests.authenticate_as('amber@test.local');
delete from public.conversations where id = tests.id('conv_a1');
select tests.clear_authentication();

select is(
  (select count(*)::int from public.conversations where id = tests.id('conv_a1')),
  1,
  'a real whatsapp conversation is still undeletable by a member'
);

-- And `local` did not lose anything on the way.
select tests.authenticate_as('amber@test.local');
select lives_ok(
  $$delete from public.conversations
    where organization_id = (select tests.id('org_a'))
      and service = 'local'
      and false$$,
  'the local arm of the policy is still there'
);
select tests.clear_authentication();

select * from finish();
rollback;
