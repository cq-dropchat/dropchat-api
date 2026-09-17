# Changelog

## Unreleased

- **The RLS helpers moved to the `rls` schema** (P8). The SECURITY DEFINER
  functions the policies call — `get_authorized_orgs`, `get_visible_addresses`,
  `get_participant_conversations`, `get_restricted_conversations`,
  `is_restricted_conversation`, `is_conversation_visible`, `is_media_visible`,
  `get_own_agents` and the two agent-identity guards — were in `public`, which
  PostgREST exposes, so each one was reachable at `/rest/v1/rpc/<name>` with the
  anon key. They answer about their caller, so they leaked nothing about other
  tenants, but they are internal machinery. They now live in a schema PostgREST
  does not serve; the policies are unchanged apart from the qualification. If
  you were calling one over REST — nothing here ever did — it is gone.

- **`api_keys.key` is gone, and so is the plaintext fallback** (P8, closing
  F14). The write-only `key` column — where a client could still hand the
  database a plain key for it to hash — no longer exists, and
  `get_authorized_orgs` compares `key_hash` and nothing else: a row without a
  hash authenticates nothing, whatever it holds. `create_api_key` (owners) is
  the only way to mint a key and still returns it exactly once. Announced for
  2026-11-01; brought forward because no deployment holds such a row. If you
  were inserting into `api_keys` yourself, that insert now fails with `42703`
  (undefined column) — use the RPC.

- **Media preprocessing is queued like everything else** (P5). The per-minute
  safety net that picked up messages whose media was never preprocessed called
  the function with pg_net directly — no retry, no fairness between
  organizations, no metric — on exactly the messages that had already failed
  once. It now files the call in `public.edge_calls` like the trigger does, and
  skips any message that already has one pending or in flight, so nothing is
  queued twice. `public.edge_calls` is the only way agent-client and
  media-preprocessor are invoked now. Preprocessing a file can start a few
  seconds later than before (the queue runs every 5 seconds); nothing changes
  for REST clients.

- **Every message's `content` is guaranteed to follow the v1 schema** (P3,
  §5.2). `messages_content_schema` was `NOT VALID`: it checked every new row but
  could say nothing about the legacy ones that predate the v1 shape (no
  `version`, no `kind`). The backfill has run and the constraint is now
  validated, so a reader can assume the shape for every row in the table instead
  of testing for it. `rpc/backfill_message_contents` (service role only) is gone
  with it. Nothing changes for REST clients: the same contents were already
  refused on insert.

- **Realtime broadcast channels** (F10). Conversation and message changes are
  published to private Realtime channels: `org:<organization_id>` (a notice with
  `table`, `op`, `id`, `organization_id`, `conversation_id`, `updated_at` and,
  for a message update, `status_changed`; never content) for conversations
  shared with the whole organization; `agent:<agent_id>` (the same notice) for
  conversations only some members see, sent to each of them; and
  `conv:<conversation_id>` (the full row). Join with
  `channel(topic, { config: { private: true } })`; members and API keys of the
  organization may join `org:`, a member their own `agent:`, and anyone who can
  read the conversation its `conv:`. Fetch the rows a notice names through the
  REST API. `postgres_changes` keeps working.

- **Agent and media preprocessing calls are queued and retried** (F12).
  agent-client and media-preprocessor are no longer called with pg_net from the
  message triggers: calls go to `public.edge_calls` and a pg_cron worker sends
  them every 5 seconds, round-robin across organizations, retrying
  5xx/429/connection failures with backoff and giving up after 5 attempts.
  `public.edge_calls_health` (service role) shows the backlog per function and
  organization. A reply from the agent can start ~2–5 s later than before.
  media-preprocessor now claims a message before working on it, so a repeated
  call does not transcribe it twice. Nothing changes for REST clients.

- **Organization export** (F18). `rpc/request_organization_export` with
  `{"_organization_id"}` (owners and owner API keys only; `42501` otherwise)
  files an export and returns its id; while one is pending or processing, the
  same id is returned. The `org-export` worker writes a ZIP to the private
  `exports` bucket at `organizations/<org>/exports/<id>.zip` with one NDJSON per
  table (`organizations`, `organizations_addresses`, `contacts_addresses`,
  `conversations`, `messages`, `agents`, `webhooks`, `logs`) and a
  `manifest.json`. Credentials are not included and attachments are not either
  (their URIs are). Owners read `public.organization_exports` (`status`:
  `pending`, `processing`, `ready`, `failed`, `expired`) and sign a download URL
  for `object_name`. Files expire after 7 days, and at once when the
  organization or one of its accounts is deleted. Export files do not count
  against the storage quota. See INTEGRATING.md §9.

- **Deleting an account also deletes its attachments** (F18). When one account
  is deleted (Meta's data-deletion callback), the attachments its messages
  referenced are now removed from Storage by the hourly `storage-gc` run, unless
  another message of the organization still uses the same file (attachments are
  stored once per content). Before, they stayed in Storage for as long as the
  organization existed. Legacy (v0) media references are not covered.

- **Billing periods renew** (F17). A pg_cron job (`renew-subscriptions`, every 5
  minutes) renews every subscription whose `current_period_end` has passed: the
  period advances to the current one (missed periods are skipped, not granted),
  the unspent part of the previous period's included balance products (AI
  credits) expires as a ledger entry of the new type `expiration`, and the
  plan's included amount is granted again. Included credits do not accumulate;
  credits bought as top-ups are kept (included credits count as spent first).
  New columns: `billing.subscriptions.canceled_at` (a subscription canceled on
  or before the end of its period is not renewed) and
  `billing.ledger.period_start` (grants and expirations are unique per
  organization, product and period). New subscriptions get `current_period_end`;
  existing ones are backfilled to one cycle after their start, so those older
  than a cycle are renewed on the first run. Plans without `billing_cycle` renew
  monthly.

- **Instagram: a rejected token stops outgoing sends too** (F28). While an
  Instagram account carries `extra.needs_reauth`, outgoing messages fail at once
  with a `190` error, without calling Graph, and read receipts and typing
  indicators are skipped. The first `190` writes an `error` line to
  `public.logs` (category `dispatch`). Re-logging in now clears the flag
  (before, the upsert kept it), and so does a successful daily token refresh. A
  refresh that fails for a transient reason (no answer, `5xx`, a transient Graph
  code) no longer sets it. A token renewed while a send was in flight is not
  flagged.

- **One request id per message chain** (F26). The Edge Functions send the
  `x-request-id` of the request they serve to PostgREST, and the database
  triggers that call the next function (agent-client, the dispatchers, the
  dispatch sweep) forward it. A webhook, the agent reply it causes and the
  dispatch of that reply now log the same `request_id`. A client that writes
  through the REST API may send its own `x-request-id`: when it is a UUID it is
  forwarded to our functions' logs; any other value is ignored. The id is never
  sent to third parties (agent tools, Meta, Slack, Instagram).

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
