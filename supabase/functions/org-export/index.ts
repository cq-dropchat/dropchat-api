import type { SupabaseClient } from "@supabase/supabase-js";
import { createUnsecureClient } from "../_shared/supabase.ts";
import type { Database } from "../_shared/types/database_types.ts";
import * as log from "../_shared/logger.ts";
import { withRequestLogging } from "../_shared/logger.ts";
import { buildOrganizationExport } from "./export.ts";

/**
 * F18: organization exports worker. Invoked when an export is requested
 * (trigger on public.organization_exports) and hourly by pg_cron (retries,
 * stale claims and expiry). Each run:
 *
 *   1. removes the files of expired exports and marks them expired;
 *   2. claims one pending export, builds its ZIP (org-export/export.ts),
 *      uploads it to the private `exports` bucket at
 *      organizations/<org>/exports/<id>.zip and marks it ready (or failed).
 *
 * The export is built in memory: an organization whose data does not fit the
 * function's memory or Storage's upload limit ends `failed` with the reason.
 */

const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const BUCKET = "exports";

type Client = SupabaseClient<Database>;

async function expireExports(client: Client): Promise<number> {
  const { data, error } = await client.rpc("expired_organization_exports", {
    _limit: 100,
  });
  if (error) throw error;

  let expired = 0;
  for (const row of data ?? []) {
    if (row.object_name) {
      const { error: removeError } = await client.storage
        .from(BUCKET)
        .remove([row.object_name]);
      if (removeError) throw removeError;
    }
    const { error: markError } = await client.rpc(
      "mark_organization_export_expired",
      { _id: row.id },
    );
    if (markError) throw markError;
    expired++;
  }
  return expired;
}

export async function handler(req: Request): Promise<Response> {
  const token = req.headers.get("Authorization")?.replace("Bearer ", "");
  if (!SERVICE_ROLE_KEY || token !== SERVICE_ROLE_KEY) {
    return new Response("Unauthorized", { status: 401 });
  }

  const client = createUnsecureClient();
  const expired = await expireExports(client);

  const { data: claimed, error } = await client.rpc(
    "claim_organization_export",
  );
  if (error) throw error;
  const job = claimed?.[0];

  if (!job) return Response.json({ expired, exported: null });

  const objectName =
    `organizations/${job.organization_id}/exports/${job.id}.zip`;

  try {
    const { zip, counts } = await buildOrganizationExport(
      client,
      job.organization_id,
    );

    const { error: uploadError } = await client.storage
      .from(BUCKET)
      .upload(objectName, new Blob([zip], { type: "application/zip" }), {
        contentType: "application/zip",
        upsert: true,
      });
    if (uploadError) throw uploadError;

    const { error: finishError } = await client.rpc(
      "finish_organization_export",
      { _id: job.id, _object_name: objectName, _error: null as never },
    );
    if (finishError) throw finishError;

    log.info("organization export ready", {
      organization_id: job.organization_id,
      export_id: job.id,
      bytes: zip.length,
      counts,
    });

    return Response.json({
      expired,
      exported: { id: job.id, bytes: zip.length, counts },
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    log.error("organization export failed", {
      organization_id: job.organization_id,
      export_id: job.id,
      error: message,
    });
    await client.rpc("finish_organization_export", {
      _id: job.id,
      _object_name: null as never,
      _error: message,
    });
    return Response.json({ expired, exported: null, failed: job.id });
  }
}

if (import.meta.main) {
  Deno.serve(withRequestLogging("org-export", handler));
}
