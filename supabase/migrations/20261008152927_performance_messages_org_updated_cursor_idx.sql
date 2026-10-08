CREATE INDEX CONCURRENTLY messages_org_updated_cursor_idx ON public.messages USING btree (organization_id, updated_at, id);
