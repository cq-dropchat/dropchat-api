import type {
  OutgoingMessage,
  WebhookEchoMessage,
} from "../../_shared/supabase.ts";
import type { AccountChange } from "../batch.ts";
import {
  collectEditOrRevoke,
  webhookMessageToIncomingMessage,
} from "../mappers/messages.ts";

/**
 * Messages the business sent from the WhatsApp Business app (coexistence),
 * live (`smb_message_echoes`) or replayed (`history`).
 */
export function collectEchoes(
  change: AccountChange,
  value: { message_echoes?: WebhookEchoMessage[] },
): void {
  const { field, organization_id, organization_address, batch, errors } =
    change;

  for (const webhookMessage of value.message_echoes ?? []) {
    const contact_address = webhookMessage.to ??
      webhookMessage.to_user_id;

    if (webhookMessage.type === "errors") {
      errors.push(...webhookMessage.errors);
      continue;
    }

    // Edits and revokes change the original row (see collectEditOrRevoke).
    if (collectEditOrRevoke(batch, organization_id, webhookMessage)) {
      continue;
    }

    const content = webhookMessageToIncomingMessage(webhookMessage);

    if (!content) {
      continue;
    }

    const message = {
      organization_id,
      // id is the internal (aka surrogate) identifier given by the DB, while
      // external_id is the one given by the service, such as the WhatsApp message id (WAMID)
      external_id: webhookMessage.id,
      service: "whatsapp" as const,
      organization_address,
      conversation_address: contact_address,
      content: content as OutgoingMessage, // Incoming are a superset of outgoing, except for templates
      status: {
        sent: new Date(webhookMessage.timestamp * 1000).toISOString(),
        // Replayed by the history sync, so the same disarming applies as
        // in the threads branch below: the live echo may already have
        // minted the row with the default arm bit.
        ...(field === "history" && { pending: null }),
      },
      timestamp: new Date(webhookMessage.timestamp * 1000).toISOString(),
    };

    batch.messages.push(message);
  }
}
