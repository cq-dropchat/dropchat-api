-- E1. The error panel is the one thing in this schema that is not scoped to an
-- organization, so none of the usual helpers apply: an issue belongs to the
-- product, not to a tenant, and its sample can carry another tenant's ids.
-- Nobody reads these tables except a platform admin.
--
-- Writes never arrive through a policy. Rows are created by
-- public.record_error_issue (SECURITY DEFINER, revoked from every API role),
-- so there is no INSERT policy on any of the three tables and no DELETE
-- policy either — purge_expired_rows does the deleting.

alter table public.platform_admins enable row level security;

-- Your own row and nothing else. This is what lets the UI ask "should I show
-- the panel?" without handing anyone the list of who can see it.
create policy "platform admins can read their own row"
on public.platform_admins
for select
to authenticated
using (user_id = (select auth.uid()));

alter table public.error_settings enable row level security;

create policy "platform admins can read the error settings"
on public.error_settings
for select
to authenticated
using (rls.is_platform_admin());

alter table public.error_issues enable row level security;

create policy "platform admins can read the error issues"
on public.error_issues
for select
to authenticated
using (rls.is_platform_admin());

create policy "platform admins can triage the error issues"
on public.error_issues
for update
to authenticated
using (rls.is_platform_admin())
with check (rls.is_platform_admin());

-- Triage is a decision about an issue, not a licence to rewrite it. Supabase's
-- default privileges grant UPDATE on every column of a new public table to
-- `authenticated`; narrowing it here means a stolen admin session can move an
-- issue's status and leave a note, and cannot touch the counter, the timestamps
-- or the captured samples — the parts that are evidence.
revoke update on public.error_issues from anon, authenticated;

grant update (status, notes) on public.error_issues to authenticated;
