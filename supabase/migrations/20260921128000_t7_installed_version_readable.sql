set check_function_bodies = off;

CREATE OR REPLACE FUNCTION rls.runs_template_version(_template_id uuid, _version integer)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  return exists (
    select 1
    from public.agents a
    where a.template_id = _template_id
      and a.template_version = _version
      and a.organization_id in (select rls.get_authorized_orgs('member'))
  );
exception when insufficient_privilege then
  return false;
end;
$function$
;


  create policy "members can read the versions their agents run on"
  on "public"."agent_template_versions"
  as permissive
  for select
  to authenticated, anon
using (rls.runs_template_version(template_id, version));




-- Hand-appended: `db diff` does not model function EXECUTE privileges.
revoke execute on function rls.runs_template_version(uuid, integer) from public;

grant execute on function rls.runs_template_version(uuid, integer)
to anon, authenticated, service_role;
