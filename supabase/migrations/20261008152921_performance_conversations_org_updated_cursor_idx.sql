CREATE INDEX CONCURRENTLY conversations_org_updated_cursor_idx ON public.conversations USING btree (organization_id, updated_at, id);
