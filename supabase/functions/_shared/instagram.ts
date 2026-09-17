// Instagram helpers shared by the webhook and the dispatcher.
import type { SupabaseClient } from "@supabase/supabase-js";
import * as log from "./logger.ts";
import { getAddressSecrets } from "./secrets.ts";

/**
 * Flags a connection whose token proved dead (Graph error 190) so the UI can
 * prompt a re-login — the same `extra.needs_reauth` flag the refresh sweep
 * sets on a failed refresh (and clears on success). Detection matters outside
 * the sweep: the sweep only attempts tokens within 10 days of expiry, so a
 * token revoked mid-life (password change, forced session invalidation)
 * would otherwise fail silently for weeks. merge_update keeps the rest of
 * extra.
 *
 * F28: while the flag is set the dispatcher sends nothing, so a flag on a
 * token that is already replaced would stop a healthy account. With
 * `rejectedToken`, the stored token is re-read first and a renewed one is
 * left alone. Returns whether the flag was written.
 */
export async function flagNeedsReauth(
  client: SupabaseClient,
  organization_id: string,
  address: string,
  rejectedToken?: string,
): Promise<boolean> {
  if (rejectedToken !== undefined) {
    const current = await getAddressSecrets(
      client as never,
      organization_id,
      "instagram",
      address,
    );
    if (current?.access_token !== rejectedToken) return false;
  }

  log.error(
    `Instagram token dead for ${address}; flagging needs_reauth`,
  );

  await client
    .from("organizations_addresses")
    .update({ extra: { needs_reauth: new Date().toISOString() } })
    .eq("organization_id", organization_id)
    .eq("service", "instagram")
    .eq("address", address)
    .throwOnError();

  return true;
}

/** When the account was flagged `needs_reauth`, or null. */
export async function readNeedsReauth(
  client: SupabaseClient,
  organization_id: string,
  address: string,
): Promise<string | null> {
  const { data } = await client
    .from("organizations_addresses")
    .select("needs_reauth:extra->>needs_reauth")
    .eq("organization_id", organization_id)
    .eq("service", "instagram")
    .eq("address", address)
    .maybeSingle()
    .throwOnError();

  return (data as { needs_reauth?: string | null } | null)?.needs_reauth ??
    null;
}
