import type { SupabaseClient } from "@supabase/supabase-js";
import type {
  Database,
  MetaWebhookPayload,
  OrganizationAddressRow,
} from "../_shared/supabase.ts";
import { revealAddresses } from "../_shared/secrets.ts";

/** Resolved WhatsApp accounts, by phone number id. */
export type OrgAddressMap = Map<string, OrganizationAddressRow>;

/**
 * Queries the database for organization addresses and returns a map.
 * Fetches first active address per address value (ordered by created_at desc).
 */
export async function buildOrgAddressMap(
  client: SupabaseClient<Database>,
  addresses: string[],
): Promise<OrgAddressMap> {
  const { data } = await client
    .from("organizations_addresses")
    .select()
    .in("address", addresses)
    .eq("status", "connected")
    .eq("service", "whatsapp")
    .order("created_at", { ascending: false })
    .throwOnError();

  // Build map, keeping only the first (most recent) address per address value
  const map = new Map<string, OrganizationAddressRow>();

  // F02: extra carries the mask; the access_token comes from public.secrets.
  for (const row of await revealAddresses(client, data)) {
    // Narrow the discriminated union — SELECT filtered to "whatsapp".
    //if (row.service !== "whatsapp") continue;
    if (!map.has(row.address)) {
      map.set(row.address, row);
    }
  }

  return map;
}

/**
 * Collects all unique organization addresses from a webhook payload.
 */
export function collectOrgAddresses(
  payload: MetaWebhookPayload,
): Array<string> {
  const addresses = new Set<string>();

  for (const entry of payload.entry) {
    for (const { value } of entry.changes) {
      if ("metadata" in value && value.metadata?.phone_number_id) {
        addresses.add(value.metadata.phone_number_id);
      }
    }
  }

  return Array.from(addresses);
}
