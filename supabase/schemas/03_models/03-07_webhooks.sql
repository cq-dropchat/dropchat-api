create table public.webhooks (
  id uuid default gen_random_uuid() not null,
  organization_id uuid not null,
  table_name public.webhook_table not null,
  operations public.webhook_operation[] not null,
  url character varying not null,
  token character varying,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.webhooks
add constraint webhooks_pkey
primary key (id);

-- F06: https to a public hostname only (is_public_https_url,
-- 04-04_webhook_delivery.sql). NOT VALID: a subscription that predates the
-- rule keeps its row, and the worker refuses to deliver to it instead.
alter table only public.webhooks
add constraint webhooks_url_check
check (public.is_public_https_url(url)) not valid;

alter table only public.webhooks
add constraint webhooks_organization_id_fkey
foreign key (organization_id)
references public.organizations(id)
on delete cascade;

create index webhooks_organization_idx
on public.webhooks
using btree (organization_id);

create trigger set_updated_at
before update
on public.webhooks
for each row
execute function public.moddatetime('updated_at'); 