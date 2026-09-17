alter table public.secrets enable row level security;

-- No policies: RLS with nothing permissive is a closed door for every API
-- role, and the service role bypasses RLS. The revokes below are the second
-- lock — the schema's default privileges would otherwise still grant the
-- table to anon/authenticated, and a policy added by mistake later would
-- then be enough to open it.
revoke all on table public.secrets from anon, authenticated;
