import type { WebhookValueStateSync } from "../../_shared/supabase.ts";
import type { AccountChange } from "../batch.ts";

/** `smb_app_state_sync`: the WhatsApp Business app's address book. */
export function collectStateSync(
  change: AccountChange,
  value: WebhookValueStateSync,
): void {
  const { organization_id, organization_address, batch } = change;

  for (const syncItem of value.state_sync) {
    if (syncItem.type === "contact") {
      batch.contacts_addresses.push({
        organization_id,
        organization_address,
        address: syncItem.contact.phone_number ??
          syncItem.contact.user_id,
        service: "whatsapp" as const,
        extra: {
          phone_number: syncItem.contact.phone_number,
          bsuid: syncItem.contact.user_id,
          address_type: syncItem.contact.phone_number ? "phone" : "bsuid",
          username: syncItem.contact.username,
          synced: {
            name: syncItem.contact.full_name,
            action: syncItem.action,
          },
        },
      });
    }
  }
}
