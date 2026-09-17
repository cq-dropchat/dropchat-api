CREATE TRIGGER handle_organization_export_requested AFTER INSERT ON public.organization_exports FOR EACH ROW EXECUTE FUNCTION public.edge_function('/org-export', 'post');



-- Hand-written (pg_cron is imperative): hourly, for stale claims and expiry.
select cron.schedule(
  'org-export',
  '15 * * * *',
  $$
  select net.http_post(
    url := c.url || '/org-export',
    headers := jsonb_build_object(
      'content-type', 'application/json',
      'authorization', 'Bearer ' || c.token
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 10000
  )
  from public.edge_functions_config() c
  $$
);
