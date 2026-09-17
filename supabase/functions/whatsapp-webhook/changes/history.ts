import * as log from "../../_shared/logger.ts";
import { insertLog } from "../../_shared/logs.ts";
import type {
  OutgoingMessage,
  WebhookValueHistory,
  WebhookValueHistoryError,
} from "../../_shared/supabase.ts";
import type { AccountChange } from "../batch.ts";
import {
  collectEditOrRevoke,
  webhookMessageToIncomingMessage,
} from "../mappers/messages.ts";

/** `history`: threads replayed by the coexistence sync, and its errors. */
export async function collectHistory(
  change: AccountChange,
  value: WebhookValueHistory | WebhookValueHistoryError,
): Promise<void> {
  const { client, organization_id, organization_address, batch, errors } =
    change;

  for (const history of value.history) {
    if ("threads" in history) {
      const convCount = history.threads.length;
      const msgCount = history.threads.reduce(
        (acc, thread) => acc + thread.messages.length,
        0,
      );

      log.info("History sync (threaded)", {
        organization_id,
        organization_address,
        conversations: convCount,
        messages: msgCount,
      });

      await insertLog(client, {
        organization_id,
        organization_address,
        category: "history",
        service: "whatsapp",
        level: "info",
        message: `Syncing ${convCount} conversations and ${msgCount} messages`,
        metadata: history.metadata,
      });

      for (const thread of history.threads) {
        // The thread's context identifies the contact for the whole
        // conversation (phone preferred, BSUID fallback). Register the
        // address and key every message in the thread to it.
        const contact_address = thread.context.wa_id ??
          thread.context.user_id;

        batch.contacts_addresses.push({
          organization_id,
          organization_address,
          address: contact_address,
          service: "whatsapp",
          extra: {
            username: thread.context.username,
            phone_number: thread.context.wa_id,
            bsuid: thread.context.user_id,
            address_type: thread.context.wa_id ? "phone" : "bsuid",
          },
        });

        for (const webhookMessage of thread.messages) {
          // Echoes (business → user) carry a recipient; incoming messages
          // (user → business) do not.
          const isEcho = "to" in webhookMessage ||
            "to_user_id" in webhookMessage;

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

          const historyStatusMap = {
            read: "read",
            delivered: "delivered",
            sent: "sent",
            error: "failed",
            played: "read",
            pending: "accepted",
          };

          const originalStatus = webhookMessage.history_context.status
            .toLowerCase() as keyof typeof historyStatusMap;

          const status = historyStatusMap[originalStatus] ||
            originalStatus;

          // Coexistence overlaps: a message recent enough to arrive live
          // (`messages`/`smb_message_echoes`) is ALSO replayed by the
          // history sync. The live row is minted first and takes the
          // column default `{pending: now()}` — the arm bit — and the
          // history row that follows only merges its own key in, leaving
          // `pending` set on a message that was delivered months ago.
          // That is what woke the dispatcher and agent-client on a
          // backfill. A null in a merge patch REMOVES the key
          // (merge_update_jsonb, RFC 7396), so stating it here disarms
          // the row the sync is describing as already-happened.
          const historyStatus = {
            [status]: new Date(webhookMessage.timestamp * 1000)
              .toISOString(),
            pending: null,
          };

          const message = isEcho
            ? {
              organization_id,
              // id is the internal (aka surrogate) identifier given by the DB, while
              // external_id is the one given by the service, such as the WhatsApp message id (WAMID)
              external_id: webhookMessage.id,
              service: "whatsapp" as const,
              organization_address,
              conversation_address: contact_address,
              content: content as OutgoingMessage, // Incoming is a superset of outgoing, except for templates
              status: historyStatus,
              timestamp: new Date(
                webhookMessage.timestamp * 1000,
              ).toISOString(),
            }
            : {
              organization_id,
              // id is the internal (aka surrogate) identifier given by the DB, while
              // external_id is the one given by the service, such as the WhatsApp message id (WAMID)
              external_id: webhookMessage.id,
              service: "whatsapp" as const,
              organization_address,
              conversation_address: contact_address,
              sender_address: contact_address,
              content, // Incoming is a superset of outgoing, except for templates
              status: historyStatus,
              timestamp: new Date(
                webhookMessage.timestamp * 1000,
              ).toISOString(),
            };

          batch.messages.push(message);
        }
      }
    }

    if ("errors" in history) {
      for (const error of history.errors) {
        log.error("History sync error", {
          organization_id,
          organization_address,
          error_code: error.code,
          error_message: error.message,
        });

        await insertLog(client, {
          organization_id,
          organization_address,
          category: "history",
          service: "whatsapp",
          level: "error",
          message: error.message,
          metadata: error,
        });
      }
    }
  }
}
