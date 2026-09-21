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

- [x] Move the RLS helpers out of `public` (P8) — the ten SECURITY DEFINER
      helpers the policies call (`get_authorized_orgs`, `get_own_agents`, the
      six visibility helpers, the two agent-identity guards) live in the `rls`
      schema, which PostgREST does not serve. `25_rls_helpers_schema` pins where
      they are and that the five actors still see exactly what they saw.

- [x] Members' lists still show deleted agents (P8) — checked, and the readers
      already filter: `useCurrentAgents`, `useCurrentAgent` and the initial
      fetch all pass `deleted_at is null`, and so do the Edge Functions that
      resolve a membership (`management_auth`, `mcp/organization`,
      `slack-management`). The ones that do not are the authorship readers —
      `useAgentProfile` and the Slack mention resolver — which is the case the
      policy keeps the row readable for. Nothing counts seats. Pinned by two
      cases in `useAgents.test.tsx`.

- [x] API-key-created `local` conversations are invisible orphans (P2) — the
      insert now fails with `PT422` when the shape needs participants and the
      writer has none to record (`after_insert_on_local_conversation`). A
      `channel` and a roster-addressed `direct` are unaffected. **Still open:**
      the rows already created. They are invisible and unrepairable through the
      API; count them in production first —

      ```sql
      select c.type, count(*)
      from public.conversations c
      where c.service = 'local'
        and c.type is distinct from 'channel'
        and not exists (
          select 1 from public.conversations_agents ca
          where ca.conversation_id = c.id
        )
      group by c.type;
      ```

      — then decide the DML: add the organization's owners as participants
      (keeps them private to owners), make them channels (organization-wide),
      or delete them.

- [ ] Organization export in parts (P4) — the `org-export` worker builds the
      whole ZIP in memory and uploads it in one request, so an organization
      large enough to exceed the function's memory or Storage's single-request
      upload limit ends `failed` with the reason (INTEGRATING.md §9 says so).
      Deferred on purpose: there is no deployment to measure, and every fix
      changes the contract. Measure first — rows and bytes of the largest
      organization —

      ```sql
      select count(*) as messages,
             pg_size_pretty(sum(pg_column_size(m.*))) as raw
      from public.messages m
      where m.organization_id = '<org>';
      ```

      — then pick: parts bounded by bytes with the manifest naming them
      (`object_name` becomes several objects: migration, RPC, INTEGRATING §9
      and the owner's screen), or a resumable upload of one streamed ZIP.
      Whichever, the export stops being one object per row.

- [ ] Secrets in Vault instead of `public.secrets` (F02, P8) — a decision before
      it is code. `public.secrets` is service-role only with no policies, and
      the audit left Vault as an improvement, not a finding. Vault costs one
      decrypted read per access (see F24's measurement) and moves the keys out
      of a table a service-role leak would read whole. Not taken in the P1–P8
      batch: nothing is deployed, so there is no operational experience to weigh
      the cost against.

- [ ] Edge call backlog for owners (P5) — `public.edge_calls_health` is service
      role only. If the product ever wants it on a dashboard, expose a summary
      per organization to owners: counts and the oldest pending timestamp, never
      `payload` or `last_error` (they carry message content and third-party
      messages). Deferred: nobody has asked, and there is no deployment to watch
      yet.

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

- [x] S1 — the reset is per member. A drill's address IS its owner's agent id,
      so `rls.get_own_sandbox_addresses` tells one member's rehearsal from
      another's without a string convention shared between SQL and the UI.
      Admins keep the org-wide reach (a departed member's drills would otherwise
      be nobody's), and API keys, having no agent, delete none.

- [x] S1 — drills stay out of the organization export (F18). The exporter drops
      any row whose `service` is `sandbox`, the same rule `notify_webhook`
      applies. No new table, so `12_deletions` needed nothing.

- [x] T1 — `extra.attention` se valida al escribir. Las reglas son las de la UI
      (`frontend/src/utils/businessHours.ts`), en un trigger y no en un CHECK
      porque `extra` llega como merge patch y sólo la fila mergeada vale.
      Encontrado al escribirlo: `{"attention": null}` en un INSERT hacía que
      `attention_config` devolviera un **array**, con todas las claves en NULL,
      y el guard del barrido comparaba contra NULL —que no es verdadero—, así
      que barría toda conversación escalada de una vez.

- [ ] Decidir los dos toggles de auth que producción tiene prendidos y este repo
      no declara (`supabase config diff`, 20/09/2026):
      `auth.external.github.enabled` y `auth.sms.twilio.enabled`. Importan
      juntos con «users can create orgs», que es `with check (true)` para
      cualquier `authenticated` y no exige invitación: con un proveedor de
      identidad abierto, cualquiera que se registre crea su organización y
      consume contra nuestras credenciales de LLM (no hay cobro: Stripe sigue
      pendiente en este mismo archivo). El login de la UI es Google; GitHub está
      prendido sin que nadie lo pidiera, y Twilio SMS agrega un segundo camino
      de autenticación —el blanco habitual del SMS pumping—. Ambos se apagan en
      el panel; declararlos en `config.toml` también los apagaría, pero recién
      en el próximo `config push`, que cambia producción entero. Las otras seis
      diferencias (pooler, storage) son ajustes del panel y quedan documentadas
      en `config.toml`.

- [x] T1 — las dos intermitencias. (a)
      `F29: agent-client stops after ten
      iterations`: el estabilizador de
      snapshots enmascaraba un instante sólo si era más nuevo que
      `Date.now() - 1000`, lo que ataba el snapshot a que los dos relojes
      coincidieran dentro de un segundo —las filas se escriben con el reloj de
      la BASE y se comparan con el de Deno, y este repo ya sabe que derivan
      (P1)—. Pasa a enmascarar por FORMA. No se pierde nada: el snapshot no
      tenía ni un timestamp literal. (b)
      `S1: escalating in the
      simulator...`: la query de las notas no tenía
      `ORDER BY` y yo afirmaba una secuencia; ordenar por `created_at` tampoco
      alcanzaba, porque `now()` es hora de transacción. Se compara como
      conjunto.

      **No se tocó** el `stable` gemelo de `whatsapp-webhook/process_payload`:
      ahí el predicado por edad es correcto a propósito —distingue los
      instantes del PAYLOAD (que sí son expectativas, y están literales en el
      snapshot) de los generados en la corrida—. Enmascarar por forma allí
      borraba aserciones reales; lo descubrí porque el snapshot falló.

- [ ] T3 — `F29: agent-client stops after ten iterations` sigue siendo
      intermitente, por una causa **distinta** de la que cerró T1. Falló una vez
      en cuatro corridas de la suite completa el 21/09; el diff del snapshot es
      solo el ORDEN de las filas, con el contenido idéntico: lotes enteros
      permutados (`use_id` `call_3_0` donde esperaba `call_1_0`). Verde 10/10
      corriendo el archivo aislado, y tres corridas completas seguidas en verde
      después, así que aparece solo bajo la carga de la suite entera.
      `written()` ya ordena por `created_at` y después por `timestamp`, que es
      lo correcto para separar lotes y para separar las filas de un lote; lo que
      falta es qué pasa cuando ese par empata. No es de T3, que no toca ese
      código — apareció corriendo su CI.
