-- API keys (F14): the secret is never stored. `key` is a write-only slot —
-- a client may still insert the plain key there and hash_api_key
-- (02-03_trigger_functions.sql) turns it into key_hash + key_prefix and
-- clears it before the row lands — and it is dropped at the cutover date
-- (see CHANGELOG). Lookups compare `key_hash = sha256(header)`, which the
-- unique index serves. Only the prefix is ever shown again; the full key is
-- returned exactly once, by create_api_key (04-01_auth_helpers.sql).
create table public.api_keys (
  id uuid default gen_random_uuid() not null,
  organization_id uuid not null,
  role public.role default 'member'::public.role not null,
  name text not null,
  -- Write-only. Null on every stored row.
  key text,
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

-- `a_` so it runs before set_updated_at; it must run before the row is
-- stored, which is what BEFORE gives.
create trigger a_hash_api_key
before insert or update of key
on public.api_keys
for each row
when (new.key is not null)
execute function public.hash_api_key();

create trigger set_updated_at
before update
on public.api_keys
for each row
execute function public.moddatetime('updated_at');
