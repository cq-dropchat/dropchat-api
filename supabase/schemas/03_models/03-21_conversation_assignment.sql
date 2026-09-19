-- H1 — the references and indexes that tie an assignment to an agent.
--
-- They live here, not in the tables' own files, for one reason: both point at
-- public.agents, and the schema files are applied in name order, so anything
-- declared in 03-00 (organizations) or 03-03 (conversations) would reference a
-- table that does not exist yet.
--
-- Both are COMPOSITE, against agents_organization_id_id_key (03-04): naming
-- the tenant in the reference is what makes "assign this conversation to
-- another organization's agent" impossible to write, instead of merely
-- impossible to reach through the current code.

alter table only public.conversations
add constraint conversations_assigned_agent_id_fkey
foreign key (organization_id, assigned_agent_id)
references public.agents(organization_id, id)
-- A retired agent is a soft delete (agents.deleted_at), so this fires only on
-- a hard delete, which today means the organization cascade. Null, not
-- cascade: losing the agent must not take the conversation with it.
on delete set null;

-- Serves two readers: "what is assigned to this agent" (the UI's "Mías"
-- filter, H6) and the FK check above when an agent row is deleted. Partial,
-- because an unassigned conversation is the common row and nothing looks it
-- up by a null assignment — H4's sweeps scan by their own timestamps.
create index conversations_assigned_agent_idx
on public.conversations
using btree (organization_id, assigned_agent_id)
where assigned_agent_id is not null;

alter table only public.organizations
add constraint organizations_entry_agent_id_fkey
foreign key (id, entry_agent_id)
references public.agents(organization_id, id)
on delete set null;
