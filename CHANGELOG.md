# Changelog

## Unreleased

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
