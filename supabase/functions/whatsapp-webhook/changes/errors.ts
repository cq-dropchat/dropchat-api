import * as log from "../../_shared/logger.ts";
import { insertLog } from "../../_shared/logs.ts";
import type { WebhookError } from "../../_shared/supabase.ts";
import type { AccountChange } from "../batch.ts";

/** The `errors`-type messages of one change, logged once per error code. */
export async function logErrorSummary(change: AccountChange): Promise<void> {
  const { client, field, organization_id, organization_address, errors } =
    change;

  if (errors.length > 0) {
    const errorCounts = errors.reduce(
      (acc, curr) => {
        const code = curr.code;

        if (!acc[code]) {
          acc[code] = { count: 0, error: curr };
        }

        acc[code].count += 1;

        return acc;
      },
      {} as Record<
        string,
        { count: number; error: Omit<WebhookError, "href"> }
      >,
    );

    for (const { count, error } of Object.values(errorCounts)) {
      log.warn(`Received ${count} error messages with code ${error.code}`, {
        organization_id,
        organization_address,
        error_code: error.code,
        error_message: error.message,
      });

      await insertLog(client, {
        organization_id,
        organization_address,
        category: field,
        service: "whatsapp",
        level: "error",
        message: `Received ${count} error messages with code ${error.code}`,
        metadata: error,
      });
    }
  }
}
