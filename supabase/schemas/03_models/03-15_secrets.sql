-- Third-party credentials, out of reach of every API role.
--
-- A Meta system-user token, an Instagram or Slack user token, an LLM
-- api_key, a SQL tool password, an HTTP tool Authorization header: all of
-- them used to live inside the `extra` jsonb of organizations_addresses,
-- agents and organizations — tables every member (and every member API key)
-- can read whole. This table is where they live now. No policy admits an API
-- role, and the grants below revoke even the default table privileges, so
-- PostgREST cannot serve a row from here to anyone but the service role.
--
-- Writers do not talk to this table. They keep writing the credential into
-- `extra` — the management functions, the token-refresh crons, the UI's
-- agent form — and the z_extract_secrets trigger on each source table
-- (02-03_trigger_functions.sql) moves it here BEFORE the row is stored,
-- leaving the mask '********' in its place. The mask is what the API returns;
-- writing the mask back (which a form does on every save) is a no-op, and
-- writing null revokes. Readers that need the real value hold the service
-- role and merge this table back in (functions/_shared/secrets.ts).
--
-- One row per secret-bearing row of the source table:
--   scope 'organization'  ref = ''                        organizations.extra
--   scope 'address'       ref = service || ':' || address organizations_addresses.extra
--   scope 'agent'         ref = agent id                  agents.extra
--
-- `value` mirrors the shape the source `extra` had, so merging back is a
-- deep merge with no per-key knowledge:
--   {"access_token": "…"}
--   {"media_preprocessing": {"api_key": "…"}}
--   {"api_key": "…", "tools": {"sql:erp-db": {"password": "…"},
--                              "http:erp-api": {"headers": {…}}}}
-- Tool secrets are keyed by `type:label`, not by array index: a form
-- resubmits the whole tools array (arrays replace under merge-patch), and a
-- reorder must not hand one tool another's password.
create table public.secrets (
  organization_id uuid not null,
  scope text not null,
  ref text not null default '',
  -- Cascade anchors. Set for scope 'address' and 'agent' respectively, so
  -- disconnecting an account or removing an agent takes its credentials
  -- along; null otherwise. The references are DEFERRED: the trigger writes
  -- this row from a BEFORE INSERT on the parent, when the parent does not
  -- exist yet; an immediate check would refuse every first credential.
  service public.service,
  address text,
  agent_id uuid,
  value jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.secrets
add constraint secrets_pkey
primary key (organization_id, scope, ref);

alter table only public.secrets
add constraint secrets_scope_check
check (scope in ('organization', 'address', 'agent'));

alter table only public.secrets
add constraint secrets_organization_id_fkey
foreign key (organization_id)
references public.organizations(id)
on delete cascade
deferrable initially deferred;

alter table only public.secrets
add constraint secrets_organization_address_fkey
foreign key (organization_id, service, address)
references public.organizations_addresses(organization_id, service, address)
on delete cascade
deferrable initially deferred;

alter table only public.secrets
add constraint secrets_agent_id_fkey
foreign key (organization_id, agent_id)
references public.agents(organization_id, id)
on delete cascade
deferrable initially deferred;

create index secrets_agent_id_idx
on public.secrets
using btree (agent_id);

create trigger set_updated_at
before update
on public.secrets
for each row
execute function public.moddatetime('updated_at');

-- The extraction triggers on the three source tables. `z_` so they run after
-- set_extra (merge_update) and see the merged document, exactly what the row
-- is about to store.
create trigger z_extract_secrets
before insert or update
on public.organizations
for each row
when (new.extra is not null)
execute function public.extract_secrets();

create trigger z_extract_secrets
before insert or update
on public.organizations_addresses
for each row
when (new.extra is not null)
execute function public.extract_secrets();

create trigger z_extract_secrets
before insert or update
on public.agents
for each row
when (new.extra is not null)
execute function public.extract_secrets();
