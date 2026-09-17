# TODO

## Billing (long-term)

Core billing

- [x] Renewal cron job — `billing.renew_subscriptions` every 5 minutes rotates
      current_period_start/end, expires unspent included credits and re-grants
      the plan's balance products (F17; there is no `change_plan` function)
- [ ] WhatsApp template billing — record template send costs in the ledger
      (costs table is ready, just needs the ledger insert in the dispatcher)
- [ ] Plan downgrade scheduling — store pending plan change, apply at period end
      instead of immediately

Monetization

- [ ] Invoice generation — aggregate usage + overages from plans_products,
      create invoice + items
- [ ] Payment integration — Stripe checkout for paid plans, webhooks for payment
      success/failure/refunds

## Slack integration (internal comms)

- [ ] Thread panel UI in open-bsp-ui — `messages.thread_id` exists but has no
      UI; Slack without threads is broken

- [ ] UI: don't render unechoed Slack sends — a dispatched row has
      sender_address null until the echo fills in the member's Slack user id, so
      other members would briefly see it attributed as their own; hide (or mark
      pending) rows with sender null + status.accepted in Slack conversations
      until the echo lands

- [ ] UI: Realtime visibility updates — subscribe the UI to
      `conversations_agents` changes so a newly-visible conversation appears
      without refresh (needs the table in the realtime publication and possibly
      `webhook_table`)

- [ ] Review webhooks — allow more than one table per webhook

- [ ] Review re-syncs — e.g. re-sync since the last message; does a media
      message re-sync overwrite the internal file uri (internal://media/…),
      causing loss/re-upload/content re-extraction?

- [ ] Offer user-scoped WhatsApp/Instagram connections

## General

- [x] Webhook delivery retries — queue table + pg_cron worker, HMAC, backoff,
      dead letter (F06) — pg_net makes one attempt per event (no retry, backoff,
      or dead-letter). Add retry with backoff + a dead-letter view. Options: a
      pg_cron sweep re-firing net.\_http_response failures, or move delivery to
      a queue table (pgmq) with attempt-count + backoff. Enqueue is already
      durable/transactional; only redelivery is missing.

- [x] Batched/async mass deletions — mark + sweep in pg_cron (F18):
      `deletion_requests`, `sweep_deletions` every minute (5,000 rows/run). The
      Meta callbacks verify `signed_request` and act on the owning organization
      only. An organization's media files go with the hourly `storage-gc` once
      the sweep has deleted the organization row. An account-scoped deletion
      (Meta data deletion) records its media (`deletion_media`) and `storage-gc`
      removes what no remaining message references (F18). Still open: v0 media
      references (`media.id` without the `internal://media/` prefix), which the
      §5.2 backfill has not converted in production yet.

- [ ] Move the RLS helpers out of `public`.

- [ ] Members' lists still show deleted agents — the SELECT policies keep them
      readable on purpose (message authorship, roster names), so the filtering
      belongs to the readers: UI member lists, and anything that ever counts
      seats.

- [ ] API-key-created `local` conversations are invisible orphans — the insert
      policy admits `anon`, but the participant trigger needs `auth.uid()`, so
      the row lands with no participants and no one can ever see it. Either drop
      `anon` from the policy or give the keyless path a `channel`.

- [ ] Uniform connection ownership — whatsapp/instagram already resolve the
      newest connected row, so reconnecting from another org steals the
      connection (fine: whoever owns the account may move it). Do the same for
      slack (drop the connect 409) and the connectors. Exception: whatsapp-web
      is a device login, so several tenants can hold live sessions for one
      number at once. Optional: tenant discrimination in generic-webhook.

- [x] Data export / DB dump — `rpc/request_organization_export` (owners) and the
      `org-export` worker write a ZIP with one NDJSON per table to the private
      `exports` bucket, without secrets or media, for 7 days (F18,
      INTEGRATING.md §9). Still open: a UI for it, and an export bigger than the
      function's memory or Storage's upload limit ends `failed`.

- [x] Encrypt API keys — stored as sha256 + prefix (F14)

- [ ] Improved error handling
      https://modelcontextprotocol.io/specification/2025-03-26/server/tools#error-handling

- [x] Timestamp precision (JS milliseconds vs PostgreSQL microseconds)

- [x] API keys equal agents (same roles and policies)

- [x] Split supabase.ts into different files

- [x] Revisit contacts and contacts_addresses

- [ ] Respond to all / non-contacts

- [ ] Enhanced privacy (optional, do not store messages from contacts)

- [x] Revisit whatsapp-management security

- [x] Sanitize tool names Error: 400 Invalid 'tools[0].function.name': string
      does not match pattern. Expected a string that matches the pattern
      '^[a-zA-Z0-9_-]+$'.
