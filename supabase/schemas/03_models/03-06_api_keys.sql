-- API keys (F14, P8): the secret is never stored, and there is nowhere to
-- store it. A key is minted by create_api_key (04-01_auth_helpers.sql), which
-- returns it exactly once and keeps `key_hash` + `key_prefix`; lookups compare
-- `key_hash = sha256(header)`, which the unique index serves, and only the
-- prefix is ever shown again.
--
-- F14 shipped with a write-only `key` column so a client could still hand the
-- database a plain key (hashed and cleared by a trigger before the row
-- landed), and get_authorized_orgs honoured a row that carried one and no
-- hash until a cutover date. Both are gone: a key the database never sees is
-- a key it cannot leak.
create table public.api_keys (
  id uuid default gen_random_uuid() not null,
  organization_id uuid not null,
  role public.role default 'member'::public.role not null,
  name text not null,
  -- sha256 of the key; what authentication compares against.
  key_hash bytea,
  -- The first characters of the key (`sk_` + 5), for lists and audit logs.
  key_prefix text,
  -- Optional expiry; a key past it authenticates nothing.
  expires_at timestamp with time zone,
  -- Stamped on use, throttled to once a minute and only in read-write
  -- transactions (PostgREST runs GET read-only).
  last_used_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.api_keys
add constraint api_keys_key_hash_key
unique (key_hash);

alter table only public.api_keys
add constraint api_keys_pkey
primary key (id);

alter table only public.api_keys
add constraint api_keys_organization_id_fkey
foreign key (organization_id)
references public.organizations(id)
on delete cascade;

create index api_keys_organization_idx
on public.api_keys
using btree (organization_id);

create trigger set_updated_at
before update
on public.api_keys
for each row
execute function public.moddatetime('updated_at');
