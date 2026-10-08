CREATE INDEX CONCURRENTLY conversations_assignment_cursor_idx ON public.conversations USING btree (assigned_at, id) WHERE (assigned_agent_id IS NOT NULL);
