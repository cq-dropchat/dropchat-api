-- F11. The dispatch sweep moves into public.dispatch_pending_messages():
-- same questions as before, plus the lease (status.dispatching) and the
-- backoff (status.retry_at), served by messages_dispatch_pending_idx, and
-- testable from pgTAP. Hand-written: pg_cron schedules are imperative.
select cron.unschedule('dispatch-outgoing-pending-messages');

select cron.schedule(
  'dispatch-outgoing-pending-messages',
  '* * * * *',
  $$ select public.dispatch_pending_messages() $$
);
