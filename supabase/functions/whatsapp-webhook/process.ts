import type { SupabaseClient } from "@supabase/supabase-js";
import * as log from "../_shared/logger.ts";
import type { Database, MetaWebhookPayload } from "../_shared/supabase.ts";
import { type AccountChange, newBatch } from "./batch.ts";
import { handleAccountUpdate } from "./changes/account_update.ts";
import { collectEchoes } from "./changes/echoes.ts";
import { logErrorSummary } from "./changes/errors.ts";
import { collectHistory } from "./changes/history.ts";
import {
  collectContacts,
  collectIncomingMessages,
  collectStatuses,
  logMessagesErrors,
} from "./changes/messages.ts";
import { collectStateSync } from "./changes/state_sync.ts";
import { handleUserIdUpdate } from "./changes/user_id_update.ts";
import { buildOrgAddressMap, collectOrgAddresses } from "./org_addresses.ts";
import { persistBatch } from "./persist.ts";

/** Everything after the ack: resolve tenants, download media, persist. */
export async function processPayload(
  client: SupabaseClient<Database>,
  payload: MetaWebhookPayload,
): Promise<void> {
  // Collect all unique organization addresses and build lookup map
  const uniqueOrgAddresses = collectOrgAddresses(payload);
  const orgAddressMap = await buildOrgAddressMap(client, uniqueOrgAddresses);

  const batch = newBatch();

  for (const entry of payload.entry) {
    const waba_id = entry.id; // WhatsApp business account ID (WABA ID)

    for (const { value, field } of entry.changes) {
      log.info(`WhatsApp ${field} payload`, value);

      if (field === "account_update") {
        await handleAccountUpdate(client, waba_id, value);
        continue;
      }

      if (field === "user_id_update") {
        await handleUserIdUpdate(client, orgAddressMap, value);
        continue;
      }

      if (!("metadata" in value)) {
        continue;
      }

      const orgAddressRow = orgAddressMap.get(value.metadata!.phone_number_id); // WhatsApp business account phone number id

      if (!orgAddressRow) {
        log.warn("No organization address");
        continue;
      }

      // TODO: whatsapp coexistence privacy feature: skip storing messages from stored contacts

      const change: AccountChange = {
        client,
        field,
        organization_id: orgAddressRow.organization_id,
        organization_address: orgAddressRow.address,
        batch,
        errors: [],
      };

      if (
        (field === "messages" || field === "smb_message_echoes" ||
          field === "history") && "contacts" in value
      ) {
        collectContacts(change, value);
      }

      if (
        (field === "messages" || field === "history") && "messages" in value
      ) {
        collectIncomingMessages(change, value);
      }

      if (field === "messages" && "statuses" in value) {
        collectStatuses(change, value);
      }

      if (field === "messages" && "errors" in value) {
        await logMessagesErrors(change, value);
      }

      if (
        (field === "smb_message_echoes" || field === "history") &&
        "message_echoes" in value
      ) {
        collectEchoes(change, value);
      }

      if (field === "history" && "history" in value) {
        await collectHistory(change, value);
      }

      if (field === "smb_app_state_sync") {
        collectStateSync(change, value);
      }

      await logErrorSummary(change);
    }
  }

  await persistBatch(client, orgAddressMap, batch);
}
