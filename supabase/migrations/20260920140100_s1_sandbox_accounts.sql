-- S1 — one sandbox account per organization.
--
-- Separate file from the enum value on purpose: the backfill below writes
-- 'sandbox' rows, which the transaction that adds the value may not do.

create or replace function public.after_insert_on_organizations() returns trigger
language plpgsql
security definer -- bypass RLS to create the first owner
set search_path to ''
as $$
declare
  user_id uuid := auth.uid();
  user_name text;
begin
  -- Two accounts, both addressed by the organization's own id because
  -- neither has an external peer to be addressed by:
  --
  --   local     team chat, the members talking to each other.
  --   sandbox   S1's simulator — the account a member writes to as if they
  --             were a customer. Ownerless on purpose: agent_id null is what
  --             rls.get_visible_addresses reads as a SHARED inbox, so every
  --             member of the organization can test an agent, and the org
  --             filter in that same function is what keeps it theirs.
  insert into public.organizations_addresses (organization_id, service, address)
    values
      (new.id, 'local', new.id::text),
      (new.id, 'sandbox', new.id::text);

  if user_id is not null then
    select coalesce(raw_user_meta_data->>'full_name', email, '?') into user_name
    from auth.users
    where id = user_id;

    insert into public.agents (organization_id, user_id, name, role)
    values (new.id, user_id, user_name, 'owner');
  end if;

  return new;
end;
$$;

-- Backfill: every organization that existed before this migration. There are
-- no production tenants yet, so this is a handful of development rows — but
-- it is what makes "the simulator is always there" true rather than "true
-- for organizations created from now on".
insert into public.organizations_addresses (organization_id, service, address)
select o.id, 'sandbox', o.id::text
from public.organizations o
on conflict (organization_id, service, address) do nothing;
