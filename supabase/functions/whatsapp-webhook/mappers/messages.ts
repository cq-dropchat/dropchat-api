import * as log from "../../_shared/logger.ts";
import type {
  EditedMessage,
  IncomingMessage,
  WebhookEchoMessage,
  WebhookHistoryMessage,
  WebhookIncomingMessage,
} from "../../_shared/supabase.ts";
import { whatsappToMarkdown } from "../../_shared/markdown.ts";
import type { Batch } from "../batch.ts";

/** A webhook message → content v1; undefined for what is not stored. */
export function webhookMessageToIncomingMessage(
  message: WebhookIncomingMessage | WebhookEchoMessage | WebhookHistoryMessage,
): IncomingMessage | undefined {
  let re_message_id: string | undefined;
  let forwarded: boolean | undefined;

  // Handle context information for incoming messages
  if ("context" in message && message.context) {
    if (message.context.id) {
      re_message_id = message.context.id;
    }
    if (message.context.forwarded || message.context.frequently_forwarded) {
      forwarded = true;
    }
  }

  // Handle reactions - they reference a message differently
  if (message.type === "reaction") {
    re_message_id = message.reaction.message_id;
  }

  const baseMessage = {
    version: "1" as const,
    ...(re_message_id && { re_message_id }),
    ...(forwarded && { forwarded }),
    ...("referral" in message && { referral: message.referral }),
    ...("context" in message && message.context?.referred_product &&
      { referred_product: message.context.referred_product }),
  };

  switch (message.type) {
    case "text": {
      return {
        ...baseMessage,
        type: "text",
        kind: "text",
        text: whatsappToMarkdown(message.text.body),
      };
    }

    case "reaction": {
      // Cross-service reaction shape (see ReactionPart), data-only;
      // removals carry no emoji on WhatsApp (single reaction per user),
      // hence no name/unicode then.
      const emoji = message.reaction.emoji;
      return {
        ...baseMessage,
        type: "data",
        kind: "reaction",
        data: emoji
          ? { action: "added", name: emoji, unicode: emoji }
          : { action: "removed" },
      };
    }

    case "audio": {
      return {
        ...baseMessage,
        type: "file",
        kind: "audio",
        file: {
          mime_type: message.audio.mime_type,
          uri: message.audio.id, // Will be replaced with internal URI after download
          size: 0, // Will be updated after download
        },
      };
    }

    case "image": {
      return {
        ...baseMessage,
        type: "file",
        kind: "image",
        file: {
          mime_type: message.image.mime_type,
          uri: message.image.id, // Will be replaced with internal URI after download
          size: 0, // Will be updated after download
        },
        ...(message.image.caption &&
          { text: whatsappToMarkdown(message.image.caption) }),
      };
    }

    case "video": {
      return {
        ...baseMessage,
        type: "file",
        kind: "video",
        file: {
          mime_type: message.video.mime_type,
          uri: message.video.id, // Will be replaced with internal URI after download
          name: message.video.filename,
          size: 0, // Will be updated after download
        },
        ...(message.video.caption &&
          { text: whatsappToMarkdown(message.video.caption) }),
      };
    }

    case "document": {
      return {
        ...baseMessage,
        type: "file",
        kind: "document",
        file: {
          mime_type: message.document.mime_type,
          uri: message.document.id, // Will be replaced with internal URI after download
          name: message.document.filename,
          size: 0, // Will be updated after download
        },
        ...(message.document.caption &&
          { text: whatsappToMarkdown(message.document.caption) }),
      };
    }

    case "sticker": {
      return {
        ...baseMessage,
        type: "file",
        kind: "sticker",
        file: {
          mime_type: message.sticker.mime_type,
          uri: message.sticker.id, // Will be replaced with internal URI after download
          size: 0, // Will be updated after download
        },
      };
    }

    case "contacts": {
      return {
        ...baseMessage,
        type: "data",
        kind: "contacts",
        data: message.contacts,
      };
    }

    case "location": {
      return {
        ...baseMessage,
        type: "data",
        kind: "location",
        data: message.location,
      };
    }

    case "order": {
      return {
        ...baseMessage,
        type: "data",
        kind: "order",
        data: message.order,
      };
    }

    case "interactive": {
      return {
        ...baseMessage,
        type: "data",
        kind: "interactive",
        data: message.interactive,
      };
    }

    case "button": {
      return {
        ...baseMessage,
        type: "data",
        kind: "button",
        data: message.button,
      };
    }

    case "media_placeholder": {
      return {
        ...baseMessage,
        type: "data",
        kind: "media_placeholder",
        data: {},
      };
    }

    case "unsupported":
      return {
        ...baseMessage,
        type: "data",
        kind: "unsupported",
        data: message.unsupported,
      };

    case "system": {
      // System messages (user_changed_number / user_changed_user_id) announce a
      // phone-number / BSUID change. No-op: we never re-key here. Identifier
      // relinking is driven by the user_id_update webhook. Log for visibility.
      log.info("System message (no-op)", message);
      break;
    }

    case "errors":
    default: {
      // System and unsupported messages are not converted to IncomingMessage
      // They should be handled separately or filtered out before calling this function
      log.warn(
        `Message type "${message.type}" cannot be converted to IncomingMessage`,
        message,
      );
    }
  }
}

/**
 * Extracts the new text/caption from an edited message. WhatsApp only allows
 * editing text bodies and media captions, so that is the only field that can
 * change; returns undefined for message types we do not edit in place.
 */
function extractEditedText(message: EditedMessage): string | undefined {
  switch (message.type) {
    case "text":
      return whatsappToMarkdown(message.text.body);
    case "image":
      return message.image.caption
        ? whatsappToMarkdown(message.image.caption)
        : "";
    case "video":
      return message.video.caption
        ? whatsappToMarkdown(message.video.caption)
        : "";
    case "document":
      return message.document.caption
        ? whatsappToMarkdown(message.document.caption)
        : "";
    default:
      return undefined;
  }
}

/**
 * Edits and revokes arrive as their own messages (coexistence: the contact
 * or the business app) and change the ORIGINAL row, by external id. Collects
 * them into the batch; returns whether the message was one. An edit of a
 * type we do not edit in place is dropped with a warning.
 */
export function collectEditOrRevoke(
  batch: Batch,
  organization_id: string,
  webhookMessage:
    | WebhookIncomingMessage
    | WebhookEchoMessage
    | WebhookHistoryMessage,
): boolean {
  if (webhookMessage.type === "revoke") {
    batch.revokes.push({
      organization_id,
      original_message_id: webhookMessage.revoke.original_message_id,
      timestamp: new Date(webhookMessage.timestamp * 1000).toISOString(),
    });
    return true;
  }

  if (webhookMessage.type === "edit") {
    const text = extractEditedText(webhookMessage.edit.message);
    if (text === undefined) {
      log.warn("Unsupported edited message type", webhookMessage.edit.message);
      return true;
    }
    batch.edits.push({
      organization_id,
      original_message_id: webhookMessage.edit.original_message_id,
      text,
      timestamp: new Date(webhookMessage.timestamp * 1000).toISOString(),
    });
    return true;
  }

  return false;
}
