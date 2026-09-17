import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../_shared/types/database_types.ts";
import * as log from "../_shared/logger.ts";
import type { MessageRow, OrganizationRow } from "../_shared/supabase.ts";

const MEDIA_PREPROCESSING_TIMEOUT = 30 * 1000; // 30 seconds
const MEDIA_PREPROCESSING_POLLING_INTERVAL = 5 * 1000; // 5 seconds

/**
 * With media preprocessing on, waits (polling) for the window's files still
 * being preprocessed, up to 30 s after they arrived, and swaps in the
 * preprocessed rows.
 */
export async function waitForPendingPreprocessing(
  client: SupabaseClient<Database>,
  org: OrganizationRow,
  messages: MessageRow[],
): Promise<void> {
  // The handler set `org.extra` to {} when it was null.
  while (org.extra!.media_preprocessing?.mode === "active") {
    const pendingPreprocessing = messages.filter(
      (m) =>
        m.content.type === "file" &&
        m.status.pending && // Note: not using status.preprocessing to avoid race conditions with the media preprocessor Edge Function.
        !m.status.preprocessed &&
        +new Date(m.status.pending) >
          +new Date() - MEDIA_PREPROCESSING_TIMEOUT,
    );

    if (!pendingPreprocessing.length) {
      break;
    }

    // WAIT FOR THE PREPROCESSING TO COMPLETE

    log.info(
      `Waiting ${MEDIA_PREPROCESSING_POLLING_INTERVAL}ms for pending preprocessing to complete...`,
    );

    await new Promise((resolve) =>
      setTimeout(resolve, MEDIA_PREPROCESSING_POLLING_INTERVAL)
    );

    // Note: we could check for newer messages here too, but it would bloat the code.

    // RETRIEVE PROCESSED MESSAGES

    const { data: pending_messages } = await client
      .from("messages")
      .select()
      .in(
        "id",
        pendingPreprocessing.map((m) => m.id),
      )
      .throwOnError();

    // Update the messages with the pending processing.
    for (const pm of pending_messages) {
      const index = messages.findIndex((m) => m.id === pm.id);

      if (index > -1) {
        messages[index] = pm;
      }
    }
  }
}
