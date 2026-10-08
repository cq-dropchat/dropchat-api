CREATE INDEX CONCURRENTLY messages_org_conv_history_cursor_idx ON public.messages USING btree (organization_id, conversation_id, "timestamp" DESC, id DESC);
