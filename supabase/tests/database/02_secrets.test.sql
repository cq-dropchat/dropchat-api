-- F02 — credentials of third parties readable by members and API keys, and
-- shipped whole to outgoing webhooks.
--
-- Failure scenario: a member key does `select extra from agents` and reads
-- the LLM api_key, the SQL tool password and the HTTP tool Authorization
-- header; `select extra from organizations_addresses` returns the Meta
-- access_token; a webhook on organizations_addresses receives the token in
-- `data`.
begin;
select plan(22);

-- Every secret the fixture plants; none may surface through an API role.
create temp table planted (value text) on commit drop;
grant select on planted to anon, authenticated;
insert into planted values
  ('sk-test-secret-a'), ('P@ss-test-secret'), ('erp-test-secret'),
  ('mcp-test-secret'), ('EAAG-test-secret-a'), ('AIza-test-secret-a');

-- A jsonb document mentions a secret key or a planted value.
create or replace function pg_temp.leaks(doc jsonb) returns boolean
language sql
as $$
  select doc is not null and (
    doc::text ~* '"(access_token|refresh_token|verify_token|api_key|password|token|authorization)"\s*:\s*"[^"*]'
    or exists (select 1 from planted p where doc::text like '%' || p.value || '%')
  );
$$;

-- ---------------------------------------------------------------------------
-- API key, member role
-- ---------------------------------------------------------------------------

select tests.authenticate_with_api_key(tests.val('key_a_member'));

select is(
  (select bool_or(pg_temp.leaks(extra)) from public.organizations_addresses),
  false,
  'member key: organizations_addresses.extra carries no token'
);

select is(
  (select bool_or(pg_temp.leaks(extra)) from public.agents),
  false,
  'member key: agents.extra carries no LLM key, tool password or auth header'
);

select is(
  (select bool_or(pg_temp.leaks(extra)) from public.organizations),
  false,
  'member key: organizations.extra carries no media_preprocessing.api_key'
);

select is(
  (select bool_or(pg_temp.leaks(to_jsonb(oa))) from public.organizations_addresses oa),
  false,
  'member key: no column of organizations_addresses carries a token'
);

select is(
  (select bool_or(pg_temp.leaks(to_jsonb(a))) from public.agents a),
  false,
  'member key: no column of agents carries a credential'
);

select is(
  (select bool_or(pg_temp.leaks(to_jsonb(o))) from public.organizations o),
  false,
  'member key: no column of organizations carries a credential'
);

-- The public facts next to the secrets stay readable.
select is(
  (select extra->>'verified_name' from public.organizations_addresses
   where service = 'whatsapp'),
  'Alpha Shop',
  'member key: non-secret account facts stay readable'
);

select is(
  (select extra->>'model' from public.agents where user_id is null),
  'openai/gpt-oss-20b',
  'member key: non-secret agent facts stay readable'
);

-- ---------------------------------------------------------------------------
-- Signed-in member and owner: same rule — the API never returns a secret,
-- whoever asks. Owners write them; they do not read them back.
-- ---------------------------------------------------------------------------

select tests.clear_authentication();
select tests.authenticate_as('amber@test.local');

select is(
  (select bool_or(pg_temp.leaks(to_jsonb(a))) from public.agents a),
  false,
  'member user: agents carry no credential'
);

select is(
  (select bool_or(pg_temp.leaks(to_jsonb(oa))) from public.organizations_addresses oa),
  false,
  'member user: organizations_addresses carry no token'
);

select tests.clear_authentication();
select tests.authenticate_as('alice@test.local');

select is(
  (select bool_or(pg_temp.leaks(to_jsonb(a))) from public.agents a),
  false,
  'owner user: agents carry no credential'
);

select is(
  (select bool_or(pg_temp.leaks(to_jsonb(o))) from public.organizations o),
  false,
  'owner user: organizations carry no credential'
);

-- An owner that writes a secret can see that it is set, not what it is.
update public.agents
set extra = '{"api_key": "sk-test-rotated"}'
where id = tests.id('agent_robot_a');

select is(
  (select extra->>'api_key' from public.agents where id = tests.id('agent_robot_a')),
  '********',
  'owner user: a written secret reads back masked'
);

-- Resubmitting the mask (what a form does) must not overwrite the secret
-- with the literal mask, and must not clear it either.
update public.agents
set extra = '{"api_key": "********", "model": "gpt-5-mini"}'
where id = tests.id('agent_robot_a');

select tests.clear_authentication();

select is(
  (select value->>'api_key' from public.secrets
   where scope = 'agent' and ref = tests.id('agent_robot_a')::text),
  'sk-test-rotated',
  'service role: the stored secret is the rotated value, not the mask'
);

select is(
  (select extra->>'model' from public.agents where id = tests.id('agent_robot_a')),
  'gpt-5-mini',
  'service role: the rest of the patch still applied'
);

-- Tool credentials follow the tool, keyed by type:label, and survive a
-- resubmit of the tools array that carries only masks.
select is(
  (select value#>>'{tools,sql:erp-db,password}' from public.secrets
   where scope = 'agent' and ref = tests.id('agent_robot_a')::text),
  'P@ss-test-secret',
  'service role: the SQL tool password lives in secrets'
);

select is(
  (select value#>>'{tools,http:erp-api,headers,Authorization}' from public.secrets
   where scope = 'agent' and ref = tests.id('agent_robot_a')::text),
  'Bearer erp-test-secret',
  'service role: the HTTP tool header lives in secrets'
);

-- Explicit null revokes.
update public.agents
set extra = '{"api_key": null}'
where id = tests.id('agent_robot_a');

select is(
  (select value->>'api_key' from public.secrets
   where scope = 'agent' and ref = tests.id('agent_robot_a')::text),
  null,
  'service role: a null patch revokes the secret'
);

-- The table itself is closed to API roles, whatever their role.
select tests.authenticate_as('alice@test.local');

select throws_ok(
  $$ select count(*) from public.secrets $$,
  '42501',
  null,
  'owner user: public.secrets is not readable through the API'
);

select tests.clear_authentication();
select tests.authenticate_with_api_key(tests.val('key_a_owner'));

select throws_ok(
  $$ select count(*) from public.secrets $$,
  '42501',
  null,
  'owner key: public.secrets is not readable through the API'
);

select tests.clear_authentication();

-- ---------------------------------------------------------------------------
-- notify_webhook: the payload is a projection, never the whole row.
-- ---------------------------------------------------------------------------

insert into public.webhooks (organization_id, table_name, operations, url, token)
values (tests.id('org_a'), 'organizations_addresses',
        array['update']::public.webhook_operation[],
        'https://127.0.0.1:9/hooks/addresses', 'test-webhook-token-a');

update public.organizations_addresses
set status = 'disconnected'
where organization_id = tests.id('org_a') and service = 'whatsapp';

select is(
  (select bool_or(pg_temp.leaks(convert_from(body, 'utf8')::jsonb))
   from net.http_request_queue
   where url = 'https://127.0.0.1:9/hooks/addresses'),
  false,
  'notify_webhook: the organizations_addresses payload carries no token'
);

select is(
  (select count(*) from net.http_request_queue
   where url = 'https://127.0.0.1:9/hooks/addresses'),
  1::bigint,
  'notify_webhook: the update was delivered once'
);

select * from finish();
rollback;
