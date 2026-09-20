drop policy "members can delete their orgs local conversations" on "public"."conversations";


  create policy "members can delete their orgs local and sandbox conversations"
  on "public"."conversations"
  as permissive
  for delete
  to authenticated, anon
using (((organization_id IN ( SELECT rls.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) AND (service = ANY (ARRAY['local'::public.service, 'sandbox'::public.service])) AND ((((organization_id, service, organization_address) IN ( SELECT v.organization_id,
    v.service,
    v.address
   FROM rls.get_visible_addresses() v(organization_id, service, address))) AND (NOT (id IN ( SELECT rls.get_restricted_conversations() AS get_restricted_conversations)))) OR (id IN ( SELECT rls.get_participant_conversations() AS get_participant_conversations)))));



