# Changelog

## Unreleased

- **A versioned contract for message content** (F29).
  `contracts/message-content.v1.schema.json` is the JSON Schema of
  `messages.content` for version `"1"`: text, file, the data kinds (reaction,
  location, contacts, template, media placeholder, …) and record-only tool
  traces. It is generated from the types the Edge Functions compile against, and
  CI fails when it is stale. `openapi.json` remains PostgREST's dump of the REST
  surface, where `content` is only `jsonb`: validate against the schema instead.

- **WhatsApp: a rejected token stops outgoing sends for that account** (F28).
  When Meta answers a send with code 190 (token expired or revoked) on an
  account with its own token, the dispatcher sets
  `organizations_addresses.extra.dispatch_auth_failure` (`{code, message, at}`)
  and writes an `error` line to `public.logs` (category `dispatch`). Until a
  different token is stored for the account, outgoing messages fail at once with
  that error, without calling Meta, and read receipts are skipped. Storing a new
  token clears the mark in the same write. The account stays `connected`, so
  inbound messages keep arriving. Accounts on the shared system-user token are
  not marked.

- **MCP: choose the organization** (F27). A user who belongs to several
  organizations can name one with the `Organization-Id` header or, for
  connectors that cannot set headers, `?organization_id=` on the MCP URL. It
  must be one of the user's current memberships (`403` otherwise, `400` for a
  malformed id). Without it the server uses the user's oldest membership, the
  same one on every request; before, it took whichever membership the database
  returned first, and removed memberships could be picked. An API key already
  belongs to one organization: `Organization-Id` is optional and must match it
  (`403` otherwise).

- **Meta webhooks accept every configured app** (F19). With several apps in
  `META_APP_ID`/`META_APP_SECRET` (or the `INSTAGRAM_*` pair), a request without
  `?app_id=` is now checked against every secret instead of only the first, so a
  second app pointed at the same callback URL is no longer dropped. `?app_id=`
  still pins one app. A request that matches none is still answered 200 (Meta
  must not retry) and now logs an `error` line with the reason
  (`missing_signature`, `unknown_app_id`, `signature_mismatch`,
  `misconfigured`); the expected signature is no longer logged.

- **Retention for logs and onboarding tokens; no more `hooks` rows** (F15).
  `public.logs` rows older than 90 days and `onboarding_tokens` expired more
  than 30 days ago are deleted by the hourly `purge-expired-rows` job. The Edge
  Function triggers no longer insert into `supabase_functions.hooks` (one row
  per call, never read); the job empties what it already holds. To follow a
  request, use `net._http_response` (pg_net's TTL) or the function's
  `x-request-id` logs.

- **Deleting an organization is asynchronous** (F18). `DELETE` on
  `organizations` (owners, as before) no longer runs the cascade in the request:
  it sets `organizations.deletion_requested_at`, files a row in
  `public.deletion_requests`, moves the organization's accounts to status
  `deleting` and affects zero rows. From that moment the organization is gone
  for every member and API key (`get_authorized_orgs` skips it); the
  `sweep-deletions` pg_cron job removes its data in batches of 5,000 rows a
  minute and then the row itself, and the hourly `storage-gc` its media files.
  Instagram's data-deletion and deauthorize callbacks now act only on the
  organization that owns the account (its newest row) instead of every
  organization holding it; data deletion is filed the same way, account-scoped,
  and its confirmation code is the request id: the status URL answers `pending`
  or `completed` (404 for an unknown code). Account-scoped deletion does not yet
  remove the account's media files.

- **One agent turn per conversation** (F16). `agent-client` registers each
  inbound message in `public.agent_turns` and answers only while it holds that
  conversation's lease: a newer message supersedes an older one, a duplicate
  invocation of one message answers once, and a message arriving while the agent
  is answering waits for it and is answered with that reply in the history (the
  holder stops before its next LLM call). Service role only. A conversation
  whose invocation crashed is free again after 90 seconds.

- **Internal sweep functions are service-role only** (F11/F05 follow-up).
  `pending_dispatch_candidates`, `claim_message_dispatch`,
  `release_message_dispatch`, `dispatch_pending_messages`,
  `record_webhook_result`, `settle_webhook_deliveries`,
  `dispatch_webhook_deliveries` and `deliver_webhooks` were callable through
  `/rest/v1/rpc/*` by the anon key and any member (execute had been revoked from
  `public` only); they now answer 42501. `pending_dispatch_candidates` returned
  every organization's pending outgoing messages. Nothing legitimate called them
  over the API.

- **Edge Function logs are JSON with a request id** (F26). Every line is one
  JSON object (`ts`, `level`, `fn`, `request_id`, `msg`, and the details' fields
  such as `organization_id`, `message_id`). Responses carry `x-request-id`; a
  caller that sends one keeps it across functions. Log queries that matched the
  old `%c`-coloured text need updating.

- **AI credits are reserved and the ledger is idempotent** (F17). Before an LLM
  call, `check_limit(ai_credits, …)` is asked for the call's upper-bound cost
  (`billing.estimate_ai_cost`: input tokens at the input price plus the output
  budget at the output price) instead of zero, so the last call can no longer
  drive a balance negative. `billing.ledger` has `external_id` (the provider's
  response id), unique with `provider`: a retried write charges once. **The
  `messages` quota now counts what the cap caps**: messages the account sends
  and every insert by an API key or member; what contacts send is metered as the
  new product `messages_inbound`, which no tier caps. Usage history before this
  release mixes both.

- **Agent tools only reach public destinations** (F08). SQL hosts, HTTP tool
  URLs, libsql URLs and MCP server URLs are refused when they are IP literals in
  private/loopback/link-local/metadata ranges, internal names (`localhost`,
  single-label names, `*.internal`, `*.local`) or names that resolve to such
  addresses. SQL connections time out after 3 s and statements after 5 s; HTTP
  tool requests after 10 s, and redirects are returned, not followed. The HTTP
  tool no longer forwards headers chosen by the model except `content-type` and
  `accept`; put credentials in the tool's config. Remote MCP tool descriptions
  reach the model bounded to 1,024 characters and marked as untrusted. Local
  development: `AGENT_TOOL_ALLOWED_HOSTS` (comma-separated hostnames).

- **Outgoing dispatch has a lease and backoff** (F11). Dispatchers take
  `status.dispatching` before calling the service, so the insert trigger and the
  retry sweep never send one message twice. A transient failure records
  `status.attempts` and `status.retry_at` (1, 2, 4 … 60 minutes) instead of
  retrying every minute. Status webhooks can therefore show `dispatching`,
  `attempts` and `retry_at` keys on outgoing rows; all are removed or left as
  history once the message is accepted. The sweep runs
  `public.dispatch_pending_messages()` over a partial index.

- **Outgoing webhooks are queued, signed and retried** (F06/F12). The trigger no
  longer calls pg_net: it inserts one row per matching webhook in
  `public.webhook_deliveries`, and the `deliver-webhooks` pg_cron job (every 30
  s) sends them with a 5 s timeout, retries non-2xx answers after 1 s, 5 s, 30
  s, 5 min and 1 h, and marks them `failed` after the fifth attempt. The
  `limit 3` per event is gone. New headers: `x-openbsp-signature` (`sha256=`
  HMAC of the raw body with the webhook token), `x-openbsp-delivery-id`,
  `x-openbsp-event`. `webhooks.url` must be `https` to a public hostname (check
  constraint, `NOT VALID` for existing rows; the worker refuses to deliver to a
  URL that fails it). Payload shape unchanged.

- **`init_data` walks an index instead of sorting the organization** (F07). New
  index
  `messages_org_timestamp_idx (organization_id, timestamp desc,
  id desc)`,
  built concurrently. Same parameters, same result set (the p_limit newest
  messages, at most p_per_conversation per conversation, plus their
  conversations); ties on `timestamp` are now broken by `id desc`, so the order
  is total and a `p_until` follow-up never overlaps the previous page. Measured
  at 60k messages / 300 conversations under RLS: 112 ms and 4,000 temp pages
  before, 3.5 ms and no temp after.

- **Meta webhooks acknowledge before processing** (F05). `whatsapp-webhook` and
  `instagram-webhook` validate the signature and answer `200` immediately;
  tenant resolution, media download/upload and the upserts run after the
  response under `EdgeRuntime.waitUntil`, as the Slack webhook always did.
  Writes to `public.logs` no longer abort a batch. Nothing changes for
  integrators; a `logs` row may now be missing where a webhook used to fail
  whole.

- **API keys are stored hashed** (F14). `api_keys.key` is now a write-only slot:
  a key inserted there is turned into `key_hash` (sha256) and `key_prefix`
  (first 8 characters) before the row is stored, and reads back as `null` for
  everyone. Mint keys with the RPC
  `create_api_key(p_organization_id, p_name, p_role, p_expires_at)` (owners
  only), which returns the plain key exactly once. New columns `expires_at` (a
  key past it authenticates nothing) and `last_used_at` (stamped on use, at most
  once a minute, on read-write requests). Existing keys were hashed in place and
  keep working as they are. **Cutover 2026-11-01:** until then a row that still
  holds a plain key and no hash (none should exist) also authenticates by
  plaintext comparison; after it, only the hash counts, and the `key` column is
  removed in a following release. Integrations are unaffected: the `api-key`
  header is the same secret.

- **Message caps and a rate limit apply to API roles** (F09). An API key or a
  signed-in member is capped on every armed row it inserts into `messages`,
  whatever its shape (rows shaped like inbound used to skip the plan cap). Real
  inbound traffic from the service role is never capped. New per-organization
  rate limit for API roles: 120 armed inserts per minute
  (`public.message_rate_limit_per_minute()`); past it PostgREST answers
  `429 Too Many Requests` (SQLSTATE `PT429`) with a retry hint. Counters live in
  `public.rate_limits` (service role only).

- **`messages.external_id` is unique per organization** (F03), not across the
  table: `messages_external_id_key` is replaced by the unique index
  `messages_org_external_id_key (organization_id, external_id)`. Two tenants can
  now hold the same service id (two whatsapp-web sessions of one number, two
  accounts in one group). If you upsert messages through PostgREST, use
  `on_conflict=organization_id,external_id`; if you update by `external_id`,
  filter by `organization_id` too.

- **Credentials leave `extra`** (F02). `organizations_addresses.extra`
  (`access_token`, `refresh_token`), `agents.extra` (`api_key`,
  `tools[].config.password`, `tools[].config.token`, `tools[].config.headers`)
  and `organizations.extra` (`media_preprocessing.api_key`) now read back as the
  mask `********` for every API role, owners included. The values live in
  `public.secrets`, which only the service role can read. Writing keeps working
  as before: patch `extra` with the credential and the trigger stores it; write
  the mask back and nothing changes; write `null` to revoke. Tool credentials
  are keyed by `type:label` — renaming a tool asks for its credentials again.
  Webhook payloads for `organizations_addresses` carry the mask. Integrations
  that read a token out of `extra` through PostgREST must move to the service
  role and `functions/_shared/secrets.ts`.

## v1

- `messages.direction` and `contact_address` (conversations, messages) are
  dropped; superseded by `conversations.address`,
  `messages.conversation_address` and `sender_address` (incoming =
  `sender_address` set, outgoing = null).
- `group_address` was absorbed by the peer address (`conversations.address`,
  `messages.conversation_address`); use `conversations.type` to distinguish
  between direct, group, channel.
- `conversations.status` is dropped.
- Accounts are keyed `(organization_id, service, address)`: add `service` to
  lookups.
- `conversations` is read-only outside `local` service.
- Deleting an agent sets `deleted_at` instead of removing the row.
- Invitations moved to `public.invitations`, keyed by email; answer them with
  the `accept_invitation` / `reject_invitation` RPCs. Inserting an agent with a
  `user_id` is refused; people join by accepting.
- `contacts_addresses` is keyed
  `(organization_id, organization_address, service, address)`: the same peer
  through two connections is two rows.
- `contacts` is dropped, along with `contacts_addresses.contact_id`: the
  address-book entry is the `contacts_addresses` row itself, its display name in
  `extra` (`synced.name`, else `name`). `contacts` webhooks are gone.
