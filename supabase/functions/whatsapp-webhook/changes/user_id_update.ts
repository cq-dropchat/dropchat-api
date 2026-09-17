import type { SupabaseClient } from "@supabase/supabase-js";
import * as log from "../../_shared/logger.ts";
import type { Database } from "../../_shared/supabase.ts";
import type { WebhookValueUserIdUpdate } from "../../_shared/types/whatsapp_webhook_payload_types.ts";
import type { OrgAddressMap } from "../org_addresses.ts";

// A user's BSUID changed (previous → current), e.g. after a phone-number
// change. We never re-key an address: instead mark the old address(es)
// inactive and leave a `replaced_by_bsuid` trail. The new address is
// created naturally by the first message under the new identity (phone- or
// bsuid-keyed) and linked back to the same contact via that trail.
export async function handleUserIdUpdate(
  client: SupabaseClient<Database>,
  orgAddressMap: OrgAddressMap,
  value: WebhookValueUserIdUpdate,
): Promise<void> {
  const org = orgAddressMap.get(value.metadata.phone_number_id);

  if (!org) {
    log.warn("user_id_update: no organization for phone number", value);
    return;
  }

  for (const update of value.user_id_update) {
    const { previous, current } = update.user_id;

    const { count } = await client
      .from("contacts_addresses")
      .update({
        status: "inactive",
        extra: { replaced_by_bsuid: current },
      }, { count: "exact" })
      .eq("organization_id", org.organization_id)
      .eq("status", "active")
      .eq("extra->>bsuid", previous)
      .throwOnError();

    log.info("user_id_update: deactivated old addresses", {
      organization_id: org.organization_id,
      previous,
      current,
      count,
    });
  }
}
