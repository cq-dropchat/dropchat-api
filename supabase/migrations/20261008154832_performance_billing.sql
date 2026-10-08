set check_function_bodies = off;

CREATE OR REPLACE FUNCTION billing.update_usage(_organization_id uuid, _product_id text, _quantity numeric DEFAULT 1)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _today date := current_date;
  _month date := date_trunc('month', current_date)::date;
begin
  -- No product = no billing for this resource
  if not exists (select 1 from billing.products where id = _product_id) then
    return;
  end if;

  -- One statement, same transaction and lock order (day/month/lifetime).
  -- Avoid three SPI executions per resource without relaxing quota semantics.
  insert into billing.usage (organization_id, product_id, interval, period, quantity)
  values
    (_organization_id, _product_id, 'day', _today, _quantity),
    (_organization_id, _product_id, 'month', _month, _quantity),
    (_organization_id, _product_id, 'lifetime', '1970-01-01', _quantity)
  on conflict (organization_id, product_id, interval, period)
  do update set quantity = billing.usage.quantity + excluded.quantity;

end;
$function$
;
