// F18: builds an organization's export — a ZIP with one NDJSON file per
// table and a manifest — from what the service role reads. Secrets never
// enter it: public.secrets is not read, and the masks F02 leaves in `extra`
// (plus any key that names a credential) are dropped.
import type { SupabaseClient } from "@supabase/supabase-js";
import { strToU8, Zip, ZipDeflate } from "fflate";
import type { Database } from "../_shared/types/database_types.ts";

type Client = SupabaseClient<Database>;
type Row = Record<string, unknown>;

const PAGE = 1000;
const MASK = "********";

/** Keys that hold a credential wherever they appear in an `extra`. */
const SECRET_KEYS = new Set([
  "access_token",
  "refresh_token",
  "api_key",
  "token",
  "password",
  "secret",
  "client_secret",
  "authorization",
]);

export type ExportTable =
  | "organizations"
  | "organizations_addresses"
  | "contacts_addresses"
  | "conversations"
  | "messages"
  | "agents"
  | "webhooks"
  | "logs";

type TableSpec = {
  name: ExportTable;
  /** The column that scopes the table to the organization. */
  scope: "id" | "organization_id";
  /** Page by `id` (keyset) when the table has one; else by range. */
  keyset: boolean;
  order: string[];
  /** Columns left out of the export. */
  omit?: string[];
  /** Columns whose JSON gets the credential-key scrub. */
  scrubKeys?: string[];
  /**
   * S1: the table has a `service` column, so its `sandbox` rows are the
   * simulator's and are left out. Stated per table rather than discovered at
   * runtime — a filter on a column that does not exist is a 400 from
   * PostgREST at export time, which is the worst moment to find out.
   */
  hasService?: boolean;
};

export const TABLES: TableSpec[] = [
  {
    name: "organizations",
    scope: "id",
    keyset: true,
    order: ["id"],
    scrubKeys: ["extra"],
  },
  {
    name: "organizations_addresses",
    scope: "organization_id",
    keyset: false,
    order: ["service", "address"],
    scrubKeys: ["extra"],
    hasService: true,
  },
  {
    name: "contacts_addresses",
    scope: "organization_id",
    keyset: false,
    order: ["organization_address", "service", "address"],
    scrubKeys: ["extra"],
    hasService: true,
  },
  {
    name: "conversations",
    scope: "organization_id",
    keyset: true,
    order: ["id"],
    hasService: true,
  },
  {
    name: "messages",
    scope: "organization_id",
    keyset: true,
    order: ["id"],
    hasService: true,
  },
  {
    name: "agents",
    scope: "organization_id",
    keyset: true,
    order: ["id"],
    scrubKeys: ["extra"],
  },
  {
    name: "webhooks",
    scope: "organization_id",
    keyset: true,
    order: ["id"],
    omit: ["token"],
  },
  {
    name: "logs",
    scope: "organization_id",
    keyset: true,
    order: ["id"],
    hasService: true,
  },
];

/** Drops F02 masks everywhere; with `keys`, also credential-named keys. */
export function scrub(value: unknown, keys: boolean): unknown {
  if (value === MASK) return undefined;
  if (Array.isArray(value)) {
    return value.map((v) => scrub(v, keys)).filter((v) => v !== undefined);
  }
  if (value !== null && typeof value === "object") {
    const out: Row = {};
    for (const [key, v] of Object.entries(value)) {
      if (keys && SECRET_KEYS.has(key.toLowerCase())) continue;
      const clean = scrub(v, keys);
      if (clean !== undefined) out[key] = clean;
    }
    return out;
  }
  return value;
}

function clean(spec: TableSpec, row: Row): Row {
  const out: Row = {};
  for (const [column, value] of Object.entries(row)) {
    if (spec.omit?.includes(column)) continue;
    const v = scrub(value, spec.scrubKeys?.includes(column) ?? false);
    if (v !== undefined) out[column] = v;
  }
  return out;
}

async function* pages(
  client: Client,
  spec: TableSpec,
  organizationId: string,
): AsyncGenerator<Row[]> {
  let after: string | null = null;
  let offset = 0;

  while (true) {
    // deno-lint-ignore no-explicit-any
    let query: any = client
      .from(spec.name)
      .select("*")
      .eq(spec.scope, organizationId);

    // S1 — the simulator's rows are not the organization's data. A drill is
    // a member rehearsing against an agent; exporting it would mix
    // rehearsals into the same NDJSON as real customer traffic, with
    // nothing in the ZIP to tell them apart. This is the rule
    // notify_webhook already applies, so "is a sandbox row real?" has one
    // answer and not two.
    //
    // The null arm is not decoration. `service <> 'sandbox'` is NULL for a
    // NULL service, and NULL is not true, so a plain `neq` would silently
    // drop every public.logs row that names no service — which is most of
    // them, since an application error is rarely about one channel.
    if (spec.hasService) {
      query = query.or("service.is.null,service.neq.sandbox");
    }

    for (const column of spec.order) query = query.order(column);

    if (spec.keyset) {
      if (after) query = query.gt("id", after);
      query = query.limit(PAGE);
    } else {
      query = query.range(offset, offset + PAGE - 1);
    }

    const { data, error } = await query;
    if (error) throw error;
    const rows = (data ?? []) as Row[];
    if (rows.length > 0) yield rows;
    if (rows.length < PAGE) return;

    after = rows[rows.length - 1].id as string;
    offset += PAGE;
  }
}

export async function buildOrganizationExport(
  client: Client,
  organizationId: string,
): Promise<
  { zip: Uint8Array<ArrayBuffer>; counts: Record<ExportTable, number> }
> {
  const chunks: Uint8Array[] = [];
  let failure: Error | null = null;
  const zip = new Zip((error, chunk) => {
    if (error) failure = error;
    else chunks.push(chunk);
  });

  const counts = {} as Record<ExportTable, number>;

  for (const spec of TABLES) {
    const file = new ZipDeflate(`${spec.name}.ndjson`, { level: 6 });
    zip.add(file);
    counts[spec.name] = 0;

    for await (const rows of pages(client, spec, organizationId)) {
      const lines = rows.map((row) => JSON.stringify(clean(spec, row)) + "\n");
      counts[spec.name] += rows.length;
      file.push(strToU8(lines.join("")));
    }
    file.push(new Uint8Array(0), true);
  }

  const manifest = new ZipDeflate("manifest.json", { level: 6 });
  zip.add(manifest);
  manifest.push(
    strToU8(JSON.stringify(
      {
        format: "openbsp-organization-export",
        version: 1,
        organization_id: organizationId,
        exported_at: new Date().toISOString(),
        counts,
      },
      null,
      2,
    )),
    true,
  );
  zip.end();

  if (failure) throw failure;

  const size = chunks.reduce((n, c) => n + c.length, 0);
  const out = new Uint8Array(new ArrayBuffer(size));
  let at = 0;
  for (const chunk of chunks) {
    out.set(chunk, at);
    at += chunk.length;
  }
  return { zip: out, counts };
}
