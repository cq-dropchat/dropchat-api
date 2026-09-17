import * as log from "../../_shared/logger.ts";
import { insertLog } from "../../_shared/logs.ts";
import type {
  OutgoingMessage,
  WebhookContact,
  WebhookIncomingMessage,
  WebhookValueMessagesError,
  WebhookValueStatuses,
} from "../../_shared/supabase.ts";
import type { AccountChange } from "../batch.ts";
import {
  collectEditOrRevoke,
  webhookMessageToIncomingMessage,
} from "../mappers/messages.ts";

/** Contacts carried by `messages`, `smb_message_echoes` and `history`. */
export function collectContacts(
  change: AccountChange,
  value: { contacts?: WebhookContact[] },
): void {
  const { organization_id, organization_address, batch } = change;

  // Both incoming and status (sent/delivered/read) payloads carry contacts;
  // status contacts is optional (omitted for failed), hence `?? []`.
  for (const contact of value.contacts ?? []) {
    batch.contacts_addresses.push({
      organization_id,
      organization_address,
      address: contact.wa_id ?? contact.user_id,
      service: "whatsapp",
      extra: {
        name: contact.profile?.name,
        username: contact.profile?.username,
        phone_number: contact.wa_id,
        bsuid: contact.user_id,
        address_type: contact.wa_id ? "phone" : "bsuid",
      },
    });
  }
}

/** Messages from contacts (`messages`, and `history` media). */
export function collectIncomingMessages(
  change: AccountChange,
  value: { messages?: WebhookIncomingMessage[] },
): void {
  const { organization_id, organization_address, batch, errors } = change;

  for (const webhookMessage of value.messages ?? []) {
    // Payload-literal keying: prefer the phone number, fall back to the
    // BSUID (present only-phone-less for username users). The conversation
    // is created/looked up on this address and never re-keyed.
    const contact_address = webhookMessage.from ??
      webhookMessage.from_user_id;

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
      // Direct chats only on WhatsApp Cloud: the contact is both the
      // conversation's peer and the author.
      conversation_address: contact_address,
      sender_address: contact_address,
      content,
      timestamp: new Date(webhookMessage.timestamp * 1000).toISOString(),
    };

    batch.messages.push(message);
  }
}

/** Delivery statuses of the account's messages. */
export function collectStatuses(
  change: AccountChange,
  value: WebhookValueStatuses,
): void {
  const { organization_id, organization_address, batch } = change;

  for (const status of value.statuses) {
    batch.statuses.push({
      // The account's organization (the map lookup this replaces returned it).
      organization_id,
      external_id: status.id,
      service: "whatsapp",
      organization_address,
      conversation_address: status.recipient_id ??
        status.recipient_user_id,
      content: {} as OutgoingMessage, // this will get merged (it won't overwrite)
      status: {
        [status.status]: new Date(
          parseInt(status.timestamp) * 1000,
        ).toISOString(),
        errors: status.errors,
      },
    });
  }
}

/** Errors Meta reports for the account, with no message attached. */
export async function logMessagesErrors(
  change: AccountChange,
  value: WebhookValueMessagesError,
): Promise<void> {
  const { client, organization_id, organization_address } = change;

  for (const error of value.errors) {
    log.error("WhatsApp messages error", {
      organization_id,
      organization_address,
      error_code: error.code,
      error_title: error.title,
    });

    await insertLog(client, {
      organization_id,
      organization_address,
      category: "messages",
      service: "whatsapp",
      level: "error",
      message: error.message,
      metadata: error,
    });
  }
}
