// F05. public.logs is an audit trail, not a step of the pipeline. A webhook
// that failed to write a log line used to 500 — and with it the whole Meta
// batch, other tenants' messages included (a FK on a deleted organization
// was enough). Writing a log never throws here; a failure is itself logged.
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "./types/database_types.ts";
import * as log from "./logger.ts";

export type LogInsert = Database["public"]["Tables"]["logs"]["Insert"];

type LogsClient = {
  from(table: "logs"): {
    insert(row: LogInsert): PromiseLike<{ error: unknown }>;
  };
};

export async function insertLog(
  client: SupabaseClient<Database> | LogsClient,
  row: LogInsert,
): Promise<boolean> {
  try {
    const { error } = await (client as LogsClient).from("logs").insert(row);

    if (error) {
      log.warn("Could not write to public.logs", { error, row });
      return false;
    }

    return true;
  } catch (error) {
    log.warn("Could not write to public.logs", { error, row });
    return false;
  }
}
