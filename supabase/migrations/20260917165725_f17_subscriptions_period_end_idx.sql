-- F17: CONCURRENTLY by hand (one row per organization; no write lock).
CREATE INDEX CONCURRENTLY subscriptions_current_period_end_idx ON billing.subscriptions USING btree (current_period_end);


