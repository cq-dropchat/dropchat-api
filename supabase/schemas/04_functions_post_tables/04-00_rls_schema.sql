-- The schema the RLS helpers live in (P8).
--
-- They used to live in `public`, which PostgREST exposes: every one of them
-- was a live RPC endpoint for anon and authenticated (Postgres grants EXECUTE
-- on a new function to PUBLIC, and `revoke … from public` does not survive a
-- `create or replace`). They are SECURITY DEFINER and answer about the caller,
-- so what leaked was small — your own organizations, your own accounts — but
-- they are the machinery of row-level security, not an API, and nothing
-- outside SQL has ever called one.
--
-- This schema is not in config.toml's exposed list, so PostgREST does not
-- serve it at all. The policies that call these functions run as the invoking
-- role, so that role still needs USAGE here and EXECUTE on them; what it no
-- longer has is a way to reach them over HTTP.
create schema if not exists rls;

grant usage on schema rls to anon, authenticated, service_role;
