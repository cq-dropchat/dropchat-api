-- F03. The per-tenant key first, built CONCURRENTLY (each statement of a
-- migration runs on its own, outside a transaction block — verified with the
-- CLI), then the global one goes. Between the two every insert satisfies
-- both, so there is no window without a uniqueness guarantee.
CREATE UNIQUE INDEX CONCURRENTLY messages_org_external_id_key ON public.messages USING btree (organization_id, external_id);

alter table "public"."messages" drop constraint "messages_external_id_key";
