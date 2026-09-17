create policy "members can download their orgs media"
on storage.objects
for select
to authenticated, anon
using (
  bucket_id = 'media'
  and (storage.foldername(name))[2] in ( select rls.get_authorized_orgs('member')::text ) -- message v1 path is organizations/<org_id>/attachments/<file_id>
  -- Attachments of membership-scoped conversations (e.g. a private Slack
  -- DM) are only downloadable by members who can see a referencing message;
  -- unreferenced objects (just-uploaded, legacy) stay org-scoped.
  and rls.is_media_visible(name)
);

create policy "members can upload their orgs media"
on storage.objects
for insert
to authenticated, anon
with check (
  bucket_id = 'media'
  and (storage.foldername(name))[2] in ( select rls.get_authorized_orgs('member')::text ) -- message v1 path is organizations/<org_id>/attachments/<file_id>
);
-- F18: an organization's export files, organizations/<org_id>/exports/<id>.zip
-- in the private `exports` bucket. Owners only (the org-delete rule); only the
-- worker (service role) writes them.
create policy "owners can download their org exports"
on storage.objects
for select
to authenticated, anon
using (
  bucket_id = 'exports'
  and (storage.foldername(name))[2] in ( select rls.get_authorized_orgs('owner')::text )
);
