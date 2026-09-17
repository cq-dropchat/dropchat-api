-- §5.2 (P3) — the content schema now holds for the whole table.
--
-- `messages_content_schema` was added NOT VALID: the deployed database held
-- legacy messages whose content predates the v1 schema (no version, no kind),
-- so it could only speak for rows written after it. The backfill converted
-- them (functions/_scripts/backfill_messages_v1.ts) and reported nothing left
-- to write, so the constraint is validated here and the writer it used is
-- dropped.
--
-- Hand-written: `db diff` proposed dropping and re-adding an identical
-- constraint before validating it, which takes ACCESS EXCLUSIVE twice and
-- leaves the table unconstrained in between. VALIDATE alone reads the table
-- once under SHARE UPDATE EXCLUSIVE, so writes go on.
alter table public.messages validate constraint messages_content_schema;

drop function if exists public.backfill_message_contents(jsonb);
