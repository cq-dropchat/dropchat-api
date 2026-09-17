-- Hand-written: db diff does not model execute privileges.
--
-- The dispatch-sweep (20260917042109) and webhook-delivery migrations revoked
-- execute from `public` only. Supabase's default privileges grant execute on
-- new functions to anon and authenticated by name, so these SECURITY DEFINER
-- functions stayed callable over PostgREST RPC by any caller:
-- pending_dispatch_candidates returned every tenant's pending outgoing rows,
-- and the lease and sweep functions let anyone stall, reschedule or fire
-- dispatches and webhook deliveries. pg_cron runs them as postgres and the
-- dispatchers as service_role, neither of which is affected.
revoke execute on function public.claim_message_dispatch(uuid) from anon, authenticated;
revoke execute on function public.release_message_dispatch(uuid, jsonb) from anon, authenticated;
revoke execute on function public.pending_dispatch_candidates() from anon, authenticated;
revoke execute on function public.dispatch_pending_messages() from anon, authenticated;
revoke execute on function public.webhook_retry_delay(integer) from anon, authenticated;
revoke execute on function public.webhook_max_attempts() from anon, authenticated;
revoke execute on function public.record_webhook_result(uuid, integer, text) from anon, authenticated;
revoke execute on function public.settle_webhook_deliveries() from anon, authenticated;
revoke execute on function public.dispatch_webhook_deliveries(integer) from anon, authenticated;
revoke execute on function public.deliver_webhooks() from anon, authenticated;
