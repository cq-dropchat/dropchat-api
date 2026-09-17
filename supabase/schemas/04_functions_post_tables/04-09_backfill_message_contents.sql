-- §5.2 (audit plan): the v0 → v1 content backfill's writer. The conversion
-- itself runs in Deno (functions/_shared/messages_v0.ts, driven by
-- functions/_scripts/backfill_messages_v1.ts); this function only applies
-- a batch of converted contents.
--
-- Why not a plain UPDATE through PostgREST: set_message merge-patches
-- content (v0 keys would survive next to the v1 ones), set_updated_at would
-- make every old row "just changed" for Realtime and the recovery pages, and
-- notify_webhook would tell every subscriber about each row. Here the user
-- triggers are off for this function's own transaction (ALTER TABLE is
-- transactional: an error rolls it back with the update). That takes an
-- exclusive lock on messages for the length of the batch; batches are
-- capped at 1,000 rows to keep it to milliseconds.
--
-- Only rows still without content.version are written, so a rerun, or a row
-- converted meanwhile, is a no-op. The check constraint refuses anything
-- without the v1 shape.
--
-- Drop it once the backfill has run in production (see the runbook in
-- functions/_scripts/backfill_messages_v1.ts).
create function public.backfill_message_contents(_rows jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
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
$$;

revoke execute on function public.backfill_message_contents(jsonb) from public, anon, authenticated;
grant execute on function public.backfill_message_contents(jsonb) to service_role;
