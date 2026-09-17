-- F06. The webhook worker: settle the previous tick, send what is due.
-- Every 30 seconds; an idle tick is one probe on webhook_deliveries_due_idx.
-- Hand-written: pg_cron schedules are imperative, db diff cannot model them.
select cron.schedule(
  'deliver-webhooks',
  '30 seconds',
  $$ select public.deliver_webhooks() $$
);
