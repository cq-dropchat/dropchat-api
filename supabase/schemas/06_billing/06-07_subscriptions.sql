create table billing.subscriptions (
  organization_id uuid not null,
  tier_id text not null,
  plan_id text,
  account_id uuid,
  current_period_start timestamp with time zone,
  current_period_end timestamp with time zone,
  -- F17: when the subscription stops renewing. A cancellation at the end of
  -- the period sets it to current_period_end; renew_subscriptions skips a
  -- subscription canceled on or before the end of its current period.
  canceled_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only billing.subscriptions
add constraint subscriptions_pkey
primary key (organization_id);

alter table only billing.subscriptions
add constraint subscriptions_organization_id_fkey
foreign key (organization_id)
references public.organizations(id)
on delete cascade;

alter table only billing.subscriptions
add constraint subscriptions_tier_id_fkey
foreign key (tier_id)
references billing.tiers(id);

alter table only billing.subscriptions
add constraint subscriptions_plan_id_fkey
foreign key (plan_id)
references billing.plans(id);

alter table only billing.subscriptions
add constraint subscriptions_account_id_fkey
foreign key (account_id)
references billing.accounts(id);

create trigger set_updated_at
before update
on billing.subscriptions
for each row
execute function public.moddatetime('updated_at');

-- F17: renew_subscriptions starts from the due subscriptions
-- (current_period_end <= now()) instead of probing every organization.
create index subscriptions_current_period_end_idx
on billing.subscriptions
using btree (current_period_end);
