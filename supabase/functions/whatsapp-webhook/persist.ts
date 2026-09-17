import type { SupabaseClient } from "@supabase/supabase-js";
import * as log from "../_shared/logger.ts";
import type {
  Database,
  MessageInsert,
  WhatsAppOrganizationAddressExtra,
} from "../_shared/supabase.ts";
import type { Batch } from "./batch.ts";
import { downloadMediaItem } from "./media.ts";
import type { OrgAddressMap } from "./org_addresses.ts";

const DEFAULT_ACCESS_TOKEN = Deno.env.get("META_SYSTEM_USER_ACCESS_TOKEN") ||
  "";

/**
 * Downloads media, then upserts contacts, statuses and messages, then applies
 * edits and revokes.
 */
export async function persistBatch(
  client: SupabaseClient<Database>,
  orgAddressMap: OrgAddressMap,
  batch: Batch,
): Promise<void> {
  const { messages, statuses, contacts_addresses, edits, revokes } = batch;

  const orgSummary = Array.from(orgAddressMap.entries()).map((
    [address, row],
  ) => ({
    organization_id: row.organization_id,
    organization_address: address,
    waba_id: (row.extra as WhatsAppOrganizationAddressExtra)?.waba_id,
  }));

  log.info("Webhook processing summary", {
    messages: messages.length,
    statuses: statuses.length,
    edits: edits.length,
    revokes: revokes.length,
    contacts_addresses: contacts_addresses.length,
    organizations: orgSummary,
  });

  const downloadMediaPromise = Promise.all(
    messages.map(async (message) => {
      const orgAddress = orgAddressMap.get(message.organization_address)!;

      try {
        return await downloadMediaItem({
          organization_id: orgAddress.organization_id,
          access_token: orgAddress.extra?.access_token || DEFAULT_ACCESS_TOKEN,
          message,
          client,
        });
      } catch (error) {
        log.warn(
          "Failed to download media, preserving message with original reference",
          {
            error: error instanceof Error ? error.message : String(error),
            message_id: message.external_id,
          },
        );

        message.status = {
          error: error instanceof Error ? error.message : String(error),
        };
        return message;
      }
    }),
  );

  if (contacts_addresses.length > 0) {
    // Deduplicate by the PK: Meta may send the same contact multiple times in
    // one payload (e.g. accumulated state sync events). PostgreSQL's ON
    // CONFLICT cannot affect the same row twice in a single statement. Keep
    // the last entry — most recent event wins.
    const dedupedContactsAddresses = Array.from(
      new Map(
        contacts_addresses.map((ca) => [
          `${ca.organization_id}|${ca.organization_address}|${ca.address}|${ca.service}`,
          ca,
        ]),
      ).values(),
    );

    const { error: contactsError } = await client
      .from("contacts_addresses")
      .upsert(dedupedContactsAddresses);

    if (contactsError) {
      log.error("Failed to upsert contacts_addresses", {
        error: contactsError,
        organizations: orgSummary,
        contacts_addresses: dedupedContactsAddresses,
      });
      throw contactsError;
    }

    log.info("Persisted contacts_addresses", {
      count: contacts_addresses.length,
    });
  }

  // Notes for statuses:
  // 1. Upsert is needed because there is no bulk update
  // 2. Insert operation is not expected, because statuses come
  //    after outgoing messages are inserted
  // 3. Only the `status` field should be updated based on external_id,
  //    but upsert requires records to be prepared for insertion (which won't happen)
  // 4. `content` field is set to empty object {}, it will be merged
  //    with existing content during update (inocuous)

  // Notes for messages:
  // Download media before upserting incoming messages
  // Patched messages include media local id and file size
  const patchedMessages = await downloadMediaPromise;

  // A status row (content `{}`) and a message row can carry the same
  // external_id within one webhook (e.g. an echo plus a status/edit/revoke for
  // the same WAMID). We upsert statuses and messages in two separate statements
  // rather than deduping: Postgres' ON CONFLICT cannot affect the same row twice
  // in one statement, and a last-wins dedup would drop the complementary half
  // (content vs status) that the merge trigger is meant to combine.
  const upsertBatch = async (label: string, rows: MessageInsert[]) => {
    if (rows.length === 0) return;

    const { error } = await client
      .from("messages")
      // defaultToNull: false — rows in one batch carry different keys (a
      // media item that failed adds `status`); PostgREST would otherwise
      // write null for a column a row omits, and a single row with `status`
      // rejected the whole batch (not-null). Omitted columns take defaults.
      .upsert(rows, {
        onConflict: "organization_id,external_id",
        defaultToNull: false,
      });

    if (error) {
      log.error(`Failed to upsert ${label}`, {
        error,
        organizations: orgSummary,
        count: rows.length,
      });
      throw error;
    }

    log.info(`Persisted ${label}`, { count: rows.length });
  };

  await upsertBatch("statuses", statuses);
  await upsertBatch("messages", patchedMessages);

  // Apply edits and revokes as in-place updates keyed by the ORIGINAL message
  // id (not the event's own id). They modify existing rows, so an UPDATE lets
  // the content/status merge triggers run without clobbering the row's
  // direction; if we never stored the original, the update matches no rows (you
  // cannot edit or delete a message we do not have). Run after the upserts so an
  // original delivered in the same webhook already exists.
  for (
    const { organization_id, original_message_id, text, timestamp } of edits
  ) {
    await client
      .from("messages")
      .update({ content: { text }, status: { edited: timestamp } })
      .eq("organization_id", organization_id)
      .eq("external_id", original_message_id)
      .throwOnError();
  }

  for (const { organization_id, original_message_id, timestamp } of revokes) {
    await client
      .from("messages")
      .update({ status: { deleted: timestamp } })
      .eq("organization_id", organization_id)
      .eq("external_id", original_message_id)
      .throwOnError();
  }
}
