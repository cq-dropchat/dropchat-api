// F27. Which organization an MCP request operates on.
//
// An OAuth user may belong to several organizations. `Organization-Id`
// (header) or `?organization_id=` (for connectors that cannot set headers)
// picks one of the caller's live memberships; without it, the oldest one — a
// stable default, where `agents … limit(1)` returned whichever row came first.
// An API key belongs to one organization: naming another is refused.
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../_shared/supabase.ts";

export type OrganizationChoice =
  | { ok: true; orgId: string }
  | { ok: false; status: 400 | 401 | 403; error: string };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The organization the request names, from header or query; null if none. */
export function requestedOrganization(req: Request): string | null {
  return req.headers.get("organization-id") ||
    new URL(req.url).searchParams.get("organization_id") || null;
}

function invalid(requested: string): OrganizationChoice | null {
  return UUID.test(requested)
    ? null
    : { ok: false, status: 400, error: "Organization-Id is not a valid id" };
}

export async function chooseUserOrganization(
  supabase: SupabaseClient<Database>,
  userId: string,
  requested: string | null,
): Promise<OrganizationChoice> {
  if (requested) {
    const bad = invalid(requested);
    if (bad) return bad;
  }

  const { data: memberships, error } = await supabase
    .from("agents")
    .select("organization_id")
    .eq("user_id", userId)
    .is("deleted_at", null)
    .order("created_at", { ascending: true })
    .order("id", { ascending: true });

  if (error || !memberships?.length) {
    return { ok: false, status: 401, error: "No organization for this user" };
  }

  if (!requested) {
    return { ok: true, orgId: memberships[0].organization_id };
  }

  return memberships.some((m) => m.organization_id === requested)
    ? { ok: true, orgId: requested }
    : {
      ok: false,
      status: 403,
      error: "Not a member of the requested organization",
    };
}

export function chooseApiKeyOrganization(
  keyOrgId: string,
  requested: string | null,
): OrganizationChoice {
  if (!requested) return { ok: true, orgId: keyOrgId };
  return invalid(requested) ??
    (requested === keyOrgId ? { ok: true, orgId: keyOrgId } : {
      ok: false,
      status: 403,
      error: "The API key does not belong to the requested organization",
    });
}
