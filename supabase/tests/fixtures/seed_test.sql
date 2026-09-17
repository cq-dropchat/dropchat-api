-- Deterministic test fixture for pgTAP (supabase/tests/database) and for the
-- Deno integration tests. Loaded by supabase/tests/run.sh with psql AFTER
-- `supabase db reset`; it is idempotent (re-running replaces the same rows).
--
-- NOT a pgTAP test: `npx supabase test db` recurses into every *.sql under
-- supabase/tests, so run `npx supabase test db supabase/tests/database`
-- (or run.sh). The two \echo lines at the bottom keep pg_prove happy if it
-- ever picks this file up by accident.
--
-- Every secret here is obviously fake. Never paste real tokens into fixtures.
--
-- Shape:
--   org A "Alpha"  owner alice, member amber, AI agent "Robot A" (with tool
--                  credentials in extra), API keys (member + owner), a
--                  whatsapp account with an access_token, a local account
--                  (minted by trigger), two contacts, two conversations.
--   org B "Bravo"  owner bob, API key (member), a whatsapp account, one
--                  contact, one conversation.
--   storage        one object per org under organizations/<org>/attachments.

-- ---------------------------------------------------------------------------
-- Helpers: act as a given actor inside a test transaction.
-- ---------------------------------------------------------------------------

create schema if not exists tests;

create table if not exists tests.fixtures (
  name text primary key,
  value text not null
);

-- tests.id('org_a') → uuid, tests.val('key_a_member') → text
create or replace function tests.val(p_name text) returns text
language sql stable
as $$
  select value from tests.fixtures where name = p_name;
$$;

create or replace function tests.id(p_name text) returns uuid
language sql stable
as $$
  select value::uuid from tests.fixtures where name = p_name;
$$;

-- A signed-in user. Sets the same GUCs PostgREST/GoTrue would, then switches
-- to the `authenticated` role for the rest of the transaction.
create or replace function tests.authenticate_as(p_email text) returns void
language plpgsql
as $$
declare
  _id uuid;
begin
  select id into _id from auth.users where email = p_email;

  if _id is null then
    raise exception 'tests.authenticate_as: no user with email %', p_email;
  end if;

  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', _id, 'role', 'authenticated', 'email', p_email)::text,
    true
  );
  perform set_config('request.jwt.claim.sub', _id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.headers', '{}', true);
  perform set_config('role', 'authenticated', true);
end;
$$;

-- An API key caller: PostgREST runs these as `anon` with the header.
create or replace function tests.authenticate_with_api_key(p_key text) returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config(
    'request.headers',
    json_build_object('api-key', p_key)::text,
    true
  );
  perform set_config('role', 'anon', true);
end;
$$;

-- Nobody: no JWT, no api-key header.
create or replace function tests.authenticate_as_anon() returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('request.headers', '{}', true);
  perform set_config('role', 'anon', true);
end;
$$;

-- Back to the session user (postgres), e.g. to seed more rows mid-test.
create or replace function tests.clear_authentication() returns void
language plpgsql
as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  perform set_config('request.headers', '', true);
end;
$$;

grant usage on schema tests to anon, authenticated, service_role;
grant select on tests.fixtures to anon, authenticated, service_role;
grant execute on all functions in schema tests to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

insert into tests.fixtures (name, value) values
  ('org_a',            'aaaaaaaa-0000-4000-8000-000000000001'),
  ('org_b',            'bbbbbbbb-0000-4000-8000-000000000001'),
  ('user_alice',       'aaaaaaaa-0000-4000-8000-0000000000a1'), -- owner A
  ('user_amber',       'aaaaaaaa-0000-4000-8000-0000000000a2'), -- member A
  ('user_bob',         'bbbbbbbb-0000-4000-8000-0000000000b1'), -- owner B
  ('agent_alice',      'aaaaaaaa-0000-4000-8000-00000000a0a1'),
  ('agent_amber',      'aaaaaaaa-0000-4000-8000-00000000a0a2'),
  ('agent_bob',        'bbbbbbbb-0000-4000-8000-00000000b0b1'),
  ('agent_robot_a',    'aaaaaaaa-0000-4000-8000-00000000a0a9'), -- AI, org A
  ('key_a_member',     'test-key-a-member-000000000000000000'),
  ('key_a_owner',      'test-key-a-owner-0000000000000000000'),
  ('key_b_member',     'test-key-b-member-000000000000000000'),
  ('wa_a',             '100000000000001'), -- whatsapp phone_number_id, org A
  ('wa_b',             '200000000000001'), -- whatsapp phone_number_id, org B
  ('contact_a1',       '5491100000101'),
  ('contact_a2',       '5491100000102'),
  ('contact_b1',       '5492200000201'),
  ('conv_a1',          'aaaaaaaa-0000-4000-8000-0000000000c1'),
  ('conv_a2',          'aaaaaaaa-0000-4000-8000-0000000000c2'),
  ('conv_b1',          'bbbbbbbb-0000-4000-8000-0000000000c1'),
  ('msg_a1_in',        'aaaaaaaa-0000-4000-8000-00000000d0a1'),
  ('msg_a1_out',       'aaaaaaaa-0000-4000-8000-00000000d0a2'),
  ('msg_a1_file',      'aaaaaaaa-0000-4000-8000-00000000d0a3'),
  ('msg_a2_in',        'aaaaaaaa-0000-4000-8000-00000000d0a4'),
  ('msg_b1_in',        'bbbbbbbb-0000-4000-8000-00000000d0b1'),
  ('msg_b1_file',      'bbbbbbbb-0000-4000-8000-00000000d0b2'),
  ('media_a',          'organizations/aaaaaaaa-0000-4000-8000-000000000001/attachments/file-a-1'),
  ('media_b',          'organizations/bbbbbbbb-0000-4000-8000-000000000001/attachments/file-b-1'),
  ('webhook_a',        'aaaaaaaa-0000-4000-8000-00000000e0a1')
on conflict (name) do update set value = excluded.value;

-- ---------------------------------------------------------------------------
-- Idempotency: wipe what this file owns. Orgs cascade to everything under
-- them; users are deleted after their owner rows are gone.
-- ---------------------------------------------------------------------------

-- storage.protect_delete refuses direct deletes unless this GUC is set.
set storage.allow_delete_query = 'true';
delete from storage.objects
where bucket_id = 'media'
  and name in (tests.val('media_a'), tests.val('media_b'));
reset storage.allow_delete_query;

delete from public.organizations
where id in (tests.id('org_a'), tests.id('org_b'));

delete from auth.users
where id in (tests.id('user_alice'), tests.id('user_amber'), tests.id('user_bob'));

-- ---------------------------------------------------------------------------
-- Organizations (billing subscription + local address minted by triggers)
-- ---------------------------------------------------------------------------

insert into public.organizations (id, name, extra) values
  (tests.id('org_a'), 'Alpha',
   '{"media_preprocessing": {"mode": "active", "api_key": "AIza-test-secret-a"}}'),
  (tests.id('org_b'), 'Bravo',
   '{"media_preprocessing": {"mode": "inactive"}}');

-- ---------------------------------------------------------------------------
-- Users (password = local part of the email)
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, email_confirmed_at,
  created_at, updated_at, confirmation_token, recovery_token,
  email_change_token_new, email_change
) values
  ('00000000-0000-0000-0000-000000000000', tests.id('user_alice'), 'authenticated', 'authenticated',
   'alice@test.local', crypt('alice', gen_salt('bf')),
   '{"provider":"email","providers":["email"]}', '{"name": "Alice"}',
   now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', tests.id('user_amber'), 'authenticated', 'authenticated',
   'amber@test.local', crypt('amber', gen_salt('bf')),
   '{"provider":"email","providers":["email"]}', '{"name": "Amber"}',
   now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', tests.id('user_bob'), 'authenticated', 'authenticated',
   'bob@test.local', crypt('bob', gen_salt('bf')),
   '{"provider":"email","providers":["email"]}', '{"name": "Bob"}',
   now(), now(), now(), '', '', '', '');

insert into auth.identities (
  id, user_id, provider_id, identity_data, provider,
  last_sign_in_at, created_at, updated_at
)
select u.id, u.id, u.id::text,
  json_build_object('sub', u.id, 'email', u.email)::jsonb, 'email',
  now(), now(), now()
from auth.users u
where u.id in (tests.id('user_alice'), tests.id('user_amber'), tests.id('user_bob'));

-- ---------------------------------------------------------------------------
-- Agents (memberships + one AI agent carrying credentials in extra)
-- ---------------------------------------------------------------------------

insert into public.agents (id, organization_id, user_id, name, role) values
  (tests.id('agent_alice'), tests.id('org_a'), tests.id('user_alice'), 'Alice', 'owner'),
  (tests.id('agent_amber'), tests.id('org_a'), tests.id('user_amber'), 'Amber', 'member'),
  (tests.id('agent_bob'),   tests.id('org_b'), tests.id('user_bob'),   'Bob',   'owner');

insert into public.agents (id, organization_id, user_id, name, extra) values
  (tests.id('agent_robot_a'), tests.id('org_a'), null, 'Robot A', $json$
    {
      "mode": "active",
      "protocol": "chat_completions",
      "api_url": "https://api.groq.com/openai/v1",
      "api_key": "sk-test-secret-a",
      "model": "openai/gpt-oss-20b",
      "instructions": "You are a test robot.",
      "response_delay_seconds": 0,
      "tools": [
        {"provider": "local", "type": "sql", "label": "erp-db",
         "config": {"driver": "postgres", "host": "db.example.test",
                    "port": 5432, "user": "erp", "password": "P@ss-test-secret",
                    "database": "erp"}},
        {"provider": "local", "type": "http", "label": "erp-api",
         "config": {"url": "https://erp.example.test/*", "methods": ["GET"],
                    "headers": {"Authorization": "Bearer erp-test-secret"}}},
        {"provider": "local", "type": "mcp", "label": "crm",
         "config": {"url": "https://mcp.example.test/sse",
                    "headers": {"Authorization": "Bearer mcp-test-secret"}}}
      ]
    }
  $json$::jsonb);

-- ---------------------------------------------------------------------------
-- API keys
-- ---------------------------------------------------------------------------

insert into public.api_keys (organization_id, key, role, name) values
  (tests.id('org_a'), tests.val('key_a_member'), 'member', 'A member key'),
  (tests.id('org_a'), tests.val('key_a_owner'),  'owner',  'A owner key'),
  (tests.id('org_b'), tests.val('key_b_member'), 'member', 'B member key');

-- ---------------------------------------------------------------------------
-- Accounts (the local address per org already exists via trigger)
-- ---------------------------------------------------------------------------

insert into public.organizations_addresses (organization_id, service, address, extra, status) values
  (tests.id('org_a'), 'whatsapp', tests.val('wa_a'),
   '{"waba_id": "300000000000001", "phone_number": "5491100000001",
     "verified_name": "Alpha Shop", "flow_type": "existing_phone_number",
     "access_token": "EAAG-test-secret-a"}', 'connected'),
  (tests.id('org_b'), 'whatsapp', tests.val('wa_b'),
   '{"waba_id": "300000000000002", "phone_number": "5492200000002",
     "verified_name": "Bravo Store", "flow_type": "existing_phone_number",
     "access_token": "EAAG-test-secret-b"}', 'connected');

-- ---------------------------------------------------------------------------
-- Contacts
-- ---------------------------------------------------------------------------

insert into public.contacts_addresses (organization_id, organization_address, service, address, extra) values
  (tests.id('org_a'), tests.val('wa_a'), 'whatsapp', tests.val('contact_a1'), '{"name": "Carla"}'),
  (tests.id('org_a'), tests.val('wa_a'), 'whatsapp', tests.val('contact_a2'), '{"name": "Dario"}'),
  (tests.id('org_b'), tests.val('wa_b'), 'whatsapp', tests.val('contact_b1'), '{"name": "Elena"}');

-- ---------------------------------------------------------------------------
-- Conversations
-- ---------------------------------------------------------------------------

insert into public.conversations (id, organization_id, organization_address, address, service, name) values
  (tests.id('conv_a1'), tests.id('org_a'), tests.val('wa_a'), tests.val('contact_a1'), 'whatsapp', 'Carla'),
  (tests.id('conv_a2'), tests.id('org_a'), tests.val('wa_a'), tests.val('contact_a2'), 'whatsapp', 'Dario'),
  (tests.id('conv_b1'), tests.id('org_b'), tests.val('wa_b'), tests.val('contact_b1'), 'whatsapp', 'Elena');

-- ---------------------------------------------------------------------------
-- Storage objects (one per org) — inserted before the messages that
-- reference them so is_media_visible has something to resolve.
-- ---------------------------------------------------------------------------

insert into storage.objects (bucket_id, name, metadata) values
  ('media', tests.val('media_a'), '{"size": 1024, "mimetype": "image/jpeg"}'),
  ('media', tests.val('media_b'), '{"size": 2048, "mimetype": "image/png"}');

-- ---------------------------------------------------------------------------
-- Messages (v1 content). All rows carry a terminal status and an old
-- timestamp on purpose: no `pending` means no dispatcher/agent trigger fires
-- and nothing is enqueued in pg_net while the fixture loads. Tests that need
-- armed rows insert them inside their own (rolled back) transaction.
-- ---------------------------------------------------------------------------

insert into public.messages (
  id, conversation_id, organization_id, organization_address,
  conversation_address, sender_address, service, agent_id, external_id,
  content, status, timestamp
) values
  (tests.id('msg_a1_in'), tests.id('conv_a1'), tests.id('org_a'), tests.val('wa_a'),
   tests.val('contact_a1'), tests.val('contact_a1'), 'whatsapp', null, 'wamid.A1.IN',
   '{"version": "1", "type": "text", "kind": "text", "text": "hola *alpha*"}',
   '{"delivered": "2026-09-01T10:00:00Z", "read": "2026-09-01T10:00:05Z"}',
   '2026-09-01T10:00:00Z'),
  (tests.id('msg_a1_out'), tests.id('conv_a1'), tests.id('org_a'), tests.val('wa_a'),
   tests.val('contact_a1'), null, 'whatsapp', tests.id('agent_alice'), 'wamid.A1.OUT',
   '{"version": "1", "type": "text", "kind": "text", "text": "hola Carla"}',
   '{"accepted": "2026-09-01T10:01:00Z", "sent": "2026-09-01T10:01:01Z", "delivered": "2026-09-01T10:01:02Z"}',
   '2026-09-01T10:01:00Z'),
  (tests.id('msg_a1_file'), tests.id('conv_a1'), tests.id('org_a'), tests.val('wa_a'),
   tests.val('contact_a1'), tests.val('contact_a1'), 'whatsapp', null, 'wamid.A1.FILE',
   json_build_object(
     'version', '1', 'type', 'file', 'kind', 'image',
     'file', json_build_object('uri', 'internal://media/' || tests.val('media_a'),
                               'mime_type', 'image/jpeg', 'size', 1024)
   )::jsonb,
   '{"delivered": "2026-09-01T10:02:00Z"}',
   '2026-09-01T10:02:00Z'),
  (tests.id('msg_a2_in'), tests.id('conv_a2'), tests.id('org_a'), tests.val('wa_a'),
   tests.val('contact_a2'), tests.val('contact_a2'), 'whatsapp', null, 'wamid.A2.IN',
   '{"version": "1", "type": "text", "kind": "text", "text": "buenas"}',
   '{"delivered": "2026-09-02T09:00:00Z"}',
   '2026-09-02T09:00:00Z'),
  (tests.id('msg_b1_in'), tests.id('conv_b1'), tests.id('org_b'), tests.val('wa_b'),
   tests.val('contact_b1'), tests.val('contact_b1'), 'whatsapp', null, 'wamid.B1.IN',
   '{"version": "1", "type": "text", "kind": "text", "text": "hola bravo"}',
   '{"delivered": "2026-09-01T11:00:00Z"}',
   '2026-09-01T11:00:00Z'),
  (tests.id('msg_b1_file'), tests.id('conv_b1'), tests.id('org_b'), tests.val('wa_b'),
   tests.val('contact_b1'), tests.val('contact_b1'), 'whatsapp', null, 'wamid.B1.FILE',
   json_build_object(
     'version', '1', 'type', 'file', 'kind', 'image',
     'file', json_build_object('uri', 'internal://media/' || tests.val('media_b'),
                               'mime_type', 'image/png', 'size', 2048)
   )::jsonb,
   '{"delivered": "2026-09-01T11:01:00Z"}',
   '2026-09-01T11:01:00Z');

-- ---------------------------------------------------------------------------
-- Webhooks (org A). Points at a closed local port so pg_net never delivers.
-- ---------------------------------------------------------------------------

insert into public.webhooks (id, organization_id, table_name, operations, url, token) values
  (tests.id('webhook_a'), tests.id('org_a'), 'messages',
   array['insert', 'update']::public.webhook_operation[],
   'https://127.0.0.1:9/hooks/messages', 'test-webhook-token-a');

\echo 1..1
\echo ok 1 - test fixture loaded
