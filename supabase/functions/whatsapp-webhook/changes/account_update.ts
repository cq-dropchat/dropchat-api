import type { SupabaseClient } from "@supabase/supabase-js";
import * as log from "../../_shared/logger.ts";
import { insertLog } from "../../_shared/logs.ts";
import type {
  Database,
  WebhookAccountUpdateValue,
} from "../../_shared/supabase.ts";

/**
 * `account_update`: logged for the account's organization; coexistence
 * lifecycle events connect or disconnect it.
 */
export async function handleAccountUpdate(
  client: SupabaseClient<Database>,
  waba_id: string,
  value: WebhookAccountUpdateValue,
): Promise<void> {
  // Query directly since account_update events do not populate orgAddressMap
  const { data: address } = await client
    .from("organizations_addresses")
    .select()
    .eq("extra->>waba_id", waba_id)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle()
    .throwOnError();

  if (!address?.organization_id) {
    log.warn(
      "Could not log account update payload: No organization found for WABA",
      value,
    );
    return;
  }

  log.info("Account update event", {
    organization_id: address.organization_id,
    event: value.event,
    waba_id,
  });

  await insertLog(client, {
    organization_id: address.organization_id,
    category: "account_update",
    service: "whatsapp",
    level: "info",
    message: value.event.toLocaleLowerCase(),
    metadata: { waba_id, value },
  });

  // Coexistence lifecycle: PARTNER_REMOVED and ACCOUNT_OFFBOARDED
  // disconnect the address; ACCOUNT_RECONNECTED re-enables it after the
  // client re-onboards (device switch, reinstall, or re-registration).
  const nextStatus = value.event === "PARTNER_REMOVED" ||
      value.event === "ACCOUNT_OFFBOARDED"
    ? "disconnected"
    : value.event === "ACCOUNT_RECONNECTED"
    ? "connected"
    : null;

  if (nextStatus) {
    log.info(`Account ${value.event}, setting address status`, {
      status: nextStatus,
      waba_id,
    });

    await client
      .from("organizations_addresses")
      .update({ status: nextStatus })
      .eq("organization_id", address.organization_id)
      .eq("extra->>waba_id", waba_id)
      .throwOnError();
  }
}
