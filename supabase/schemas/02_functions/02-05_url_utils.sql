-- Lives before 03_models: webhooks.url's check constraint calls it.

-- Where a webhook may point. HTTPS only, a hostname (never an IP literal —
-- the private ranges, loopback, link-local and the cloud metadata address
-- are all literals), no userinfo, and none of the names that resolve
-- inside the platform. A regex cannot follow DNS: a public name that
-- resolves to a private address is still reachable, which is the limit of
-- what SQL can check and is why pg_net's timeout is short.
create function public.is_public_https_url(url text) returns boolean
language sql
immutable
set search_path to ''
as $$
  select url is not null
    and url ~* '^https://[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(:[0-9]{1,5})?(/[^\s]*)?$'
    and url !~* '^https://[^/]*\.(internal|local|localhost|lan|home|arpa)(:|/|$)'
    and url !~* '^https://[^/]*supabase\.(internal|co\.internal)(:|/|$)'
    and url !~* '^https://[^/]*@'
    -- IPv4 literal (every label numeric): 10.x, 127.x, 169.254.169.254, …
    and url !~ '^https://[0-9.]+(:|/|$)';
$$;
