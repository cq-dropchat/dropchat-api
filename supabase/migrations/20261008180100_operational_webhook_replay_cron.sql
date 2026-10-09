select cron.schedule('replay-webhook-receipts','30 seconds',$$select public.replay_webhook_receipts();$$);
