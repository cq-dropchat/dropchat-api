set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.backfill_message_contents(_rows jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _count integer;
begin
  if jsonb_typeof(_rows) is distinct from 'array' then
    raise exception 'rows must be a JSON array' using errcode = '22023';
  end if;

  if jsonb_array_length(_rows) > 1000 then
    raise exception 'at most 1000 rows per batch' using errcode = '22023';
  end if;

  alter table public.messages disable trigger user;

  update public.messages m
  set content = r.content
  from jsonb_to_recordset(_rows) as r(id uuid, content jsonb)
  where m.id = r.id
    and m.content->>'version' is null
    and m.content <> '{}'::jsonb;

  get diagnostics _count = row_count;

  alter table public.messages enable trigger user;

  return _count;
end;
$function$
;



-- Hand-written (db diff does not model privileges). Supabase's default
-- privileges grant execute by name to anon and authenticated.
revoke execute on function public.backfill_message_contents(jsonb) from public, anon, authenticated;
grant execute on function public.backfill_message_contents(jsonb) to service_role;
