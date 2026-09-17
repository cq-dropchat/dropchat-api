-- F10: who may join the broadcast channels of 04-12. Realtime checks this
-- once when a client joins a private channel, with realtime.topic() set.
-- Nobody but the triggers writes: there is no insert policy.
create policy "members join their realtime channels"
on realtime.messages
for select
to authenticated, anon
using (
  realtime.messages.extension = 'broadcast'
  and (
    -- org:<id> — members and API keys of the organization.
    public.realtime_topic_uuid('org') in (select rls.get_authorized_orgs('member'))
    -- agent:<id> — only the member that agent is.
    or public.realtime_topic_uuid('agent') in (
      select a.id from public.agents a
      where a.user_id = auth.uid() and a.deleted_at is null
    )
    -- conv:<id> — whoever the conversations policy lets read it.
    or exists (
      select 1 from public.conversations c
      where c.id = public.realtime_topic_uuid('conv')
    )
  )
);
