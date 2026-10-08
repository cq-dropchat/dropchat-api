CREATE INDEX CONCURRENTLY conversations_waiting_cursor_idx ON public.conversations USING btree (awaiting_human_since, id) WHERE (awaiting_human_since IS NOT NULL);
