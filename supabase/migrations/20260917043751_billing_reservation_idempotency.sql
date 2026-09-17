
alter table "billing"."ledger" add column "external_id" text;

CREATE INDEX CONCURRENTLY ledger_message_id_idx ON billing.ledger USING btree (message_id);

CREATE UNIQUE INDEX ledger_provider_external_id_key ON billing.ledger USING btree (provider, external_id);

alter table "billing"."ledger" add constraint "ledger_provider_external_id_key" UNIQUE using index "ledger_provider_external_id_key";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION billing.estimate_ai_cost(_pricing jsonb, _quantity numeric, _input_tokens numeric, _max_output_tokens numeric)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select round(
    (
      coalesce(_input_tokens, 0) * coalesce((_pricing ->> 'input')::numeric, 0)
      + coalesce(_max_output_tokens, 0) * coalesce(
          (_pricing ->> 'output')::numeric,
          (_pricing ->> 'input')::numeric,
          0
        )
    ) / nullif(_quantity, 0),
    8
  );
$function$
;

CREATE OR REPLACE FUNCTION billing.update_message_usage()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.content ->> 'internal' is not null then
    return new;
  end if;

  if new.sender_address is null
    or coalesce(auth.role(), '') in ('anon', 'authenticated')
  then
    perform billing.update_usage(new.organization_id, 'messages');
  else
    perform billing.update_usage(new.organization_id, 'messages_inbound');
  end if;

  return new;
end;
$function$
;

-- Dropped right before it is recreated: no insert runs uncounted between.
drop trigger if exists "update_billing_message_usage" on "public"."messages";

CREATE TRIGGER update_billing_message_usage AFTER INSERT ON public.messages FOR EACH ROW WHEN ((new."timestamp" >= (now() - '00:00:10'::interval))) EXECUTE FUNCTION billing.update_message_usage();



-- Hand-written. billing functions are born executable by PUBLIC; the grants
-- file revokes them, but only for functions that exist when it runs (see
-- 06-40_grants.sql), so a migration adding one repeats it.
revoke execute on all functions in schema billing from public;
grant execute on all functions in schema billing to service_role;

-- DML: the inbound counter, where billing is configured (the products table
-- is populated by each deployment, not by migrations).
insert into billing.products (id, name, unit, kind)
select 'messages_inbound', 'Inbound messages', 'count', 'counter'
where exists (select 1 from billing.products where id = 'messages')
on conflict (id) do nothing;
