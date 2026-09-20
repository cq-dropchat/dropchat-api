# Tech Provider as a Service

Ship a WhatsApp (or Instagram) product **without registering with Meta as a Tech
Provider**. Your customers connect their own WhatsApp Business accounts _under
OpenBSP's_ Meta app via Embedded Signup; from then on you drive everything over
a plain REST API with an API key, and — if you want — that account's message
webhooks are delivered **straight to your app**.

OpenBSP is the Tech Provider. You are its API consumer. No Meta app review, no
business verification, no JS SDK on your side.

```
your customer ──(onboarding link)──► OpenBSP Embedded Signup ──► WABA connected
                                                                      │
your app ◄── messages (per-account webhook) ── Meta Cloud API ◄───────┘
your app ◄── account events / logs (OpenBSP webhooks or polling) ── OpenBSP
your app ──► send (OpenBSP REST  *or*  Meta directly with the account token)
```

There is exactly **one thing you do in the dashboard** — create your org and an
API key. Everything else is REST.

---

## Conventions

- **Base URL:** `https://qqfrzurledgywyhcxdse.supabase.co`
- **Dashboard:** `https://web.openbsp.dev`
- Every REST call sends **two** headers:

  ```
  apikey: <PUBLISHABLE_KEY>     # public Supabase publishable key (it's in the web bundle)
  api-key: <OPENBSP_API_KEY>    # the secret key you generate below
  ```

  Do **not** send `Authorization: Bearer <api-key>` — PostgREST would reject it
  as a non-JWT. See [AUTH.md](AUTH.md) for the full model.

- An API key acts for the organization, not as a member of it. Internal
  (`local`) conversations whose visibility comes from their participants
  therefore cannot be created with one, and the attempt fails with `422`: a
  `group` has no creator to record, and a `direct` needs its roster stated in
  `conversation_address` as agent ids (`<id>:<id>`). Use `type: "channel"` for
  an internal conversation the whole organization sees.

---

## 1. Create your organization (dashboard, one-time)

Sign in at [web.openbsp.dev](https://web.openbsp.dev) with Google or GitHub.
Your organization is created on first sign-in.

> This is the **only** step that needs a logged-in user — creating an
> organization (and your owner membership) is the one operation an API key can't
> do. After this you never need the UI again.

## 2. Generate an API key

Dashboard → **Settings → API Keys → New**. Pick a role:

- **owner** — full access, including minting onboarding links.
- **admin** — manage templates, contacts, webhooks, send messages.
- **member** — read + send.

Copy the key. It's scoped to this one organization and carries that role.

## 3. Make REST calls

PostgREST is exposed at `/rest/v1/<table>`; edge functions at
`/functions/v1/<function>`. A couple of reads:

```bash
# Connected accounts (phone numbers) in your org
curl 'https://qqfrzurledgywyhcxdse.supabase.co/rest/v1/organizations_addresses?service=eq.whatsapp&select=address,status,extra' \
  -H 'apikey: <PUBLISHABLE_KEY>' -H 'api-key: <OPENBSP_API_KEY>'

# Recent platform/Meta events for your org (account updates, signup/history errors)
curl 'https://qqfrzurledgywyhcxdse.supabase.co/rest/v1/logs?select=level,category,service,message,metadata,created_at&order=created_at.desc&limit=20' \
  -H 'apikey: <PUBLISHABLE_KEY>' -H 'api-key: <OPENBSP_API_KEY>'
```

## 4. (Optional) Register webhooks instead of polling

So your app is _pushed_ events. Dashboard → **Settings → Webhooks → New**, or
via REST:

```bash
curl -X POST 'https://qqfrzurledgywyhcxdse.supabase.co/rest/v1/webhooks' \
  -H 'apikey: <PUBLISHABLE_KEY>' -H 'api-key: <OPENBSP_API_KEY>' \
  -H 'Content-Type: application/json' \
  -d '{
    "table_name": "organizations_addresses",
    "operations": ["insert", "update"],
    "url": "https://your-app.com/openbsp/accounts",
    "token": "<your shared secret>"
  }'
```

No delivery is ever queued for a row whose `service` is `sandbox` — those are
the simulator's drills, not your customers'. See "Drills" under `## 7`.

Subscribable tables: `organizations_addresses` (account connected /
disconnected; credentials in `extra` read as `********`), `logs` (Meta events &
errors), `contacts_addresses`, plus `messages` / `conversations` (the latter two
only carry data for accounts _not_ using a per-account webhook — see step 7).
OpenBSP `POST`s `{ entity, action, data: <row> }` to your `url`.

**URL rules.** `https://` to a public hostname only. Plain `http`, IP literals,
`localhost` and internal names (`*.internal`, `*.local`, …) are refused.

**Delivery.** Events are queued in the same transaction as the change and sent
within ~30 s, with a 5 s timeout. Any non-2xx answer (or a timeout) is retried
after 1 s, 5 s, 30 s, 5 min and 1 h; after the fifth failure the delivery is
kept as `failed` in `webhook_deliveries` (readable by owners). Deliveries can
arrive more than once and out of order: dedupe on `x-openbsp-delivery-id`.

**Headers.**

| Header                  | Value                                              |
| ----------------------- | -------------------------------------------------- |
| `authorization`         | `Bearer <token>`, when the webhook has a token     |
| `x-openbsp-signature`   | `sha256=<hex HMAC-SHA256(token, raw body)>`        |
| `x-openbsp-delivery-id` | unique per delivery (stable across retries)        |
| `x-openbsp-event`       | `<table>.<insert\|update>`, e.g. `messages.insert` |

**Verify the signature** against the raw body, before parsing it:

```ts
async function verifyOpenBSP(req: Request, token: string) {
  const body = await req.text();
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(token),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(body),
  );
  const expected = "sha256=" +
    [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0"))
      .join("");
  const got = req.headers.get("x-openbsp-signature") ?? "";
  if (got.length !== expected.length) return null;
  let diff = 0;
  for (let i = 0; i < got.length; i++) {
    diff |= got.charCodeAt(i) ^ expected.charCodeAt(i);
  }
  return diff === 0 ? JSON.parse(body) : null;
}
```

The same code, with tests, is
[`supabase/functions/_shared/webhook_signature.ts`](supabase/functions/_shared/webhook_signature.ts).

## 5. Mint an onboarding link (API key)

This is how you hand a customer a link to connect their WhatsApp. Create an
`onboarding_token` — and, if you want their traffic delivered to **your** app,
set `callback_url` + `verify_token` (the per-account webhook override):

```bash
curl -X POST 'https://qqfrzurledgywyhcxdse.supabase.co/rest/v1/onboarding_tokens?select=id' \
  -H 'apikey: <PUBLISHABLE_KEY>' -H 'api-key: <OWNER_OPENBSP_API_KEY>' \
  -H 'Content-Type: application/json' -H 'Prefer: return=representation' \
  -d '{
    "name": "Acme Corp",
    "organization_id": "<YOUR_ORG_ID>",
    "service": "whatsapp",
    "expires_at": "2026-07-01T00:00:00Z",
    "callback_url": "https://your-app.com/acme/whatsapp",
    "verify_token": "a-long-random-secret"
  }'
```

Minting requires an **owner** API key, and `organization_id` is required — it
must be the organization your API key belongs to (row-level security rejects the
insert otherwise, with a 42501 error). Find it in the dashboard URL or via
`GET /rest/v1/organizations?select=id,name`. The response `id` is the link
token; hand the customer:

```
https://web.openbsp.dev/onboard/whatsapp/<id>
```

(`callback_url`/`verify_token` are optional — omit them to keep messages flowing
through OpenBSP instead.)

## 6. The customer connects

They open the link and complete Embedded Signup (no OpenBSP account, no Meta
developer setup needed). On success:

- the onboarding token flips to `used`;
- a row appears in `organizations_addresses` (`status = connected`) whose
  `extra` holds `waba_id` and `phone_number`. The **`access_token`** is stored
  server-side (`public.secrets`, service role only) and reads back through the
  API as the mask `********`;
- if you set a `callback_url`, that WABA's message webhooks are pointed at it.

You learn about it via your `organizations_addresses` webhook (step 4) or by
polling (step 8).

### Capturing the credentials

A common pitfall: the `callback_url` you set on the token is registered **with
Meta** — Meta sends message traffic there, and its payloads carry only the
`phone_number_id`, **never credentials**. The `waba_id` / `access_token` /
`phone_number` your app needs to call the Cloud API arrive on the **OpenBSP
plane**: the `organizations_addresses` webhook (step 4). Its payload is the full
row:

```jsonc
{
  "entity": "organizations_addresses",
  "action": "insert", // or "update"
  "data": {
    "organization_id": "…",
    "service": "whatsapp",
    "address": "883…", // = phone_number_id
    "status": "connected",
    "extra": {
      "waba_id": "…",
      "access_token": "EAAG…",
      "phone_number": "54911…",
      "verified_name": "…",
      "flow_type": "existing_phone_number",
      "callback_url": "https://your-app.com/tenant-42/whatsapp",
      "verify_token": "…"
    }
  }
}
```

**Mapping the row to your tenant:** the onboarding token id is not in the row —
correlate with `extra.callback_url` or `extra.verify_token` instead: you chose
those values when you minted the link, so mint each tenant's link with a unique
one (e.g. `…/tenant-42/whatsapp`) and match on it when the webhook arrives.

## 7. Receive messages and send

**Receiving** — with a `callback_url` set, Meta delivers that account's incoming
messages and statuses **directly to your app's URL** (verified with your
`verify_token`). Account-level events (connect/disconnect, errors) still come
from OpenBSP via the `organizations_addresses` / `logs` channels. OpenBSP does
**not** store these messages.

**Sending** — two options:

- **Through OpenBSP** (simplest): `POST /rest/v1/messages` with the
  `organization_address` (the `phone_number_id`), `conversation_address`, and a
  `content` object. See [MIGRATING_FROM_TWILIO.md](MIGRATING_FROM_TWILIO.md) for
  the message shapes.
- **Directly to Meta** (fully autonomous): call the WhatsApp Cloud API yourself
  with the account's token. The token is not readable through the API
  (`extra.access_token` is the mask `********` for every API role): it is the
  system-user token your own Meta app issued during Embedded Signup, so keep it
  on your side — or, if you self-host OpenBSP, read it with the service role
  from `public.secrets` (`functions/_shared/secrets.ts`).

### Who answers a conversation (H1)

A conversation is answered by one agent, recorded on the row itself:

| Column                            | Meaning                                                                                                                              |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `conversations.assigned_agent_id` | Who holds this conversation: an AI agent, a member (a human took it), or `null` — nobody yet, so the next inbound message routes it. |
| `conversations.assigned_at`       | When that assignment was made.                                                                                                       |
| `organizations.entry_agent_id`    | The agent that takes a conversation nobody holds. Unset means "the oldest eligible AI agent".                                        |

All three are **read-only over the API**: a direct `PATCH` fails with `42501`,
because every change has to go through the function that also records it. An
agent is eligible when it is not a membership (`user_id is null`), not retired
(`deleted_at is null`) and its `extra.mode` is neither `inactive` nor `draft`.

Each change inserts a **record-only message** in the conversation — internal,
never dispatched, never billed:

```json
{
  "version": "1",
  "type": "data",
  "kind": "assignment",
  "internal": true,
  "data": {
    "from": null,
    "to": "8f1c…",
    "awaiting_human": false,
    "by": null,
    "cause": "entry"
  }
}
```

`cause` is one of `routing`, `entry`, `escalation`, `manual`, `takeover`,
`expiry`; `category` and `reason` appear when the change carries them (an
escalation to a human, from H3). Two consequences for an integrator:

- If you count what the contact received, filter internal rows out
  (`content->internal is null`) — the same filter tool traces already needed.
- Assignments emit `update` events of `conversations` on your webhooks. If you
  subscribe to that table, expect one event per conversation the first time it
  is answered.

On external services the AI answers `direct` conversations only. To let it
answer in groups, set `organizations.extra.ai_in_groups = true`.

### Handing a conversation to a person (H3)

`conversations.awaiting_human_since` is set when the agent escalates — its
`escalate_to_human` tool — and cleared as soon as anybody is assigned. While it
is set, no AI answers that conversation. The assignment note of the escalation
carries `category` (a closed list: `reclamo`, `pedido_fuera_de_alcance`,
`pide_persona`, `pago`, `envio`, `cambio_devolucion`, `otro`) and a free-text
`reason`.

To move an assignment yourself:

```bash
curl -X POST "$SUPABASE_URL/rest/v1/rpc/assign_conversation" \
  -H "apikey: $API_KEY" -H "Content-Type: application/json" \
  -d '{"p_conversation_id": "<uuid>", "p_agent_id": "<agent uuid or null>"}'
```

- `p_agent_id` a member → they hold it, and the AI stays out.
- `p_agent_id` an AI agent → it answers again.
- `null` → back to routing; the next inbound message picks an agent.

You must be able to SEE the conversation (the same rule that decides what
`/rest/v1/conversations` returns). An agent of another organization is refused
with `23503`; a retired agent, or an AI in `draft`/`inactive`, with a plain
error — they would hold a conversation nothing answers.

Sending an outgoing message as a member, while the conversation belongs to the
AI or is waiting for a person, also takes it (an assignment note of cause
`takeover`). Record-only rows (`content.internal`) do not. Turn it off per
organization with `organizations.extra.attention.auto_takeover = false`.

### Drills: the `sandbox` service (S1)

`public.service` has a value your integration will never be sent but may read:
`sandbox`. It is the simulator — a member of the organization writing as if they
were a customer, to try an agent out against the real path. Every organization
has one `sandbox` account in `organizations_addresses`, addressed by the
organization's own id.

**Webhooks never carry it.** No `sandbox` row fires a delivery, on any
subscribed table, so nothing you receive is a drill and you need no filter
there.

**Polling does carry it**, because a query is yours to write. If you poll
`messages` or `conversations` (`## 8`), exclude drills:

```
&service=neq.sandbox
```

Nothing is dispatched for a drill — there is no `sandbox` carrier, outgoing rows
are marked `delivered` in place and no read receipt is sent — but the agent's
replies are real LLM calls, so they appear in `billing.ledger` and count against
usage like any other message.

Each member's drills are their own: a `sandbox` conversation is addressed by the
agent id of the member who opened it, and only that member — or an admin — can
delete it. An API key authenticates without a user, so it owns no drill and
deletes none.

Your organization's export (`## 9`) leaves drills out too.

### How long an assignment lasts (H4)

`organizations.extra.attention` holds the settings, and every default applies
key by key:

| Key                          | Default            | Meaning                                                                                              |
| ---------------------------- | ------------------ | ---------------------------------------------------------------------------------------------------- |
| `timezone`                   | `America/Santiago` | IANA zone the schedule is read in.                                                                   |
| `business_hours`             | absent = 24/7      | `{ "mon": [["09:00","19:00"]], … }`, several windows a day for a break.                              |
| `ai_assignment_ttl_days`     | `14`               | Days without the contact writing before the conversation routes again (checked on the next message). |
| `human_assignment_ttl_hours` | `72`               | Hours without that person writing before it goes back to routing. `0` means never.                   |
| `human_wait_minutes`         | `30`               | Business minutes a contact waits for a person after an escalation.                                   |
| `on_human_wait_timeout`      | `notify_customer`  | Or `return_to_ai`, which hands the conversation back to the AI.                                      |
| `human_wait_message`         | a Spanish default  | What `notify_customer` sends, once.                                                                  |
| `auto_takeover`              | `true`             | Answering by hand takes the conversation.                                                            |

`extra` is written as a **JSON merge patch**: sending `null` for a key removes
it, which brings its default back. That is why "never expires" is `0` rather
than `null`, and how a schedule is cleared (`"business_hours": null`).

Two consequences on the wire: an assignment can change with no API call of yours
(an `update` event of `conversations`, and a note whose cause is `expiry`), and
a conversation waiting past the limit may receive one extra outgoing message —
the waiting message — which is never sent outside the channel's 24-hour window.

## 8. (Optional) Poll instead of webhooks

If you'd rather pull than receive pushes:

```bash
# Has the account connected yet?
curl 'https://qqfrzurledgywyhcxdse.supabase.co/rest/v1/organizations_addresses?service=eq.whatsapp&status=eq.connected&select=address,extra,updated_at' \
  -H 'apikey: <PUBLISHABLE_KEY>' -H 'api-key: <OPENBSP_API_KEY>'

# Any onboarding/Meta errors?
curl 'https://qqfrzurledgywyhcxdse.supabase.co/rest/v1/logs?level=eq.error&select=category,service,message,metadata,created_at&order=created_at.desc' \
  -H 'apikey: <PUBLISHABLE_KEY>' -H 'api-key: <OPENBSP_API_KEY>'
```

## 9. (Optional) Export your organization's data

An owner (user or **owner** API key) can take a copy of the organization's data:
one NDJSON file per table (`organizations`, `organizations_addresses`,
`contacts_addresses`, `conversations`, `messages`, `agents`, `webhooks`, `logs`)
and a `manifest.json`, in a ZIP. Credentials are not included: `extra` values
stored as secrets, credential-named keys and webhook tokens are left out.
Attachments are not included either; `messages.content.file.uri` names them.

The simulator is not included: no row whose `service` is `sandbox` is exported,
on any of those tables, so an export holds real traffic and not a colleague's
rehearsals. See "Drills" under `## 7`. `manifest.json` counts what was written,
so its numbers are of the export and not of the database.

```bash
# File the export (returns its id; while one is pending you get that one)
curl -X POST 'https://qqfrzurledgywyhcxdse.supabase.co/rest/v1/rpc/request_organization_export' \
  -H 'apikey: <PUBLISHABLE_KEY>' -H 'api-key: <OPENBSP_OWNER_API_KEY>' \
  -H 'Content-Type: application/json' -d '{"_organization_id": "<ORG_ID>"}'

# Wait for status "ready" (pending → processing → ready | failed)
curl 'https://qqfrzurledgywyhcxdse.supabase.co/rest/v1/organization_exports?id=eq.<EXPORT_ID>&select=status,object_name,error,expires_at' \
  -H 'apikey: <PUBLISHABLE_KEY>' -H 'api-key: <OPENBSP_OWNER_API_KEY>'

# Sign a download URL for object_name (valid 1 hour here)
curl -X POST 'https://qqfrzurledgywyhcxdse.supabase.co/storage/v1/object/sign/exports/<OBJECT_NAME>' \
  -H 'apikey: <PUBLISHABLE_KEY>' -H 'api-key: <OPENBSP_OWNER_API_KEY>' \
  -H 'Content-Type: application/json' -d '{"expiresIn": 3600}'
```

The file is removed 7 days after it is ready (the row then reads `expired`), and
at once if the organization or one of its accounts is deleted. A member or admin
(or their keys) gets `42501`.

**Size.** The worker builds the whole ZIP in memory and uploads it in one
request, so a large organization's export ends `failed` with the reason rather
than producing a file: the ceilings are the function's memory and Storage's
upload limit for a single request. As a rule of thumb the compressed NDJSON runs
at a few kilobytes per hundred messages, so an organization in the hundreds of
thousands of messages is where this starts to matter. If you hit it, ask for the
data in ranges through the REST API (`messages` filtered by `created_at`) until
the export is split into parts.

---

## Recap

1. Create your org + API key in the dashboard (once).
2. (Optional) Register `organizations_addresses` + `logs` webhooks.
3. Mint an onboarding link (with `callback_url`/`verify_token`) via the API.
4. Customer connects → account appears in `organizations_addresses` with its
   token.
5. Their messages arrive at your `callback_url`; you send via OpenBSP or Meta.

You shipped a multi-tenant WhatsApp product and never touched Meta's Tech
Provider program — OpenBSP is the Tech Provider, as a service.
