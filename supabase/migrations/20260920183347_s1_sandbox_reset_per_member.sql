drop policy "members can delete their orgs local and sandbox conversations" on "public"."conversations";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION rls.get_own_sandbox_addresses()
 RETURNS TABLE(organization_id uuid, address text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select a.organization_id, a.id::text
  from public.agents a
  where a.user_id = auth.uid() and a.deleted_at is null;
$function$
;


  create policy "members can delete their orgs local and sandbox conversations"
  on "public"."conversations"
  as permissive
  for delete
  to authenticated, anon
using (((organization_id IN ( SELECT rls.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) AND ((service = 'local'::public.service) OR ((service = 'sandbox'::public.service) AND (((organization_id, address) IN ( SELECT s.organization_id,
    s.address
   FROM rls.get_own_sandbox_addresses() s(organization_id, address))) OR (organization_id IN ( SELECT rls.get_authorized_orgs('admin'::public.role) AS get_authorized_orgs))))) AND ((((organization_id, service, organization_address) IN ( SELECT v.organization_id,
    v.service,
    v.address
   FROM rls.get_visible_addresses() v(organization_id, service, address))) AND (NOT (id IN ( SELECT rls.get_restricted_conversations() AS get_restricted_conversations)))) OR (id IN ( SELECT rls.get_participant_conversations() AS get_participant_conversations)))));



